#!/usr/bin/env bash
# =============================================================================
#  Morse-Pi  —  Updater
#  Run on your Raspberry Pi with:
#    curl -sSL https://raw.githubusercontent.com/Nerd-or-Geek/Morse-Pi/main/update.sh | sudo bash
#
#  This script updates an existing Morse-Pi installation:
#    1. Verify / fix USB HID gadget setup
#    2. Pull latest code (preserves settings.json and stats.json)
#    3. Ensure auto-start on boot
#
#  For a fresh install, use install.sh
#  For updating packages only, use packages.sh
# =============================================================================
set -euo pipefail

# ── Colour helpers ─────────────────────────────────────────────────────────────
RED='\033[0;31m'  YEL='\033[0;33m'  GRN='\033[0;32m'
CYN='\033[0;36m'  BLD='\033[1m'     RST='\033[0m'

info()    { echo -e "${CYN}[INFO]${RST}  $*"; }
ok()      { echo -e "${GRN}[  OK]${RST}  $*"; }
warn()    { echo -e "${YEL}[WARN]${RST}  $*"; }
die()     { echo -e "${RED}[FAIL]${RST}  $*" >&2; exit 1; }
banner()  { echo -e "\n${BLD}${CYN}━━━  $*  ━━━${RST}\n"; }

# ── Configuration ──────────────────────────────────────────────────────────────
REPO_URL="https://github.com/Nerd-or-Geek/Morse-Pi.git"
BRANCH="main"
INSTALL_DIR="/opt/morse-pi"
APP_DIR="${INSTALL_DIR}/morse-translator"
SERVICE_NAME="morse-pi"
SERVICE_FILE="/etc/systemd/system/${SERVICE_NAME}.service"
HID_SERVICE_NAME="morse-pi-hid"
HID_SERVICE_FILE="/etc/systemd/system/${HID_SERVICE_NAME}.service"
HID_SCRIPT="/usr/local/bin/morse-pi-hid-setup.sh"
PORT=5000

# ── Sanity checks ─────────────────────────────────────────────────────────────
banner "Morse-Pi Updater"
echo -e "  ${GRN}★ Updating existing installation${RST}"
echo -e "  Repo   : ${BLD}${REPO_URL}${RST}"
echo -e "  Branch : ${BLD}${BRANCH}${RST}"
echo -e "  Target : ${BLD}${INSTALL_DIR}${RST}"
echo -e "  Port   : ${BLD}${PORT}${RST}"
echo ""

if [[ $EUID -ne 0 ]]; then
  die "Run this script with sudo:  sudo bash update.sh"
fi

if [[ ! -d "${INSTALL_DIR}/.git" ]]; then
  die "No existing installation found at ${INSTALL_DIR}. Run install.sh for a fresh install."
fi
ok "Existing installation found"

IS_PI=false
if grep -qi "raspberry" /proc/device-tree/model 2>/dev/null; then
  IS_PI=true
  ok "Raspberry Pi detected: $(tr -d '\0' < /proc/device-tree/model)"
else
  warn "No Raspberry Pi detected — GPIO and USB HID features will be unavailable."
fi

# ── Resolve run user ──────────────────────────────────────────────────────────
if [[ -n "${SUDO_USER:-}" ]]; then
  RUN_USER="${SUDO_USER}"
elif id "pi" &>/dev/null; then
  RUN_USER="pi"
else
  RUN_USER="$(id -un)"
fi
info "Service will run as user: ${RUN_USER}"

# ===========================================================================
#  STEP 1 — Verify / fix USB HID Keyboard Gadget
# ===========================================================================
banner "Step 1 / 3 — USB HID Keyboard Gadget"

HID_NEEDS_REBOOT=false

if [[ "${IS_PI}" == "true" ]]; then

  # ── Determine config.txt location ──
  if [[ -f /boot/firmware/config.txt ]]; then
    CONFIG_TXT="/boot/firmware/config.txt"
  else
    CONFIG_TXT="/boot/config.txt"
  fi

  # ── Enable dwc2 overlay ──
  if grep -q "^dtoverlay=dwc2" "${CONFIG_TXT}" 2>/dev/null; then
    ok "dwc2 overlay enabled"
  else
    info "Enabling dwc2 overlay in ${CONFIG_TXT}…"
    echo "dtoverlay=dwc2" >> "${CONFIG_TXT}"
    ok "dwc2 overlay enabled"
    HID_NEEDS_REBOOT=true
  fi

  # ── dwc2 module ──
  if grep -q "^dwc2" /etc/modules 2>/dev/null; then
    ok "dwc2 module loaded"
  else
    info "Adding dwc2 to /etc/modules…"
    echo "dwc2" >> /etc/modules
    ok "dwc2 added"
    HID_NEEDS_REBOOT=true
  fi

  # ── libcomposite module ──
  if grep -q "^libcomposite" /etc/modules 2>/dev/null; then
    ok "libcomposite module loaded"
  else
    info "Adding libcomposite to /etc/modules…"
    echo "libcomposite" >> /etc/modules
    ok "libcomposite added"
    HID_NEEDS_REBOOT=true
  fi

  # ── Blacklist conflicting USB gadget drivers ──
  # g_ether provides USB Ethernet (SSH-over-USB) but monopolises the single
  # UDC on a Pi Zero, preventing the HID keyboard gadget from binding.
  BLACKLIST_FILE="/etc/modprobe.d/morse-pi-no-gadget-conflict.conf"
  info "Ensuring conflicting USB gadget modules are blacklisted…"
  cat > "${BLACKLIST_FILE}" <<'BLEOF'
# Morse-Pi: prevent legacy gadget drivers from grabbing the UDC
# These conflict with the configfs-based USB HID keyboard gadget.
blacklist g_ether
blacklist g_serial
blacklist g_mass_storage
blacklist g_multi
blacklist g_zero
blacklist g_webcam
BLEOF
  ok "Conflicting modules blacklisted"

  # ── Clean g_ether from cmdline.txt / modules ──
  CMDLINE=""
  if [[ -f /boot/firmware/cmdline.txt ]]; then
    CMDLINE="/boot/firmware/cmdline.txt"
  elif [[ -f /boot/cmdline.txt ]]; then
    CMDLINE="/boot/cmdline.txt"
  fi
  if [[ -n "${CMDLINE}" ]]; then
    if grep -q "g_ether" "${CMDLINE}" 2>/dev/null; then
      info "Removing g_ether from ${CMDLINE}…"
      sed -i 's/,g_ether//g; s/g_ether,//g; s/modules-load=g_ether //g' "${CMDLINE}"
      ok "g_ether removed from ${CMDLINE}"
      HID_NEEDS_REBOOT=true
    fi
  fi
  if grep -q "^g_ether" /etc/modules 2>/dev/null; then
    info "Removing g_ether from /etc/modules…"
    sed -i '/^g_ether/d' /etc/modules
    ok "g_ether removed from /etc/modules"
    HID_NEEDS_REBOOT=true
  fi

  # ── Remove stale dr_mode=host from config.txt ──
  if grep -q "dr_mode=host" "${CONFIG_TXT}" 2>/dev/null; then
    info "Removing dr_mode=host from ${CONFIG_TXT} (breaks USB gadget mode)…"
    sed -i '/dtoverlay=dwc2,dr_mode=host/d' "${CONFIG_TXT}"
    ok "dr_mode=host line removed"
    HID_NEEDS_REBOOT=true
  fi

  # ── HID gadget setup script (always rewrite to pick up fixes) ──
  info "Writing HID gadget setup script to ${HID_SCRIPT}…"
  cat > "${HID_SCRIPT}" <<'HIDEOF'
#!/bin/bash
# Morse-Pi USB HID Keyboard Gadget Setup
set -e

modprobe libcomposite 2>/dev/null || true

GADGET_DIR="/sys/kernel/config/usb_gadget/morse-pi-keyboard"

# ── Remove conflicting USB gadget drivers ──
# g_ether (USB Ethernet), g_serial, g_mass_storage, g_multi etc. monopolise
# the single UDC on a Pi Zero, preventing us from binding the HID gadget.
for mod in g_ether g_serial g_mass_storage g_multi g_zero g_webcam; do
  if lsmod | grep -q "^${mod} "; then
    echo "Removing conflicting gadget module: ${mod}"
    rmmod "${mod}" 2>/dev/null || true
  fi
done

# Also clean up orphaned function drivers left behind
for mod in usb_f_ecm usb_f_rndis u_ether usb_f_acm u_serial; do
  if lsmod | grep -q "^${mod} "; then
    rmmod "${mod}" 2>/dev/null || true
  fi
done

# If gadget dir exists, check if UDC is already bound.  If so, we're done.
if [[ -d "${GADGET_DIR}" ]]; then
  CURRENT_UDC=$(cat "${GADGET_DIR}/UDC" 2>/dev/null | tr -d '[:space:]')
  if [[ -n "${CURRENT_UDC}" ]]; then
    echo "USB HID already bound to ${CURRENT_UDC}"
    exit 0
  fi
  # Gadget dir exists but UDC is empty — try to bind it
  UDC=$(ls /sys/class/udc 2>/dev/null | head -n1)
  if [[ -n "${UDC}" ]]; then
    echo "${UDC}" > "${GADGET_DIR}/UDC"
    echo "USB HID keyboard gadget re-bound to ${UDC}"
    exit 0
  fi
  echo "Gadget configured but no UDC available" >&2
  exit 1
fi

if [[ ! -d /sys/kernel/config/usb_gadget ]]; then
  mount -t configfs none /sys/kernel/config 2>/dev/null || true
  if [[ ! -d /sys/kernel/config/usb_gadget ]]; then
    echo "USB gadget configfs not available" >&2
    exit 1
  fi
fi

mkdir -p "${GADGET_DIR}"
cd "${GADGET_DIR}"

echo 0x1d6b > idVendor
echo 0x0104 > idProduct
echo 0x0100 > bcdDevice
echo 0x0200 > bcdUSB

mkdir -p strings/0x409
echo "fedcba9876543210"    > strings/0x409/serialnumber
echo "Morse-Pi"            > strings/0x409/manufacturer
echo "Morse Code Keyboard" > strings/0x409/product

mkdir -p functions/hid.usb0
echo 1 > functions/hid.usb0/protocol
echo 1 > functions/hid.usb0/subclass
echo 8 > functions/hid.usb0/report_length

echo -ne '\x05\x01\x09\x06\xa1\x01\x05\x07\x19\xe0\x29\xe7\x15\x00\x25\x01\x75\x01\x95\x08\x81\x02\x95\x01\x75\x08\x81\x03\x95\x05\x75\x01\x05\x08\x19\x01\x29\x05\x91\x02\x95\x01\x75\x03\x91\x03\x95\x06\x75\x08\x15\x00\x25\x65\x05\x07\x19\x00\x29\x65\x81\x00\xc0' \
  > functions/hid.usb0/report_desc

mkdir -p configs/c.1/strings/0x409
echo "Config 1: Keyboard" > configs/c.1/strings/0x409/configuration
echo 250 > configs/c.1/MaxPower

ln -sf functions/hid.usb0 configs/c.1/

UDC=$(ls /sys/class/udc | head -n1)
if [[ -n "${UDC}" ]]; then
  echo "${UDC}" > UDC
  echo "USB HID keyboard gadget enabled on ${UDC}"
else
  echo "No USB Device Controller found" >&2
  exit 1
fi
HIDEOF
  chmod +x "${HID_SCRIPT}"
  ok "HID setup script created"

  # ── udev rule ──
  UDEV_RULE="/etc/udev/rules.d/99-morse-pi-hid.rules"
  if [[ -f "${UDEV_RULE}" ]]; then
    ok "udev rule exists"
  else
    info "Creating udev rule for /dev/hidg0 permissions…"
    cat > "${UDEV_RULE}" <<'UDEVEOF'
KERNEL=="hidg[0-9]*", MODE="0666"
UDEVEOF
    udevadm control --reload-rules 2>/dev/null || true
    udevadm trigger 2>/dev/null || true
    ok "udev rule created"
  fi

  # ── HID systemd service ──
  if [[ ! -f "${HID_SERVICE_FILE}" ]]; then
    info "Creating HID systemd service…"
    cat > "${HID_SERVICE_FILE}" <<HIDSVCEOF
[Unit]
Description=Morse-Pi USB HID Keyboard Gadget
DefaultDependencies=no
After=sys-kernel-config.mount
Requires=sys-kernel-config.mount

[Service]
Type=oneshot
ExecStart=${HID_SCRIPT}
RemainAfterExit=yes

[Install]
WantedBy=sysinit.target
HIDSVCEOF
    systemctl daemon-reload
  fi

  if ! systemctl is-enabled --quiet "${HID_SERVICE_NAME}" 2>/dev/null; then
    systemctl enable "${HID_SERVICE_NAME}" 2>&1
    ok "HID service enabled for boot"
  else
    ok "HID service already enabled"
  fi

  # Start if not already running
  if ! systemctl is-active --quiet "${HID_SERVICE_NAME}" 2>/dev/null; then
    if [[ -d /sys/kernel/config/usb_gadget ]] || modprobe libcomposite 2>/dev/null; then
      if systemctl start "${HID_SERVICE_NAME}" 2>/dev/null; then
        ok "HID gadget activated"
      else
        warn "HID gadget couldn't start — will work after reboot"
        HID_NEEDS_REBOOT=true
      fi
    else
      HID_NEEDS_REBOOT=true
    fi
  else
    ok "HID gadget already active"
  fi

  if [[ -e /dev/hidg0 ]]; then
    chmod 666 /dev/hidg0
    ok "/dev/hidg0 ready"
  fi

  if [[ "${HID_NEEDS_REBOOT}" == "true" ]]; then
    warn "A reboot is required for USB HID to fully activate"
  fi
else
  info "Not a Raspberry Pi — skipping USB HID check"
fi

# ===========================================================================
#  STEP 2 — Update code (preserve settings.json and stats.json)
# ===========================================================================
banner "Step 2 / 3 — Update code"

# Stop the service while we update files
if systemctl is-active --quiet "${SERVICE_NAME}" 2>/dev/null; then
  info "Stopping ${SERVICE_NAME} for update…"
  systemctl stop "${SERVICE_NAME}" 2>/dev/null || true
  ok "Service stopped"
fi

# Backup user data files
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

# Pull latest code (hard reset to discard any local changes)
info "Fetching latest from ${BRANCH}…"
git -C "${INSTALL_DIR}" fetch --quiet origin "${BRANCH}"
git -C "${INSTALL_DIR}" reset --hard "origin/${BRANCH}" --quiet
ok "Code updated to latest ${BRANCH}"

# Restore user data
if [[ -n "${SETTINGS_BACKUP}" && -f "${SETTINGS_BACKUP}" ]]; then
  cp "${SETTINGS_BACKUP}" "${APP_DIR}/settings.json"
  rm -f "${SETTINGS_BACKUP}"
  ok "Restored settings.json"
fi
if [[ -n "${STATS_BACKUP}" && -f "${STATS_BACKUP}" ]]; then
  cp "${STATS_BACKUP}" "${APP_DIR}/stats.json"
  rm -f "${STATS_BACKUP}"
  ok "Restored stats.json"
fi

if [[ ! -f "${APP_DIR}/app.py" ]]; then
  die "app.py not found after update — something went wrong."
fi
ok "app.py verified"

# Remove leftover virtual environments from old installs
for leftover in "${INSTALL_DIR}/venv" "${INSTALL_DIR}/.venv" "${INSTALL_DIR}/env" "${APP_DIR}/venv" "${APP_DIR}/.venv" "${APP_DIR}/env"; do
  [[ -d "${leftover}" ]] && rm -rf "${leftover}"
done

# Fix ownership
chown -R "${RUN_USER}:${RUN_USER}" "${INSTALL_DIR}"
chmod -R u+rw "${INSTALL_DIR}"
ok "Ownership set to ${RUN_USER}"

# ===========================================================================
#  STEP 3 — Ensure auto-start on boot
# ===========================================================================
banner "Step 3 / 3 — Auto-start on boot"

# Remove stale drop-in overrides
DROPIN_DIR="/etc/systemd/system/${SERVICE_NAME}.service.d"
[[ -d "${DROPIN_DIR}" ]] && rm -rf "${DROPIN_DIR}"

info "Writing ${SERVICE_FILE}…"
cat > "${SERVICE_FILE}" <<SVCEOF
[Unit]
Description=Morse-Pi — Morse code trainer web app
After=network-online.target pigpiod.service ${HID_SERVICE_NAME}.service
Wants=network-online.target pigpiod.service

[Service]
Type=simple
User=${RUN_USER}
Group=${RUN_USER}
WorkingDirectory=${APP_DIR}
ExecStart=/usr/bin/python3 ${APP_DIR}/app.py
Restart=always
RestartSec=3
StandardOutput=journal
StandardError=journal
Environment=GPIOZERO_PIN_FACTORY=pigpio
TimeoutStartSec=30

[Install]
WantedBy=multi-user.target
SVCEOF

if [[ ! -f "${SERVICE_FILE}" ]]; then
  die "Failed to create ${SERVICE_FILE}"
fi
ok "Service file written"

systemctl daemon-reload
ok "systemd daemon reloaded"

systemctl enable "${SERVICE_NAME}" 2>&1
ok "${SERVICE_NAME} enabled for auto-start"

info "Starting ${SERVICE_NAME}…"
systemctl start "${SERVICE_NAME}"

sleep 2
if systemctl is-active --quiet "${SERVICE_NAME}"; then
  ok "${SERVICE_NAME} is running"
else
  warn "${SERVICE_NAME} may have failed to start:"
  journalctl -u "${SERVICE_NAME}" --no-pager -n 15 2>/dev/null || true
fi

# Firewall
if command -v ufw &>/dev/null && ufw status | grep -q "Status: active"; then
  if ! ufw status | grep -q "${PORT}"; then
    ufw allow ${PORT}/tcp --quiet
    ok "Port ${PORT} opened in ufw"
  fi
fi

# ===========================================================================
#  Done
# ===========================================================================
banner "Update complete!"
echo -e "${GRN}${BLD}Morse-Pi has been updated and restarted!${RST}"

IPS=$(hostname -I 2>/dev/null | tr ' ' '\n' | grep -v '^$' | grep -v '^127\.' | head -5)
echo ""
echo -e "  Open your browser:"
while IFS= read -r ip; do
  [[ -n "$ip" ]] && echo -e "    ${BLD}${YEL}http://${ip}:${PORT}${RST}"
done <<< "${IPS}"
echo ""
echo -e "  Useful commands:"
echo -e "    ${BLD}sudo systemctl status  ${SERVICE_NAME}${RST}   — check status"
echo -e "    ${BLD}sudo systemctl restart ${SERVICE_NAME}${RST}   — restart"
echo -e "    ${BLD}sudo journalctl -u ${SERVICE_NAME} -f${RST}    — live logs"
echo ""
if [[ "${HID_NEEDS_REBOOT}" == "true" ]]; then
  echo -e "  ${YEL}${BLD}⚠  Reboot required for USB HID keyboard:  sudo reboot${RST}"
  echo ""
fi
