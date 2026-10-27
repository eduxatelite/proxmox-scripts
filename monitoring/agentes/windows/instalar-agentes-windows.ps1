<#
.SYNOPSIS
    Instala y configura windows_exporter y Grafana Alloy en un controlador de dominio.

.DESCRIPTION
    Pensado para desplegar el stack de monitorizacion en clientes nuevos.
    Es idempotente: se puede volver a ejecutar sin romper nada.

    - windows_exporter con los colectores de Active Directory, puerto 9182
    - regla de firewall restringida solo a la VM de monitorizacion
    - Grafana Alloy enviando el log de seguridad a Loki

.PARAMETER MonitoringVM
    IP de la VM donde corren Prometheus y Loki.

.PARAMETER DCName
    Nombre del DC, se usa como label 'host' en Loki. Por defecto el hostname.

.EXAMPLE
    .\instalar-agentes-windows.ps1 -MonitoringVM 10.0.0.50

.EXAMPLE
    .\instalar-agentes-windows.ps1 -MonitoringVM 10.0.0.50 -SkipAlloy
#>

[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)]
    [string]$MonitoringVM,

    [string]$DCName = $env:COMPUTERNAME,

    [int]$ExporterPort = 9182,

    [int]$LokiPort = 3100,

    [string]$Collectors = "ad,dns,cpu,memory,logical_disk,os,service,net,system,time",

    [switch]$SkipExporter,

    [switch]$SkipAlloy
)

$ErrorActionPreference = "Stop"
$TempDir = "C:\Temp\monitoring-setup"

function Write-Paso { param($m) Write-Host "`n=== $m ===" -ForegroundColor Cyan }
function Write-Ok   { param($m) Write-Host "  [OK] $m" -ForegroundColor Green }
function Write-Warn { param($m) Write-Host "  [!]  $m" -ForegroundColor Yellow }

# ─── Comprobaciones previas ────────────────────────────────────────────────

Write-Paso "Comprobaciones previas"

if (-not ([Security.Principal.WindowsPrincipal] `
    [Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole(
        [Security.Principal.WindowsBuiltInRole]::Administrator)) {
    throw "Hay que ejecutarlo como administrador."
}
Write-Ok "Ejecutando como administrador"

if (-not (Test-Path $TempDir)) {
    New-Item -ItemType Directory -Force -Path $TempDir | Out-Null
}

# TLS 1.2 para las descargas de GitHub
[Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12

$conn = Test-NetConnection -ComputerName $MonitoringVM -Port $LokiPort `
        -WarningAction SilentlyContinue
if (-not $conn.TcpTestSucceeded) {
    Write-Warn "No se alcanza $MonitoringVM`:$LokiPort. Alloy no podra enviar logs."
    Write-Warn "Revisar la regla DOCKER-USER en la VM (Loki 3100 restringido por IP)."
} else {
    Write-Ok "Conectividad con Loki correcta"
}

Write-Ok "DC: $DCName  |  VM de monitorizacion: $MonitoringVM"

# ─── windows_exporter ──────────────────────────────────────────────────────

if (-not $SkipExporter) {
    Write-Paso "windows_exporter"

    $svc = Get-Service windows_exporter -ErrorAction SilentlyContinue
    if ($svc) {
        Write-Warn "Ya esta instalado (estado: $($svc.Status)). Se omite la instalacion."
    } else {
        # Resolver la ultima release via API de GitHub
        $api = "https://api.github.com/repos/prometheus-community/windows_exporter/releases/latest"
        $rel = Invoke-RestMethod -Uri $api -UseBasicParsing
        $asset = $rel.assets | Where-Object { $_.name -like "*amd64.msi" } | Select-Object -First 1
        if (-not $asset) { throw "No se encontro el MSI amd64 en la ultima release." }

        $msi = Join-Path $TempDir $asset.name
        Write-Host "  Descargando $($asset.name)..."
        Invoke-WebRequest -Uri $asset.browser_download_url -OutFile $msi -UseBasicParsing

        # ENABLED_COLLECTORS con los de AD. El path de config va vacio a
        # proposito: si se pone un fichero que no existe, el servicio no arranca.
        $args = @(
            "/i", "`"$msi`"", "/qn",
            "ENABLED_COLLECTORS=`"$Collectors`"",
            "LISTEN_PORT=$ExporterPort",
            "ADDLOCAL=FirewallException=`"`""
        )
        Write-Host "  Instalando..."
        $p = Start-Process msiexec.exe -ArgumentList $args -Wait -PassThru
        if ($p.ExitCode -ne 0) { throw "msiexec devolvio $($p.ExitCode)" }

        Start-Sleep -Seconds 5
        Write-Ok "Instalado"
    }

    # Regla de firewall restringida (idempotente)
    $ruleName = "windows_exporter - Prometheus"
    $existing = Get-NetFirewallRule -DisplayName $ruleName -ErrorAction SilentlyContinue
    if ($existing) {
        Set-NetFirewallRule -DisplayName $ruleName -RemoteAddress $MonitoringVM
        Write-Ok "Regla de firewall actualizada"
    } else {
        New-NetFirewallRule -DisplayName $ruleName -Direction Inbound -Protocol TCP `
            -LocalPort $ExporterPort -RemoteAddress $MonitoringVM -Action Allow | Out-Null
        Write-Ok "Regla de firewall creada (solo desde $MonitoringVM)"
    }

    # Verificacion
    $svc = Get-Service windows_exporter
    if ($svc.Status -ne "Running") { Start-Service windows_exporter }

    try {
        $body = (Invoke-WebRequest "http://localhost:$ExporterPort/metrics" `
                 -UseBasicParsing -TimeoutSec 15).Content
        $adCount = ([regex]::Matches($body, "windows_ad_")).Count
        if ($adCount -gt 0) {
            Write-Ok "Metricas de AD expuestas ($adCount referencias)"
        } else {
            Write-Warn "El exporter responde pero no expone metricas windows_ad_*."
            Write-Warn "Revisar que el colector 'ad' este en ENABLED_COLLECTORS."
        }
    } catch {
        Write-Warn "El exporter no responde en localhost:$ExporterPort - $_"
    }
}

# ─── Grafana Alloy ─────────────────────────────────────────────────────────

if (-not $SkipAlloy) {
    Write-Paso "Grafana Alloy"

    $alloyDir  = "C:\Program Files\GrafanaLabs\Alloy"
    $bookmarks = "C:\ProgramData\GrafanaLabs\Alloy\bookmarks"

    $svc = Get-Service Alloy -ErrorAction SilentlyContinue
    if ($svc) {
        Write-Warn "Ya esta instalado (estado: $($svc.Status)). Se reescribe la config."
    } else {
        $api = "https://api.github.com/repos/grafana/alloy/releases/latest"
        $rel = Invoke-RestMethod -Uri $api -UseBasicParsing
        $asset = $rel.assets | Where-Object {
            $_.name -like "*installer-windows-amd64.exe.zip"
        } | Select-Object -First 1
        if (-not $asset) { throw "No se encontro el instalador de Windows." }

        $zip = Join-Path $TempDir $asset.name
        Write-Host "  Descargando $($asset.name)..."
        Invoke-WebRequest -Uri $asset.browser_download_url -OutFile $zip -UseBasicParsing
        Expand-Archive -Path $zip -DestinationPath (Join-Path $TempDir "alloy") -Force

        $exe = Get-ChildItem (Join-Path $TempDir "alloy") -Filter "*.exe" |
               Select-Object -First 1
        if (-not $exe) { throw "No se encontro el .exe dentro del zip." }

        Write-Host "  Instalando (silencioso)..."
        Start-Process $exe.FullName -ArgumentList "/S" -Wait
        Start-Sleep -Seconds 5
        Write-Ok "Instalado"
    }

    # La carpeta de bookmarks NO la crea el instalador
    if (-not (Test-Path $bookmarks)) {
        New-Item -ItemType Directory -Force -Path $bookmarks | Out-Null
        Write-Ok "Carpeta de bookmarks creada"
    }

    # config.alloy. El bookmark evita reenviar todo el log tras un reinicio.
    $config = @"
// Generado automaticamente para $DCName
// Lee el log de seguridad de Windows y lo envia a Loki

loki.source.windowsevent "security" {
  eventlog_name          = "Security"
  use_incoming_timestamp = true
  poll_interval          = "10s"
  bookmark_path          = "$($bookmarks -replace '\\','\\')\\security.xml"
  forward_to             = [loki.write.default.receiver]
}

loki.write "default" {
  endpoint {
    url = "http://${MonitoringVM}:${LokiPort}/loki/api/v1/push"
  }
  external_labels = {
    job     = "windows_security",
    host    = "$DCName",
    service = "active_directory",
  }
}
"@

    $configPath = Join-Path $alloyDir "config.alloy"
    if (-not (Test-Path $alloyDir)) {
        throw "No existe $alloyDir. La instalacion de Alloy no se completo."
    }

    if (Test-Path $configPath) {
        Copy-Item $configPath "$configPath.bak" -Force
    }
    Set-Content -Path $configPath -Value $config -Encoding UTF8
    Write-Ok "config.alloy escrito (host = $DCName)"

    Restart-Service Alloy
    Start-Sleep -Seconds 5
    $svc = Get-Service Alloy
    if ($svc.Status -eq "Running") {
        Write-Ok "Servicio Alloy en ejecucion"
    } else {
        Write-Warn "Alloy no arranco. Revisar la UI en http://localhost:12345"
    }
}

# ─── Resumen ───────────────────────────────────────────────────────────────

Write-Paso "Resumen"

Write-Host @"
  Hecho en $DCName.

  Comprobar desde la VM de monitorizacion:

    curl -s http://$(hostname -f 2>$null; if(-not $?){$env:COMPUTERNAME}):$ExporterPort/metrics | head

  Y en Grafana, que los logs llegan:

    {job="windows_security", host="$DCName"}

  PENDIENTE por hacer en el dominio (una sola vez, no por DC):
    - Importar y enlazar la GPO de auditoria a la OU Domain Controllers
    - Meter la cuenta de equipo de este DC en el grupo de security filtering
    - Reiniciar el DC (o klist -li 0x3e7 purge) para que el token coja el grupo.
      Sin esto la GPO no se aplica aunque gpupdate diga que si.
"@ -ForegroundColor Gray
