# Stack de monitorización Xatélite

Despliegue estandarizado del stack de observabilidad para clientes:
**Grafana, Prometheus, Loki, Promtail, node-exporter** + módulos por cliente
(FortiGate, Synology, AD, Proxmox, Jump Desktop, Deadline, Nuke).

Objetivo: que cualquiera del equipo pueda levantar la monitorización de un
cliente nuevo sin depender de quien la montó, y que mantener la de un cliente
existente no implique reaprender cómo está hecha.

> Vive en `proxmox-scripts/monitoring/` (repo público). **Nada de clientes
> entra aquí**: IPs, contraseñas, tokens y community SNMP solo existen en el
> `.env` de cada VM. Antes de cada push: `git diff --cached | grep -iE "password|token|community|192\.168"`.

---

## Desplegar un cliente nuevo — un solo link

En **un nodo Proxmox del cliente**, como root:

```bash
bash <(curl -fsSL https://raw.githubusercontent.com/eduxatelite/proxmox-scripts/main/monitoring/deploy.sh)
```

Descarga el repo y ejecuta `deploy.sh`:

1. **Asistente módulo a módulo.** Para cada dashboard pregunta si hace falta;
   si es que no pasa al siguiente, si es que sí pide sus IPs:

   | Pregunta | Pide | Trae |
   |---|---|---|
   | ¿FortiGate? | IP (propone el gateway) | dashboard FortiGate, SNMP, 7 alertas |
   | ¿Proxmox? | nodos (los detecta del cluster) | dashboard Proxmox. **Crea él solo** el usuario `monitoring@pve` + token; node_exporter opcional por SSH |
   | ¿NAS Synology? | nombre:ip de cada NAS | dashboard NAS (RAID, discos, volúmenes, logs DSM), 8 alertas |
   | ¿NAS TrueNAS? | nombre:ip, usuario y API key de cada NAS | dashboard TrueNAS (pools, discos, temperaturas, scrub, alertas del propio TrueNAS) + logs, 9 alertas |
   | ¿Domain Controllers? | NOMBRE:ip (propone los DNS) | dashboard DCs (servicios, replicación, 4625/4740...), 12 alertas |
   | └ ¿Auditoría TPN? | — | dashboard de auditoría de 28 paneles |
   | ¿Jump Desktop? | Team ID, token, horario | anomalías de conexión, 5 alertas |
   | ¿Deadline? | IP del Web Service | dashboard de la granja |
   | ¿Licencias Nuke? | IP del servidor RLM | dashboard de licencias |

   Más: contraseña de Grafana y community SNMP (se generan), correo de alertas
   y URL del Uptime Kuma.
2. **Crea la VM** Rocky 9 (`lib/common.sh` del repo), 4 vCPU / 8 GB / 100 GB por
   defecto, con `onboot: 1`. Imagen del FTP de Madrid o, si no llega, la oficial.
3. **Instala el stack** en la VM por SSH (clave del nodo inyectada por cloud-init).
4. **Cambia la contraseña root** de la VM y muestra el resumen: URL, contraseñas,
   IP/MAC para reservar en el DHCP y lo que hay que pegar en FortiGate/DSM/DCs.

Todas las preguntas van al principio; luego son ~10 minutos desatendidos.

### Cambios posteriores

Dentro de la VM:

```bash
cd /opt/monitoring-stack-src
./configurar.sh /root/monitoring-<cliente>.env     # mismo asistente, Enter = mantener
./install.sh --env /root/monitoring-<cliente>.env  # o editar el .env a mano y relanzar
```

Probar sin tocar nada: `./install.sh --env /root/monitoring-<cliente>.env --render-only --target /tmp/prueba`

### Sin el link (VM ya creada)

```bash
dnf -y install git
git clone https://github.com/eduxatelite/proxmox-scripts.git /opt/proxmox-scripts
cd /opt/proxmox-scripts/monitoring && ./install.sh     # sin argumentos = asistente
```

---

## Estructura

```
deploy.sh               Un solo paso desde el nodo Proxmox: asistente + VM + instalación
install.sh              Instalador del stack (se ejecuta en la VM, idempotente)
configurar.sh           Asistente: módulo a módulo, pide IPs y genera el .env
lib/common.sh           Render de plantillas, helpers
core/                   Lo que lleva TODA instalación
  docker-compose.yml      grafana, prometheus, loki, promtail, node-exporter
  config/                 .tmpl → se renderizan con el .env del cliente
    grafana/provisioning/   datasources con UID fijos, alertas del stack, contact point
  system/                 daemon.json, firewall DOCKER-USER, heartbeat (systemd)
modules/<modulo>/       Se activan con MODULES="..." en el .env
  module.sh               descripción, dependencias, defaults, validación, hooks
  compose.yml             servicios extra (se une al core vía COMPOSE_FILE)
  scrape.yml.tmpl         jobs de Prometheus → config/prometheus/scrape.d/
  promtail.yml.tmpl       jobs de Promtail (se añaden al config base)
  alerts.yaml.tmpl        reglas de alerta → provisioning/alerting/<modulo>.yaml
  dashboards/*.json       → carpeta de Grafana con el nombre del módulo
  build/                  Dockerfile + código de exporters propios
agentes/                Windows (windows_exporter + Alloy) y Jump Desktop
clientes/               Solo cliente.env.example. Los .env reales NO van aquí
tools/                  comprobar-onboot.sh, instalar-node-exporter.sh
docs/                   Inventario, manuales y notas de operación
```

| Módulo | Qué añade | Variables obligatorias |
|---|---|---|
| `fortigate` | syslog TCP 1515/UDP 1514, SNMP, 7 alertas, dashboard | `FORTIGATE_IP`, `SNMP_COMMUNITY` |
| `synology` | dashboard NAS, syslog TCP 1516, SNMP (RAID, discos, volumen), 8 alertas | `NAS_TARGETS`, `SNMP_COMMUNITY` |
| `truenas` | exporter propio por API (WebSocket), syslog TCP 1517, dashboard en la carpeta NAS, 9 alertas | `TRUENAS_TARGETS`, `TRUENAS_API_KEYS` |
| `ad` | dashboard DCs, windows_exporter, eventos 4625/4740/..., 12 alertas | `AD_DCS` |
| `proxmox` | pve-exporter (token), node_exporter opcional, dashboard | `PVE_NODES`, `PVE_TOKEN_VALUE` |
| `jumpdesktop` | poller + watcher + cron, 5 alertas | `JUMPDESKTOP_TEAM_ID`, `JUMPDESKTOP_API_TOKEN` |
| `tpn-audit` | dashboard de auditoría de seguridad (28 paneles) | — (requiere `ad`) |
| `deadline` | exporter del Web Service, dashboard de granja | `DEADLINE_HOST` |
| `nuke` | exporter RLM (rlmutil), dashboard de licencias | `RLM_HOST` |
| `snmp` | snmp_exporter (automático con fortigate/synology) | `SNMP_COMMUNITY` |

---

## Cómo se parametriza

- Los `.tmpl` se renderizan con `envsubst` **restringido a variables en
  MAYÚSCULAS definidas**: los `{{ $labels.x }}` de Grafana no se tocan. Si queda
  algún `${VAR}` sin definir, el instalador se para y dice cuál falta.
- Las listas de equipos van como `nombre:ip` separados por espacios
- Los umbrales que dependen del tamaño del cliente son variables `ALERT_*`
  con valores por defecto ya calibrados en producción (tabla en `docs/INVENTARIO-STACK.md` §12).
- Versiones de imágenes **fijadas** en el compose; se cambian con `*_VERSION` en el `.env`.

## Secretos

**Nada con credenciales reales entra en el repo.** Los valores viven en el
gestor de contraseñas; en la VM solo existen en `/opt/grafana-stack/.env` (600).

- `snmp.yml` ya no lleva la community: snmp_exporter la lee de `SNMP_COMMUNITY`
  (`--config.expand-environment-variables`).
- pve-exporter lee el token de variables de entorno: no hay `pve.yml`.
- Antes de cada push: `git diff --cached | grep -iE "password|token|community"`.

---

## Tres cosas que van sí o sí en la plantilla base

Son las que han provocado averías reales:

| | Avería | Dónde está resuelto |
|---|---|---|
| `restart: unless-stopped` en todos los servicios | Loki 7 semanas caído tras un reinicio | Todos los compose; `install.sh` avisa si algún contenedor no la tiene |
| Límite de logs de Docker | Log del Loki muerto de 31 GB, disco al 78 % | `/etc/docker/daemon.json` + `logging:` en cada servicio |
| `onboot: 1` en la VM | VM caída 82 días sin que nadie se enterase | `lib/common.sh` de proxmox-scripts lo pone al crear; `tools/comprobar-onboot.sh --fix` para las existentes |

## Vigilancia del propio stack

Las alertas de un stack no pueden avisar de que el stack está caído:

- **Uptime Kuma** en el CPD de Xatélite, un push monitor por cliente → `HEARTBEAT_URL`
- `xat-heartbeat.timer` (cada 5 min) solo manda el latido si Loki, Grafana y
  Prometheus responden de verdad
- Alerta `[0a]` de disco de la VM y `[0b]` de cualquier exporter caído
- Pendiente: check externo gratuito vigilando al propio Kuma

---

## Pendiente

- [ ] **Primer deploy real** con el link en un nodo de laboratorio (con todos los módulos)
- [ ] `jumpdesktop_logs.py` (poller) no está en el repo → añadir a `agentes/jumpdesktop/`
- [ ] Desplegar Uptime Kuma central + check externo
- [ ] Revisar `onboot` en todas las VMs de todos los clientes
- [ ] Migrar Promtail → Grafana Alloy (Promtail está en fin de vida)
