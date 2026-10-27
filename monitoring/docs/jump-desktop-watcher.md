# Alertas del stack de monitorización

VM: `<IP_VM>` (monitorización)

## Qué incluye

| Archivo | Qué es |
|---|---|
| `jd_watcher.py` | Detecta anomalías en Jump Desktop: IP nueva por usuario, país nuevo, fuera de horario y auth fallidos |
| `alert-rules.yaml` | Las 28 reglas de alerta, listas para importar en Grafana |

Están **todas** las que pidió Jorge. Se cargan de una sola vez, pero las que
dependen de infraestructura que aún no existe entran **en pausa**: aparecen en
Grafana, no evalúan nada, y se activan con un click cuando la fuente esté lista.

| Grupo | Reglas | Estado |
|---|---|---|
| Active Directory (1-8) | 9 | Activas |
| Jump Desktop (15-17) | 4 | Activas, requieren `jd_watcher.py` |
| FortiGate (11-14) | 6 | En pausa |
| Synology (18-21) | 5 | En pausa |
| Transversal (22) | 4 | 2 activas, 2 en pausa |

### Qué hace falta para activar cada pausada

| Reglas | Qué falta |
|---|---|
| 11, 12, 13 | Que el job `fortigate` reciba logs (pendiente del cambio a RFC5424 tras el firmware) |
| 14a, 14b, 14c | `snmp_exporter` apuntando al FortiGate |
| 18a, 18b, 19 | `snmp_exporter` con el MIB de Synology |
| 20, 21 | Activar Log Sending en Log Center del Synology |

### Cómo activarlas cuando toque

Editas `alert-rules.yaml`, cambias `isPaused: true` por `false` en las reglas
correspondientes, y reinicias Grafana. También se puede desde la UI, pero al ser
provisionadas el cambio se perdería en el siguiente reinicio, así que mejor
tocarlo en el archivo.

### ⚠️ Nombres de métricas a verificar

Las reglas de SNMP (FortiGate y Synology) usan nombres de métrica estándar
(`fgSysCpuUsage`, `synologyRaidStatus`, etc.) pero el nombre real depende del
módulo SNMP y de la versión de `snmp_exporter` que se acabe usando. Cuando se
monte, hay que comprobar los nombres reales antes de quitar la pausa.

Lo mismo con los patrones de texto de los logs de FortiGate y Synology: están
basados en los mensajes habituales, pero conviene mirar un log real y ajustarlos.

---

## Parte 1 — Watcher de Jump Desktop

### Instalar

```bash
cp jd_watcher.py /opt/jumpdesktop-poller/
chmod +x /opt/jumpdesktop-poller/jd_watcher.py
mkdir -p /opt/jumpdesktop-poller/state
```

### Modo aprendizaje (importante)

Si lo activas en frío, marcará **todas** las IPs como nuevas porque no conoce ninguna.
Déjalo 1-2 semanas aprendiendo antes de activar las alertas:

```bash
LEARNING_MODE=1 python3 /opt/jumpdesktop-poller/jd_watcher.py
```

Y en el cron, junto al poller:

```
*/5 * * * * set -a; . /opt/jumpdesktop-poller/.env; set +a; /usr/bin/python3 /opt/jumpdesktop-poller/jumpdesktop_logs.py >> /var/log/jumpdesktop-poller.log 2>&1
*/5 * * * * LEARNING_MODE=1 /usr/bin/python3 /opt/jumpdesktop-poller/jd_watcher.py >> /var/log/jumpdesktop-watcher.log 2>&1
```

Cuando quieras activarlo de verdad, quitas `LEARNING_MODE=1` de la línea.

Para ver qué ha aprendido:

```bash
python3 -m json.tool /opt/jumpdesktop-poller/state/known_ips.json
```

### Configuración disponible

| Variable | Por defecto | Qué hace |
|---|---|---|
| `LEARNING_MODE` | `0` | A `1` registra pero no alerta |
| `JD_WORK_START` | `8` | Hora de inicio del horario laboral |
| `JD_WORK_END` | `20` | Hora de fin |
| `JD_ALERT_WEEKENDS` | `1` | A `0` no alerta en fin de semana |
| `JD_GEO_ENABLED` | `1` | A `0` desactiva la geolocalización |

### ⚠️ Nota sobre la geolocalización y TPN

Por defecto usa la API gratuita de `ip-api.com`, lo que implica **enviar las IPs
públicas de los usuarios a un tercero**. El resultado se cachea, así que cada IP
se consulta una sola vez, pero conviene valorarlo antes de dejarlo en producción.

Alternativa sin salida a internet: base de datos local GeoLite2 de MaxMind
(gratuita con registro) usando la librería `geoip2`. Requiere mantener el `.mmdb`
actualizado. Si se prefiere esa vía, hay que cambiar la función `geo_lookup`.

Con `JD_GEO_ENABLED=0` funciona todo menos la detección de país nuevo.

### ⚠️ Ojo con el log del cron

En el cron actual el `poller.log` se escribe dentro de `/var/log/jumpdesktop/`,
que Promtail recoge con un glob `*.log`. Eso mete líneas de INFO del propio script
en Loki como si fueran eventos. En el cron de arriba está corregido para escribir
fuera de esa carpeta.

---

## Parte 2 — Reglas de alerta en Grafana

### 1. Obtener los UID de los datasources

```bash
curl -s -u admin:TU_PASSWORD http://localhost:3000/api/datasources | \
  python3 -c "import sys,json; [print(d['name'], '->', d['uid']) for d in json.load(sys.stdin)]"
```

### 2. Sustituirlos en el archivo

```bash
sed -i 's/PROM_UID/el_uid_de_prometheus/g; s/LOKI_UID/el_uid_de_loki/g' alert-rules.yaml
```

### 3. Copiar al directorio de provisioning

```bash
mkdir -p /opt/grafana-stack/config/grafana/provisioning/alerting
cp alert-rules.yaml /opt/grafana-stack/config/grafana/provisioning/alerting/
```

Verifica que ese directorio está montado en el contenedor. En el
`docker-compose.yml`, el servicio de Grafana debe tener algo como:

```yaml
    volumes:
      - ./config/grafana/provisioning:/etc/grafana/provisioning
```

Si no lo tiene, hay que añadirlo.

### 4. Reiniciar Grafana

```bash
docker compose restart grafana
docker logs grafana --tail 40 | grep -i alert
```

### 5. Verificar

En Grafana → **Alerting → Alert rules**, debe aparecer la carpeta `Alertas` con
los tres grupos. Las reglas provisionadas salen con un candado y no se pueden
editar desde la UI, solo desde el archivo.

---

## Antes de dar por buenas las reglas

Dos nombres de métrica hay que confirmar, porque cambian entre versiones de
`windows_exporter`:

```bash
curl -s http://<IP_DC2>:9182/metrics | grep "windows_service_state" | head -3
```

Si no devuelve nada, mira cómo se llama:

```bash
curl -s http://<IP_DC2>:9182/metrics | grep -E "^windows_service" | head -5
```

Y ajusta la regla `ad_ntds_down` en consecuencia. Puede llamarse
`windows_service_state` o `windows_service_status` según la versión.

## Calibración

Los umbrales de las reglas basadas en logs (fuerza bruta a 20, lockouts a 3,
auth fallidos a 5) son un punto de partida, no un valor definitivo. Conviene
dejarlas una semana sin canal de notificación, ver cuántas veces saltarían con
tráfico real, y ajustar antes de conectarlas al correo o a Chat.

## Infraestructura pendiente

Para poder quitar la pausa a las 13 reglas restantes:

**FortiGate**
```bash
# Comprobar si el job ya recibe logs
curl -s "http://localhost:3100/loki/api/v1/label/job/values" | python3 -m json.tool
```
Si `fortigate` no aparece, sigue comentado en Promtail a la espera del cambio de
formato a RFC5424 tras la actualizacion de firmware.

**snmp_exporter** (necesario para FortiGate 14 y Synology 18-19)
Se anade como contenedor al stack, con los modulos de Fortinet y Synology, y un
job en `prometheus.yml` por cada dispositivo.

**Synology syslog**
Control Panel > Log Center > Log Sending. Servidor `<IP_VM>`, puerto
`1514`, protocolo TCP. Ojo con el formato: si los logs entran mal parseados,
probar el otro formato (BSD o IETF RFC5424).
