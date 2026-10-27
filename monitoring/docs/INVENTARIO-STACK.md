# Inventario del stack de monitorización — para replicar por cliente

> **Nota (estandarización):** este inventario viene de la primera implantación y sirve de guía. En el repo, todo lo de la VM lo hace `install.sh` con módulos; el cron de Jump Desktop lo genera el módulo `jumpdesktop` (`/etc/cron.d/jumpdesktop`).

Todo lo que se montó en la primera implantación, separado por **lo que puede ir en el
script** y **lo que hay que hacer por cliente**.

---

## 1. Lo que ya tienes cubierto

- VM creada por script
- Grafana + Loki + Prometheus instalados en Docker

---

## 2. Contenedores que faltan en tu compose

Además de los tres que ya tienes:

| Servicio | Imagen | Para qué | Puertos |
|---|---|---|---|
| `promtail` | `grafana/promtail:latest` | Recibe syslog y lee ficheros locales | 9080, 1514/udp, 1515/tcp, 1516/tcp |
| `snmp-exporter` | `prom/snmp-exporter:latest` | Métricas de FortiGate y Synology | 9116 (solo interno) |
| `pve-exporter` | `prompve/prometheus-pve-exporter:latest` | Métricas de Proxmox | 9221 (solo interno) |

`snmp-exporter` y `pve-exporter` **no deben publicar puertos** al host, van solo
por la red interna de Docker.

---

## 3. Estructura de ficheros de configuración

```
/opt/grafana-stack/
├── docker-compose.yml
├── .env                          ← chmod 600, aquí TODOS los secretos
├── config/
│   ├── grafana/
│   │   └── provisioning/
│   │       ├── datasources/      ← Prometheus y Loki automáticos
│   │       └── alerting/
│   │           └── alert-rules.yaml
│   ├── prometheus/
│   │   └── prometheus.yml
│   ├── loki/
│   │   └── loki-config.yml
│   ├── promtail/
│   │   └── promtail-config.yml
│   ├── snmp-exporter/
│   │   └── snmp.yml              ← chmod 600, lleva la community
│   └── pve-exporter/
│       └── pve.yml               ← chmod 600, lleva credenciales
└── dashboards/
    └── *.json
```

**Importante para el provisioning de datasources:** si los generas por fichero,
fija tú los UID en lugar de dejar que Grafana los invente. Así el
`alert-rules.yaml` y los dashboards funcionan igual en todos los clientes sin
tener que hacer `sed` de UIDs cada vez.

```yaml
# config/grafana/provisioning/datasources/datasources.yml
apiVersion: 1
datasources:
  - name: Prometheus
    type: prometheus
    uid: PBFA97CFB590B2093      # fíjalo igual en todos los clientes
    url: http://prometheus:9090
    isDefault: true
  - name: Loki
    type: loki
    uid: P8E80F9AEF21F6940
    url: http://loki:3100
```

---

## 4. Paquetes del sistema

```bash
dnf install -y net-snmp-utils nmap-ncat tcpdump iptables-services
```

- `net-snmp-utils` → `snmpwalk` para verificar dispositivos
- `nmap-ncat` → pruebas de puertos syslog
- `tcpdump` → diagnóstico de tráfico que no llega
- `iptables-services` → persistir las reglas de firewall

---

## 5. Firewall (esto se olvida y es importante)

**Docker se salta firewalld**, así que las reglas van en la cadena `DOCKER-USER`:

```bash
# Loki 3100 solo accesible desde los agentes que hacen push
iptables -I DOCKER-USER -p tcp --dport 3100 -s <IP_DC1> -j ACCEPT
iptables -I DOCKER-USER -p tcp --dport 3100 -s <IP_DC2> -j ACCEPT
iptables -A DOCKER-USER -p tcp --dport 3100 -j DROP

iptables-save > /etc/sysconfig/iptables
systemctl enable iptables
```

Los ACCEPT tienen que ir **antes** del DROP. Verificar con:
```bash
iptables -L DOCKER-USER -n --line-numbers
```

---

## 6. Poller y watcher de Jump Desktop

```
/opt/jumpdesktop-poller/
├── jumpdesktop_logs.py      ← poller, tira de la API
├── jd_watcher.py            ← detección de anomalías
├── .env                     ← TEAM_ID y API_TOKEN, chmod 600
└── state/                   ← known_ips.json, geo_cache.json, processed_ids.json

/var/log/jumpdesktop/        ← connections.log, activity.log, anomalies.log
```

Cron:
```
*/5 * * * * set -a; . /opt/jumpdesktop-poller/.env; set +a; /usr/bin/python3 /opt/jumpdesktop-poller/jumpdesktop_logs.py >> /var/log/jumpdesktop-poller.log 2>&1
*/5 * * * * /usr/bin/flock -n /tmp/jd_watcher.lock env LEARNING_MODE=1 /usr/bin/python3 /opt/jumpdesktop-poller/jd_watcher.py >> /var/log/jumpdesktop-watcher.log 2>&1
```

**Dos cosas a tener en cuenta:**
- Los logs del propio cron van **fuera** de `/var/log/jumpdesktop/`, si no Promtail los ingiere como si fueran eventos
- El watcher arranca en `LEARNING_MODE=1` y hay que quitarlo a las 1-2 semanas. Ponlo en el checklist del cliente, es fácil de olvidar

---

## 7. Agentes en máquinas Windows (los DCs)

Esto es lo más repetitivo y lo que más se agradece automatizar. Ver
`instalar-agentes-windows.ps1`.

**windows_exporter**
- MSI de `prometheus-community/windows_exporter`
- Colectores: `ad,dns,cpu,memory,logical_disk,os,service,net,system,time`
- Puerto 9182
- Firewall Exception del instalador **desactivado**, y regla propia restringida a la IP de la VM
- El campo "config file" del instalador **vacío**, si no el servicio no arranca

**Grafana Alloy**
- Instalador de `grafana/alloy`
- `config.alloy` con `loki.source.windowsevent` del log Security
- Carpeta de bookmarks creada a mano: `C:\ProgramData\GrafanaLabs\Alloy\bookmarks`
- El label `host` tiene que llevar el nombre del DC, es el fallo típico al copiar la config entre máquinas

---

## 8. GPO de auditoría — automatizable con backup e import

Esto es el hallazgo más útil para replicar: **puedes exportar la GPO de un cliente ya configurado
e importarla en cada cliente** en lugar de configurarla a mano.

```powershell
# En un cliente ya configurado, una sola vez
Backup-GPO -Name "AD-Audit-Policy" -Path "C:\GPO-Templates"

# En cada cliente nuevo
New-GPO -Name "AD-Audit-Policy"
Import-GPO -BackupGpoName "AD-Audit-Policy" -TargetName "AD-Audit-Policy" `
           -Path "\\ruta\GPO-Templates" -CreateIfNeeded
New-GPLink -Name "AD-Audit-Policy" -Target "OU=Domain Controllers,DC=...,DC=..."
```

Contenido de la GPO:
- Advanced Audit Policy: Logon, Account Lockout, Credential Validation, Kerberos Auth, User Account Mgmt, Security Group Mgmt (Success+Failure); Computer Account Mgmt y Audit Policy Change (Success)
- Security Options → "Force audit policy subcategory settings" = Enabled
- Event Log → Maximum security log size = 1048576 KB

**Y el detalle que cuesta media hora si no lo sabes:** si usas security
filtering con un grupo, la pertenencia no se aplica hasta que el equipo
renueva su ticket Kerberos. O `klist -li 0x3e7 purge` o reinicio. No basta con
`gpupdate /force`.

---

## 9. FortiGate — automatizable por SSH

```
config system snmp sysinfo
    set status enable
    set description "<CLIENTE>"
end
config system snmp community
    edit 1
        set name "<COMMUNITY>"
        config hosts
            edit 1
                set ip <IP_VM> 255.255.255.255
            next
        end
        set query-v2c-status enable
        set trap-v1-status disable
        set trap-v2c-status disable
    next
end

config log syslogd setting
    set status enable
    set server "<IP_VM>"
    set port 1515
    set mode reliable
    set format rfc5424
end

config log syslogd filter
    set severity information
    set forward-traffic disable
    set local-traffic disable
    set multicast-traffic disable
    set sniffer-traffic disable
end
```

**Dos cosas críticas:**
- Hay que habilitar SNMP en el **acceso administrativo de la interfaz** (o VLAN) por la que entra la consulta. Sin esto no responde aunque el agente esté activo
- Desactivar el log de tráfico **no es opcional**. Con `forward-traffic enable` el FortiGate metió 200 MB en 20 minutos (unos 14 GB/día). Con el filtro puesto, unos pocos MB

---

## 10. Synology

SNMP y syslog se pueden configurar por SSH si está habilitado, pero por GUI es
más rápido y menos frágil:

- **Control Panel → Terminal & SNMP → SNMP:** activar SNMPv2, community, restringir a la IP de la VM
- **Log Center → Log Sending:** servidor = IP de la VM, puerto 1516, TCP, formato **IETF (RFC 5424)**

**El formato importa:** Promtail solo parsea RFC5424. Con BSD/RFC3164 los logs
no entran y parece un problema de red.

---

## 11. Lo que hay que parametrizar por cliente

Un `vars.env` o similar con:

```bash
CLIENTE=cliente
VM_IP=<IP_VM>
SNMP_COMMUNITY=<generar con openssl rand -hex 12>

DC1_NAME=DC01
DC1_IP=<IP_DC1>
DC2_NAME=DC02
DC2_IP=<IP_DC2>

FORTIGATE_IP=<IP_FORTIGATE>
NAS_PRINCIPAL_IP=<IP_NAS>
NAS_PRINCIPAL_NAME=nas01
NAS_VOLUME=/volume1

PROXMOX_NODE_IP=<IP_PVE>

GRAFANA_ADMIN_PASSWORD=<generar>
GRAFANA_SMTP_PASSWORD=<del tenant>
ALERT_CONTACT_EMAIL=<destinatario>

JUMPDESKTOP_TEAM_ID=<del panel>
JUMPDESKTOP_API_TOKEN=<del panel>

PROMETHEUS_RETENTION=90d
LOKI_RETENTION=8760h
```

Con `envsubst` sobre plantillas `.tmpl` resuelves casi todo:

```bash
for f in config/**/*.tmpl; do
  envsubst < "$f" > "${f%.tmpl}"
done
```

---

## 12. Umbrales que hay que revisar por cliente

Las alertas no son universales, estos valores dependen del tamaño del cliente:

| Alerta | Valor por defecto | Depende de |
|---|---|---|
| Fuerza bruta AD (4625) | >10 por usuario/IP en 5m | Nº de empleados |
| Cuentas bloqueadas | >3 distintas en 10m | Política de passwords |
| Sesiones FortiGate | >40000 | Modelo del firewall y nº de usuarios |
| Logins fallidos DSM | >4 en 10m | Nº de usuarios del NAS |
| Volumen NAS lleno | >90% | Tamaño del volumen |
| Disco DC | <10% libre | — |

Los de disco y estado de RAID sí son universales.

---

## 13. Checklist por cliente nuevo

**En la VM (script)**
- [ ] VM creada
- [ ] Docker + compose con los 6 servicios
- [ ] Configs generadas desde plantillas con las vars del cliente
- [ ] Datasources provisionados con UID fijos
- [ ] `alert-rules.yaml` con los umbrales ajustados
- [ ] Dashboards importados
- [ ] Reglas DOCKER-USER + persistencia
- [ ] Poller y watcher de Jump Desktop + cron
- [ ] Contact point y notification policy

**En los DCs (script PowerShell)**
- [ ] windows_exporter + regla de firewall
- [ ] Alloy + config con el nombre del DC correcto
- [ ] GPO importada y enlazada
- [ ] Grupo de security filtering con las cuentas de equipo
- [ ] Reinicio o purge de tickets para que aplique

**En los dispositivos**
- [ ] FortiGate: SNMP + syslog + filtro + SNMP en la interfaz
- [ ] Synology: SNMP + Log Sending en RFC5424
- [ ] Verificar cada uno con `snmpwalk` y con `{job="..."}` en Loki

**Post-instalación**
- [ ] Medir volumen de Loki a las 24h
- [ ] Calibrar umbrales tras una semana
- [ ] Quitar `LEARNING_MODE` a las 1-2 semanas
- [ ] Verificar que todos los targets están UP y ninguna alerta en Error

---

## 14. Cosas que a día de hoy quedan fuera y podrías añadir

- `node_exporter` en los nodos Proxmox y en la propia VM
- `snmp_exporter` contra el SAI (módulo apcups o el del fabricante)
- Retención específica por stream para las fuentes que más volumen generan
- `blackbox_exporter` para checks de disponibilidad
- Métricas de servidores de licencias (RLM/FlexLM) donde aplique
- Deadline u otro scheduler de render donde aplique
