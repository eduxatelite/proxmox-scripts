# =============================================================================
# rocky9-base.ks — Kickstart file para Rocky 9.6
# Instalación desatendida para VMs VFX en Proxmox
# =============================================================================

# --- Método de instalación ---
install
cdrom
text                        # Sin interfaz gráfica
reboot                      # Reinicia sola al acabar

# --- Idioma y teclado ---
lang en_US.UTF-8
keyboard --vckeymap=es --xlayouts='es'

# --- Zona horaria ---
timezone Europe/Madrid --utc

# --- Red: DHCP, hostname genérico (cada script lo cambia luego) ---
network --bootproto=dhcp --device=eth0 --onboot=yes --activate
network --hostname=rocky-vm

# --- Contraseña root ---
rootpw --plaintext Ab12345

# --- Seguridad: SELinux OFF, Firewall OFF ---
selinux --disabled
firewall --disabled

# --- Bootloader ---
bootloader --location=mbr --append="rhgb quiet"
zerombr
clearpart --all --initlabel

# --- Particionado: 50 GB totales ---
# /boot  : 1 GB
# swap   : 4 GB
# /      : resto (~45 GB)
part /boot --fstype=xfs  --size=1024
part swap  --fstype=swap --size=4096
part /     --fstype=xfs  --size=1 --grow

# --- Paquetes: Server minimal + herramientas básicas ---
%packages --ignoremissing
@^minimal-environment
@standard
bash-completion
curl
wget
git
vim
net-tools
bind-utils
tar
unzip
python3
python3-pip
open-vm-tools           # Por si acaso, no daña
qemu-guest-agent        # IMPRESCINDIBLE para que Proxmox pueda hablar con la VM
%end

# --- Post-instalación: actualizar sistema y habilitar agente QEMU ---
%post --log=/root/kickstart-post.log
#!/bin/bash

echo "=== Actualizando sistema ==="
dnf update -y

echo "=== Habilitando QEMU Guest Agent ==="
systemctl enable qemu-guest-agent
systemctl start  qemu-guest-agent

echo "=== Deshabilitando SELinux definitivamente ==="
sed -i 's/^SELINUX=.*/SELINUX=disabled/' /etc/selinux/config

echo "=== Configurando SSH: permitir root login ==="
sed -i 's/^#PermitRootLogin.*/PermitRootLogin yes/' /etc/ssh/sshd_config
sed -i 's/^PermitRootLogin.*/PermitRootLogin yes/'  /etc/ssh/sshd_config

echo "=== Listo ==="
%end
