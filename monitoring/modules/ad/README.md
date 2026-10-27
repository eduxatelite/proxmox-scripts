# Módulo ad

- Prometheus: job `windows_dc` → windows_exporter :9182 en cada DC (`AD_DCS="NOMBRE:IP ..."`), label `dc_name`.
- Loki: los DCs hacen push con Grafana Alloy (`job="windows_security"`, `host=<DC>`). Sus IPs se añaden solas a la lista blanca del 3100.
- Agente: `agentes/windows/instalar-agentes-windows.ps1 -MonitoringVM <IP_VM> -DCName <DC>`
- GPO de auditoría: ver `docs/INVENTARIO-STACK.md` §8 (Backup-GPO / Import-GPO).
