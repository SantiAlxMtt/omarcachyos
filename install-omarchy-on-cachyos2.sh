#!/bin/bash
set -e # Aborta inmediatamente si ocurre un error crítico

echo "======================================================="
echo "  Arquitecto CachyOS: Integración Segura con Omarchy   "
echo "  Kernel: CachyOS Nativo | Visual: Omarchy (Hyprland)  "
echo "  Hardware: Intel Iris Xe                              "
echo "======================================================="

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
OMARCHY_DIR="$SCRIPT_DIR/omarchy-src"

echo "[1/5] Obteniendo código fuente de Omarchy..."
if [ ! -d "$OMARCHY_DIR" ]; then
    git clone https://github.com/basecamp/omarchy "$OMARCHY_DIR"
else
    echo "[*] Directorio existente. Limpiando parches previos y actualizando..."
    cd "$OMARCHY_DIR"
    git reset --hard HEAD
    git pull
    cd "$SCRIPT_DIR"
fi

echo "[2/5] Instalando dependencias exclusivas (iwd, plymouth)..."
sudo pacman -S --needed --noconfirm iwd plymouth

echo "[3/5] Configurando llaves y repositorio pacman..."
sudo pacman-key --recv-keys F0134EE680CAC571
sudo pacman-key --lsign-key F0134EE680CAC571

if ! grep -q '^\[omarchy\]' /etc/pacman.conf; then
    echo -e "\n[omarchy]\nSigLevel = Optional TrustedOnly\nServer = https://pkgs.omarchy.org/\$arch" | sudo tee -a /etc/pacman.conf > /dev/null
fi
sudo pacman -Syu --noconfirm

# Purgar SDDM correctamente (Archivo y Servicio)
if [ -f /etc/sddm.conf ]; then
    echo "[*] Purgando rastro y servicio de SDDM..."
    sudo rm -f /etc/sddm.conf
fi
sudo systemctl disable sddm.service 2>/dev/null || true

echo ""
read -p "Ingresa tu nombre de usuario (Nombre y Apellido): " OMARCHY_USER_NAME
export OMARCHY_USER_NAME

read -p "Ingresa tu correo electrónico: " OMARCHY_USER_EMAIL
export OMARCHY_USER_EMAIL

echo "[4/5] Aplicando parches de compatibilidad arquitectónica..."
cd "$OMARCHY_DIR"

# 4.1 Evitar conflictos de paquetes base y proteger el Kernel de CachyOS
sed -i '/tldr/d' install/omarchy-base.packages
sed -i '/run_logged \$OMARCHY_INSTALL\/preflight\/pacman\.sh/d' install/preflight/all.sh
sed -i '/run_logged \$OMARCHY_INSTALL\/post-install\/pacman\.sh/d' install/post-install/all.sh

sed -i '/bootloader/d' install/preflight/all.sh 2>/dev/null || true
find install/preflight -type f -exec sed -i '/Omarchy install requires: Limine bootloader/d' {} + 2>/dev/null || true

# Asegurar que los scripts de actualización busquen linux-cachyos, no linux vanilla
sed -i "s/ | sed 's\/-arch\/\\\.arch\/'//" bin/omarchy-update-restart
sed -i "s/'{print \$2}'/'{print \$2 \"-\" \$1}' | sed 's\/-linux\/\/'/" bin/omarchy-update-restart
sed -i 's/pacman -Q linux /pacman -Q linux-cachyos /g' bin/omarchy-update-restart

# 4.2 Forzar hardware Intel Iris Xe
echo "# Hardware Intel Iris Xe detectado. Omitiendo rutinas de Nvidia." > install/config/hardware/nvidia.sh
chmod +x install/config/hardware/nvidia.sh

# Fix enlaces simbólicos
sed -i 's/ln -s/ln -sf/' install/config/omarchy-ai-skill.sh

# 4.3 Evitar que Omarchy reescriba el Bootloader (Dejamos el control a CachyOS/systemd-boot)
sed -i '/run_logged \$OMARCHY_INSTALL\/login\/limine-snapper\.sh/d' install/login/all.sh
sed -i '/run_logged \$OMARCHY_INSTALL\/login\/alt-bootloaders\.sh/d' install/login/all.sh

# 4.4 Inyección segura de Plymouth para Omarchy Logo
cat > install/login/plymouth.sh << EOF
#!/bin/bash
sudo mkdir -p /usr/share/plymouth/themes/omarchy
# Usamos la ruta absoluta al directorio de Omarchy para evitar fallos de path
sudo cp -r "$OMARCHY_DIR/default/plymouth/"* /usr/share/plymouth/themes/omarchy/

# Inyección segura en mkinitcpio.conf
if ! grep -q "plymouth" /etc/mkinitcpio.conf; then
    sudo sed -i 's/\b\(udev\|systemd\)\b/& plymouth/' /etc/mkinitcpio.conf
fi

# Inyección segura en /etc/kernel/cmdline (solo en la primera línea)
if [ -f /etc/kernel/cmdline ]; then
    if ! grep -q "splash" /etc/kernel/cmdline; then
        sudo sed -i '1 s/$/ quiet splash loglevel=3 rd.udev.log_priority=3 vt.global_cursor_default=0/' /etc/kernel/cmdline
        if command -v sdboot-manage &> /dev/null; then
            sudo sdboot-manage gen
        fi
    fi
fi

sudo plymouth-set-default-theme -R omarchy
sudo mkinitcpio -P
EOF
chmod +x install/login/plymouth.sh

# 4.5 Deshabilitar wpa_supplicant y anclar IWD a NetworkManager (Vía conf.d)
cat > install/config/hardware/network.sh << 'NETEOF'
#!/bin/bash
sudo systemctl disable --now wpa_supplicant.service 2>/dev/null || true
sudo systemctl enable --now iwd.service

sudo mkdir -p /etc/NetworkManager/conf.d
if [ ! -f /etc/NetworkManager/conf.d/wifi_backend.conf ]; then
  echo -e "[device]\nwifi.backend=iwd" | sudo tee /etc/NetworkManager/conf.d/wifi_backend.conf > /dev/null
  sudo systemctl restart NetworkManager
fi
NETEOF
chmod +x install/config/hardware/network.sh

# Pinning de Walker
sed -i '1a\
if ! grep -q "^IgnorePkg.*walker" /etc/pacman.conf 2>/dev/null; then\
  if grep -q "^IgnorePkg" /etc/pacman.conf; then\
    sudo sed -i '"'"'s/^IgnorePkg = \\(.*\\)/IgnorePkg = \\1 walker/'"'"' /etc/pacman.conf\
  else\
    sudo sed -i '"'"'/^\\[options\\]/a IgnorePkg = walker'"'"' /etc/pacman.conf\
  fi\
fi\
' install/config/walker-elephant.sh

# Soporte Bash/Fish dual para Mise
sed -i 's/omarchy-cmd-present mise && eval "\$(mise activate bash)"/if [ "\$SHELL" = "\/bin\/bash" ] \&\& command -v mise \&> \/dev\/null; then\n  eval "\$(mise activate bash)"\nelif [ "\$SHELL" = "\/bin\/fish" ] \&\& command -v mise \&> \/dev\/null; then\n  mise activate fish | source\nfi/' config/uwsm/env

echo "[5/5] Preparando instalación..."
mkdir -p ~/.local/share/omarchy
# Sincronizamos usando rsync para evitar recursividades en caso de ejecuciones múltiples
rsync -a "$OMARCHY_DIR/" ~/.local/share/omarchy/
cd ~/.local/share/omarchy

echo "[✓] Capas separadas exitosamente. Iniciando Omarchy..."
chmod +x install.sh
./install.sh
