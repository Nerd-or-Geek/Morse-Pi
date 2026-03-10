#!/usr/bin/env bash
# =============================================================================
#  Morse-Pi  —  Automatic Installer
#  Run on your Raspberry Pi with:
#    curl -sSL https://raw.githubusercontent.com/Nerd-or-Geek/Morse-Pi/main/install.sh | bash
# =============================================================================
set -euo pipefail

# ── Colour helpers ─────────────────────────────────────────────────────────────
RED='\033[0;31m'  YEL='\033[0;33m'  GRN='\033[0;32m'
CYN='\033[0;36m'  BLD='\033[1m'     RST='\033[0m'

info()    { echo -e "${CYN}[INFO]  ${RST}$*"; }
ok()      { echo -e "${GRN}[  OK]  ${RST}$*"; }
warn()    { echo -e "${YEL}[WARN]  ${RST}$*"; }
die()     { echo -e "${RED}[FAIL]  ${RST}$*" >&2; exit 1; }
banner()  { echo -e "\n${BLD}${CYN}━━━  $*  ━━━${RST}\n"; }

# ── Configuration ──────────────────────────────────────────────────────────────
REPO_URL="https://github.com/Nerd-or-Geek/Morse-Pi.git"
BRANCH="main"
INSTALL_DIR="/opt/morse-pi"
APP_DIR="${INSTALL_DIR}/morse-translator"
SERVICE_NAME="morse-pi"
SERVICE_FILE="/etc/systemd/system/${SERVICE_NAME}.service"
PORT=5000

# ── Sanity checks ──────────────────────────────────────────────────────────────
# Detect if this is an update or fresh install
SKIP_PACKAGES=false
if [[ -d "${INSTALL_DIR}/.git" ]]; then
  banner "Morse-Pi Updater"
  echo -e "  ${GRN}★ Existing installation detected — will update${RST}"
  echo ""
  echo -e "  Repo   : ${BLD}${REPO_URL}${RST}"
  echo -e "  Branch : ${BLD}${BRANCH}${RST}"
  echo -e "  Target : ${BLD}${INSTALL_DIR}${RST}"
  echo -e "  Port   : ${BLD}${PORT}${RST}"
  echo ""
  
  # Interactive prompt for update options
  echo -e "${BLD}Update Options:${RST}"
  echo -e "  ${CYN}1)${RST} Full update (check packages + update code + restart service)"
  echo -e "  ${CYN}2)${RST} Quick update (skip packages, just update code + restart service)"
  echo ""
  
  # Read from /dev/tty to allow input even when script is piped
  if [[ -t 0 ]]; then
    # stdin is a terminal, read normally
    read -r -p "Choose option [1/2, default=1]: " UPDATE_CHOICE
  else
    # stdin is piped, read from tty
    exec 3</dev/tty
    echo -n "Choose option [1/2, default=1]: "
    read -r UPDATE_CHOICE <&3
    exec 3<&-
  fi
  
  if [[ "${UPDATE_CHOICE}" == "2" ]]; then
    SKIP_PACKAGES=true
    echo ""
    info "Skipping package checks — quick update mode"
  else
    echo ""
    info "Full update mode selected"
  fi
  echo ""
else
  banner "Morse-Pi Installer"
  echo -e "  ${CYN}★ Fresh installation${RST}"
  echo -e "  Repo   : ${BLD}${REPO_URL}${RST}"
  echo -e "  Branch : ${BLD}${BRANCH}${RST}"
  echo -e "  Target : ${BLD}${INSTALL_DIR}${RST}"
  echo -e "  Port   : ${BLD}${PORT}${RST}"
  echo ""
fi

if [[ $EUID -ne 0 ]]; then
  die "Run this installer with sudo: sudo bash install.sh"
fi

# Detect Raspberry Pi (warn only — still works on plain Debian/Ubuntu)
if grep -qi "raspberry" /proc/device-tree/model 2>/dev/null; then
  ok "Raspberry Pi detected: $(cat /proc/device-tree/model)"
else
  warn "No Raspberry Pi model string found — GPIO features will be unavailable, but the web UI still works."
fi

# ── System packages ────────────────────────────────────────────────────────────
if [[ "${SKIP_PACKAGES}" == "true" ]]; then
  banner "Step 1 / 6 — System packages (SKIPPED)"
  info "Skipping package checks as requested"
else
  banner "Step 1 / 6 — System packages"
  info "Refreshing package lists…"
  apt-get update -qq

  PKGS=(python3 python3-pip git)
  for pkg in "${PKGS[@]}"; do
    if dpkg -s "$pkg" &>/dev/null; then
      ok "$pkg already installed"
    else
      info "Installing $pkg…"
      apt-get install -y "$pkg" -qq
      ok "$pkg installed"
    fi
  done

  # GPIO libraries — pigpio backend works reliably on all Pi models including Zero W
  if grep -qi "raspberry" /proc/device-tree/model 2>/dev/null; then
    for pkg in python3-gpiozero pigpio python3-pigpio; do
      if dpkg -s "$pkg" &>/dev/null; then
        ok "$pkg already installed"
      else
        info "Installing $pkg…"
        apt-get install -y "$pkg" -qq
        ok "$pkg installed"
      fi
    done

    # pigpio requires its daemon to be running
    if ! systemctl is-enabled pigpiod &>/dev/null; then
      info "Enabling pigpio daemon…"
      systemctl enable pigpiod --now
      ok "pigpiod enabled and started"
    elif ! systemctl is-active pigpiod &>/dev/null; then
      info "Starting pigpio daemon…"
      systemctl start pigpiod
      ok "pigpiod started"
    else
      ok "pigpiod already running"
    fi
  fi
fi

# ── Clone / update repo ────────────────────────────────────────────────────────
banner "Step 2 / 6 — Repository"
if [[ -d "${INSTALL_DIR}/.git" ]]; then
  IS_UPDATE=true
  info "Existing installation found at ${INSTALL_DIR}. Updating…"
  
  # Backup settings.json and stats.json before git reset (preserves user data)
  # Note: words.json is NOT backed up so it gets updated from the repo
  SETTINGS_BACKUP=""
  STATS_BACKUP=""
  if [[ -f "${APP_DIR}/settings.json" ]]; then
    SETTINGS_BACKUP=$(mktemp)
    cp "${APP_DIR}/settings.json" "${SETTINGS_BACKUP}"
    info "Backed up settings.json"
  fi
  if [[ -f "${APP_DIR}/stats.json" ]]; then
    STATS_BACKUP=$(mktemp)
    cp "${APP_DIR}/stats.json" "${STATS_BACKUP}"
    info "Backed up stats.json"
  fi
  
  git -C "${INSTALL_DIR}" fetch --quiet origin "${BRANCH}"
  git -C "${INSTALL_DIR}" reset --hard "origin/${BRANCH}" --quiet
  
  # Restore settings.json and stats.json after git reset
  if [[ -n "${SETTINGS_BACKUP}" && -f "${SETTINGS_BACKUP}" ]]; then
    cp "${SETTINGS_BACKUP}" "${APP_DIR}/settings.json"
    rm -f "${SETTINGS_BACKUP}"
    ok "Restored user settings.json"
  fi
  if [[ -n "${STATS_BACKUP}" && -f "${STATS_BACKUP}" ]]; then
    cp "${STATS_BACKUP}" "${APP_DIR}/stats.json"
    rm -f "${STATS_BACKUP}"
    ok "Restored user stats.json"
  fi
  
  ok "Repository updated to latest ${BRANCH}"
else
  IS_UPDATE=false
  info "Cloning ${REPO_URL} → ${INSTALL_DIR}…"
  git clone --branch "${BRANCH}" --depth 1 "${REPO_URL}" "${INSTALL_DIR}"
  ok "Repository cloned"
fi

if [[ ! -f "${APP_DIR}/app.py" ]]; then
  die "app.py not found at ${APP_DIR}. Check your REPO_URL and directory structure."
fi
ok "app.py found at ${APP_DIR}"

# Remove any leftover virtual environment from old installs
if [[ -d "${INSTALL_DIR}/venv" ]]; then
  info "Removing old virtual environment at ${INSTALL_DIR}/venv…"
  rm -rf "${INSTALL_DIR}/venv"
  ok "Old venv removed"
fi
# Also catch venvs named .venv or env
for leftover in "${INSTALL_DIR}/.venv" "${INSTALL_DIR}/env" "${APP_DIR}/venv" "${APP_DIR}/.venv" "${APP_DIR}/env"; do
  if [[ -d "${leftover}" ]]; then
    info "Removing leftover environment at ${leftover}…"
    rm -rf "${leftover}"
    ok "Removed ${leftover}"
  fi
done

# ── Python packages ──────────────────────────────────────────────────────────
banner "Step 3 / 6 — Python packages"

# Helper: check if a Python package is already importable
pkg_installed(){ python3 -c "import $1" 2>/dev/null; }

# Flask
if pkg_installed flask; then
  FLASK_VER=$(python3 -c "import flask; print(flask.__version__)" 2>/dev/null)
  ok "flask already installed (v${FLASK_VER})"
else
  info "Installing flask…"
  pip3 install flask --quiet --break-system-packages
  ok "flask installed"
fi

# gpiozero via pip only if the apt package isn't available
if pkg_installed gpiozero; then
  GZ_VER=$(python3 -c "import gpiozero; print(gpiozero.__version__)" 2>/dev/null)
  ok "gpiozero already installed (v${GZ_VER})"
else
  info "Installing gpiozero…"
  pip3 install gpiozero --quiet --break-system-packages
  ok "gpiozero installed"
fi

# Install from requirements.txt if present
if [[ -f "${INSTALL_DIR}/requirements.txt" ]]; then
  info "Installing from requirements.txt…"
  pip3 install -r "${INSTALL_DIR}/requirements.txt" --quiet --break-system-packages
  ok "requirements.txt packages installed"
fi

# ── Systemd service ────────────────────────────────────────────────────────────
banner "Step 4 / 6 — Systemd service"

# Remove any drop-in overrides left by previous installs (e.g. old venv path)
DROPIN_DIR="/etc/systemd/system/${SERVICE_NAME}.service.d"
if [[ -d "${DROPIN_DIR}" ]]; then
  info "Removing old systemd drop-in overrides at ${DROPIN_DIR}…"
  rm -rf "${DROPIN_DIR}"
  ok "Old overrides removed"
fi

# Resolve the actual user who invoked sudo (fall back to 'pi' → root)
if [[ -n "${SUDO_USER:-}" ]]; then
  RUN_USER="${SUDO_USER}"
else
  RUN_USER="$(id -un)"
fi
info "Service will run as user: ${RUN_USER}"

# Ensure the app directory is owned by the service user (so settings.json can be written)
info "Setting ownership of ${APP_DIR} to ${RUN_USER}…"
chown -R "${RUN_USER}:${RUN_USER}" "${APP_DIR}"
chmod -R u+rw "${APP_DIR}"
ok "Directory permissions set"

# Create initial settings.json if it doesn't exist (prevents permission issues on first run)
SETTINGS_FILE="${APP_DIR}/settings.json"
if [[ ! -f "${SETTINGS_FILE}" ]]; then
  info "Creating initial settings.json…"
  cat > "${SETTINGS_FILE}" <<'SETTINGS_EOF'
{
  "speaker_pin": 18,
  "output_type": "speaker",
  "pin_mode": "single",
  "data_pin": 17,
  "dot_pin": 22,
  "dash_pin": 27,
  "ground_pin": null,
  "grounded_pins": [],
  "use_external_switch": false,
  "dot_freq": 700,
  "dash_freq": 500,
  "volume": 0.75,
  "wpm_target": 20,
  "theme": "dark",
  "difficulty": "easy",
  "device_name": "Morse Pi"
}
SETTINGS_EOF
  chown "${RUN_USER}:${RUN_USER}" "${SETTINGS_FILE}"
  chmod 644 "${SETTINGS_FILE}"
  ok "settings.json created"
else
  # Ensure existing settings.json is writable
  chown "${RUN_USER}:${RUN_USER}" "${SETTINGS_FILE}"
  chmod 644 "${SETTINGS_FILE}"
  ok "settings.json permissions verified"
fi

# Add user to gpio group so gpiozero can access hardware without sudo
if getent group gpio &>/dev/null; then
  if ! id -nG "${RUN_USER}" | grep -qw "gpio"; then
    info "Adding ${RUN_USER} to gpio group…"
    usermod -aG gpio "${RUN_USER}"
    ok "${RUN_USER} added to gpio group"
  else
    ok "${RUN_USER} already in gpio group"
  fi
fi

# Create the systemd service file
info "Creating systemd service file at ${SERVICE_FILE}…"
cat > "${SERVICE_FILE}" <<EOF
[Unit]
Description=Morse-Pi — Morse code trainer web app
After=network-online.target
Wants=network-online.target

[Service]
Type=simple
User=${RUN_USER}
WorkingDirectory=${APP_DIR}
ExecStart=/usr/bin/python3 app.py
Restart=always
RestartSec=5
StandardOutput=journal
StandardError=journal
# Tell gpiozero to use pigpio — works on all Pi models including Zero W
Environment=GPIOZERO_PIN_FACTORY=pigpio
# Give gpiozero time to initialise on boot
TimeoutStartSec=30

[Install]
WantedBy=multi-user.target
EOF

# Verify the service file was created
if [[ -f "${SERVICE_FILE}" ]]; then
  ok "Service file written to ${SERVICE_FILE}"
else
  die "Failed to create service file at ${SERVICE_FILE}"
fi

info "Reloading systemd daemon…"
systemctl daemon-reload
ok "systemd reloaded"

# Always ensure service is enabled (will start on boot)
info "Enabling ${SERVICE_NAME} to start on boot…"
systemctl enable "${SERVICE_NAME}"
ok "${SERVICE_NAME} enabled"

# Always ensure service is running (stop first if active to pick up changes)
if systemctl is-active --quiet "${SERVICE_NAME}"; then
  info "Restarting ${SERVICE_NAME} to apply changes…"
  systemctl restart "${SERVICE_NAME}"
  ok "${SERVICE_NAME} restarted"
else
  info "Starting ${SERVICE_NAME}…"
  systemctl start "${SERVICE_NAME}"
  ok "${SERVICE_NAME} started"
fi

# Verify the service is actually running
sleep 1
if systemctl is-active --quiet "${SERVICE_NAME}"; then
  ok "${SERVICE_NAME} is running"
else
  warn "${SERVICE_NAME} may have failed to start. Check: sudo journalctl -u ${SERVICE_NAME} -n 50"
fi

# Wait briefly for the service to come up before showing the URL
sleep 2

# ── USB HID Gadget Setup ─────────────────────────────────────────────────────
banner "Step 5 / 6 — USB HID Keyboard Gadget"

# Only set up USB HID on Raspberry Pi
if grep -qi "raspberry" /proc/device-tree/model 2>/dev/null; then
  HID_NEEDS_REBOOT=false
  
  # Determine config.txt location (changed in newer Pi OS)
  if [[ -f /boot/firmware/config.txt ]]; then
    CONFIG_TXT="/boot/firmware/config.txt"
  else
    CONFIG_TXT="/boot/config.txt"
  fi
  
  # Enable dwc2 overlay in config.txt
  if grep -q "^dtoverlay=dwc2" "${CONFIG_TXT}" 2>/dev/null; then
    ok "dwc2 overlay already enabled in ${CONFIG_TXT}"
  else
    info "Enabling dwc2 overlay in ${CONFIG_TXT}…"
    echo "dtoverlay=dwc2" >> "${CONFIG_TXT}"
    ok "dwc2 overlay enabled"
    HID_NEEDS_REBOOT=true
  fi
  
  # Add dwc2 module to /etc/modules
  if grep -q "^dwc2" /etc/modules 2>/dev/null; then
    ok "dwc2 module already in /etc/modules"
  else
    info "Adding dwc2 to /etc/modules…"
    echo "dwc2" >> /etc/modules
    ok "dwc2 added to /etc/modules"
    HID_NEEDS_REBOOT=true
  fi
  
  # Add libcomposite module to /etc/modules
  if grep -q "^libcomposite" /etc/modules 2>/dev/null; then
    ok "libcomposite module already in /etc/modules"
  else
    info "Adding libcomposite to /etc/modules…"
    echo "libcomposite" >> /etc/modules
    ok "libcomposite added to /etc/modules"
    HID_NEEDS_REBOOT=true
  fi
  
  # Create USB HID gadget setup script
  HID_SCRIPT="/usr/local/bin/morse-pi-hid-setup.sh"
  info "Creating USB HID gadget setup script…"
  cat > "${HID_SCRIPT}" <<'HID_SCRIPT_EOF'
#!/bin/bash
# Morse-Pi USB HID Keyboard Gadget Setup
# This script configures the Raspberry Pi as a USB HID keyboard

set -e

# Load required module
modprobe libcomposite 2>/dev/null || true

GADGET_DIR="/sys/kernel/config/usb_gadget/morse-pi-keyboard"

# If gadget already exists, we're done
if [[ -d "${GADGET_DIR}" ]]; then
  exit 0
fi

# Check if configfs is available
if [[ ! -d /sys/kernel/config/usb_gadget ]]; then
  # Try to mount configfs
  mount -t configfs none /sys/kernel/config 2>/dev/null || true
  if [[ ! -d /sys/kernel/config/usb_gadget ]]; then
    echo "USB gadget configfs not available" >&2
    exit 1
  fi
fi

# Create gadget
mkdir -p "${GADGET_DIR}"
cd "${GADGET_DIR}"

# USB device descriptor
echo 0x1d6b > idVendor  # Linux Foundation
echo 0x0104 > idProduct # Multifunction Composite Gadget
echo 0x0100 > bcdDevice # v1.0.0
echo 0x0200 > bcdUSB    # USB2

# Device strings
mkdir -p strings/0x409
echo "fedcba9876543210" > strings/0x409/serialnumber
echo "Morse-Pi" > strings/0x409/manufacturer
echo "Morse Code Keyboard" > strings/0x409/product

# HID function
mkdir -p functions/hid.usb0
echo 1 > functions/hid.usb0/protocol    # Keyboard
echo 1 > functions/hid.usb0/subclass    # Boot interface subclass
echo 8 > functions/hid.usb0/report_length

# HID report descriptor for a standard keyboard
echo -ne '\x05\x01\x09\x06\xa1\x01\x05\x07\x19\xe0\x29\xe7\x15\x00\x25\x01\x75\x01\x95\x08\x81\x02\x95\x01\x75\x08\x81\x03\x95\x05\x75\x01\x05\x08\x19\x01\x29\x05\x91\x02\x95\x01\x75\x03\x91\x03\x95\x06\x75\x08\x15\x00\x25\x65\x05\x07\x19\x00\x29\x65\x81\x00\xc0' > functions/hid.usb0/report_desc

# Configuration
mkdir -p configs/c.1/strings/0x409
echo "Config 1: Keyboard" > configs/c.1/strings/0x409/configuration
echo 250 > configs/c.1/MaxPower

# Link function to configuration
ln -sf functions/hid.usb0 configs/c.1/

# Get the UDC (USB Device Controller) name
UDC=$(ls /sys/class/udc | head -n1)
if [[ -n "${UDC}" ]]; then
  echo "${UDC}" > UDC
  echo "USB HID keyboard gadget enabled on ${UDC}"
else
  echo "No USB Device Controller found" >&2
  exit 1
fi
HID_SCRIPT_EOF
  chmod +x "${HID_SCRIPT}"
  ok "USB HID setup script created at ${HID_SCRIPT}"
  
  # Create systemd service for USB HID gadget
  HID_SERVICE="/etc/systemd/system/morse-pi-hid.service"
  info "Creating USB HID systemd service…"
  cat > "${HID_SERVICE}" <<HID_SERVICE_EOF
[Unit]
Description=Morse-Pi USB HID Keyboard Gadget
After=sysinit.target
DefaultDependencies=no

[Service]
Type=oneshot
ExecStart=${HID_SCRIPT}
RemainAfterExit=yes

[Install]
WantedBy=sysinit.target
HID_SERVICE_EOF
  ok "USB HID service created at ${HID_SERVICE}"
  
  # Enable and start the HID service
  systemctl daemon-reload
  if ! systemctl is-enabled --quiet morse-pi-hid 2>/dev/null; then
    info "Enabling USB HID service…"
    systemctl enable morse-pi-hid
    ok "USB HID service enabled"
  else
    ok "USB HID service already enabled"
  fi
  
  # Try to start it now (may fail if modules aren't loaded yet)
  if [[ -d /sys/kernel/config/usb_gadget ]] || modprobe libcomposite 2>/dev/null; then
    if ! systemctl is-active --quiet morse-pi-hid 2>/dev/null; then
      info "Starting USB HID service…"
      if systemctl start morse-pi-hid 2>/dev/null; then
        ok "USB HID gadget is active"
      else
        warn "USB HID service couldn't start now — will work after reboot"
      fi
    else
      ok "USB HID gadget already active"
    fi
  else
    warn "USB HID will be available after reboot (kernel modules not yet loaded)"
    HID_NEEDS_REBOOT=true
  fi
  
  # Set permissions on /dev/hidg0 if it exists
  if [[ -e /dev/hidg0 ]]; then
    chmod 666 /dev/hidg0
    ok "/dev/hidg0 permissions set"
  fi
  
  if [[ "${HID_NEEDS_REBOOT}" == "true" ]]; then
    warn "USB HID gadget requires a reboot to fully activate"
    echo -e "  ${YEL}After this script completes, run: ${BLD}sudo reboot${RST}"
  fi
else
  info "Not a Raspberry Pi — skipping USB HID gadget setup"
fi

# ── Firewall ─────────────────────────────────────────────────────────────────
banner "Step 6 / 6 — Firewall"
if command -v ufw &>/dev/null && ufw status | grep -q "Status: active"; then
  if ufw status | grep -q "${PORT}"; then
    ok "Port ${PORT} already allowed in ufw"
  else
    info "Opening port ${PORT} in ufw…"
    ufw allow ${PORT}/tcp --quiet
    ok "Port ${PORT} allowed"
  fi
else
  info "ufw not active — skipping firewall step"
fi

# ── Done ───────────────────────────────────────────────────────────────────────
if [[ "${IS_UPDATE:-false}" == "true" ]]; then
  banner "Update complete!"
  echo -e "${GRN}${BLD}Morse-Pi has been updated and restarted!${RST}"
else
  banner "Installation complete!"
  echo -e "${GRN}${BLD}Morse-Pi is running!${RST}"
fi

# Determine the Pi's LAN IP(s) for display
IPS=$(hostname -I 2>/dev/null | tr ' ' '\n' | grep -v '^$' | grep -v '^127\.' | head -5)

echo ""
echo -e "  Open your browser and navigate to one of:"
while IFS= read -r ip; do
  echo -e "    ${BLD}${YEL}http://${ip}:${PORT}${RST}"
done <<< "${IPS}"
echo ""
echo -e "  Useful commands:"
echo -e "    ${BLD}sudo systemctl status  ${SERVICE_NAME}${RST}   — check status"
echo -e "    ${BLD}sudo systemctl restart ${SERVICE_NAME}${RST}   — restart"
echo -e "    ${BLD}sudo journalctl -u ${SERVICE_NAME} -f${RST}    — live logs"
echo -e "    ${BLD}sudo systemctl stop    ${SERVICE_NAME}${RST}   — stop"
echo ""
echo -e "  To update later, re-run this script:"
echo -e "    ${BLD}curl -sSL https://raw.githubusercontent.com/Nerd-or-Geek/Morse-Pi/main/install.sh | sudo bash${RST}"
echo ""
