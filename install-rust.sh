#!/usr/bin/env bash
# =============================================================================
#  Morse-Pi  —  Fresh Installer (Rust backend)
#  Run on your Raspberry Pi with:
#    curl -sSL https://raw.githubusercontent.com/Nerd-or-Geek/Morse-Pi/main/install-rust.sh | sudo bash
#
#  This script performs a FRESH install using the native Rust backend:
#    1. Configure USB HID keyboard gadget
#    2. Install Rust toolchain + build dependencies
#    3. Clone the repository and build the binary
#    4. Set up auto-start on boot
#
#  The Python install script (install.sh) is still available if needed.
#  Build time: ~10-30 min on Pi Zero, ~3-5 min on Pi 3/4/5.
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
RUST_SRC="${INSTALL_DIR}/morse-translator-rust"
SERVICE_NAME="morse-pi"
SERVICE_FILE="/etc/systemd/system/${SERVICE_NAME}.service"
HID_SERVICE_NAME="morse-pi-hid"
HID_SERVICE_FILE="/etc/systemd/system/${HID_SERVICE_NAME}.service"
HID_SCRIPT="/usr/local/bin/morse-pi-hid-setup.sh"
BINARY_NAME="morse-pi"
PORT=5000

# ── Sanity checks ─────────────────────────────────────────────────────────────
banner "Morse-Pi Installer (Rust)"
echo -e "  ${CYN}★ Fresh installation — native Rust backend${RST}"
echo -e "  Repo   : ${BLD}${REPO_URL}${RST}"
echo -e "  Branch : ${BLD}${BRANCH}${RST}"
echo -e "  Target : ${BLD}${INSTALL_DIR}${RST}"
echo -e "  Port   : ${BLD}${PORT}${RST}"
echo ""

if [[ $EUID -ne 0 ]]; then
  die "Run this installer with sudo:  sudo bash install-rust.sh"
fi

if [[ -d "${INSTALL_DIR}/.git" ]]; then
  warn "Existing installation detected at ${INSTALL_DIR}."
  warn "Use transition-rust.sh to switch an existing Python install to Rust,"
  warn "or remove ${INSTALL_DIR} first for a fresh install."
  die "Aborting — existing installation found."
fi

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

# ── Disk space check ──────────────────────────────────────────────────────────
AVAIL_ROOT_MB=$(df -BM / 2>/dev/null | awk 'NR==2{gsub(/M/,""); print $4}' || echo 0)
NEEDED_MB=700
info "Available disk space: / = ${AVAIL_ROOT_MB} MB (need ~${NEEDED_MB} MB)"

if [[ "${AVAIL_ROOT_MB}" -lt "${NEEDED_MB}" ]]; then
  warn "Low disk space — attempting cleanup…"
  apt-get clean 2>/dev/null || true
  apt-get autoremove -y -qq 2>/dev/null || true
  journalctl --vacuum-size=10M 2>/dev/null || true

  AVAIL_ROOT_MB=$(df -BM / 2>/dev/null | awk 'NR==2{gsub(/M/,""); print $4}' || echo 0)
  info "After cleanup: ${AVAIL_ROOT_MB} MB available"

  if [[ "${AVAIL_ROOT_MB}" -lt "${NEEDED_MB}" ]]; then
    die "Not enough disk space (${AVAIL_ROOT_MB} MB free, need ~${NEEDED_MB} MB).
    Rust toolchain (~400 MB) + build cache (~200 MB) + repo.
    Free some space and try again."
  fi
fi

# ===========================================================================
#  STEP 1 — USB HID Keyboard Gadget
# ===========================================================================
banner "Step 1 / 4 — USB HID Keyboard Gadget"

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
    ok "dwc2 overlay already enabled in ${CONFIG_TXT}"
  else
    info "Enabling dwc2 overlay in ${CONFIG_TXT}…"
    echo "dtoverlay=dwc2" >> "${CONFIG_TXT}"
    ok "dwc2 overlay enabled"
    HID_NEEDS_REBOOT=true
  fi

  # ── Remove stale dr_mode=host from config.txt ──
  if grep -q "dr_mode=host" "${CONFIG_TXT}" 2>/dev/null; then
    info "Removing dr_mode=host from ${CONFIG_TXT} (breaks USB gadget mode)…"
    sed -i '/dtoverlay=dwc2,dr_mode=host/d' "${CONFIG_TXT}"
    ok "dr_mode=host line removed"
    HID_NEEDS_REBOOT=true
  fi

  # ── Add dwc2 module ──
  if grep -q "^dwc2" /etc/modules 2>/dev/null; then
    ok "dwc2 module already in /etc/modules"
  else
    info "Adding dwc2 to /etc/modules…"
    echo "dwc2" >> /etc/modules
    ok "dwc2 added"
    HID_NEEDS_REBOOT=true
  fi

  # ── Add libcomposite module ──
  if grep -q "^libcomposite" /etc/modules 2>/dev/null; then
    ok "libcomposite module already in /etc/modules"
  else
    info "Adding libcomposite to /etc/modules…"
    echo "libcomposite" >> /etc/modules
    ok "libcomposite added"
    HID_NEEDS_REBOOT=true
  fi

  # ── Blacklist conflicting USB gadget drivers ──
  BLACKLIST_FILE="/etc/modprobe.d/morse-pi-no-gadget-conflict.conf"
  info "Blacklisting conflicting USB gadget modules…"
  cat > "${BLACKLIST_FILE}" <<'BLEOF'
# Morse-Pi: prevent legacy gadget drivers from grabbing the UDC
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

  # ── Create USB HID gadget setup script ──
  info "Writing HID gadget setup script to ${HID_SCRIPT}…"
  cat > "${HID_SCRIPT}" <<'HIDEOF'
#!/bin/bash
# Morse-Pi USB HID Keyboard Gadget Setup
set -e

modprobe libcomposite 2>/dev/null || true

GADGET_DIR="/sys/kernel/config/usb_gadget/morse-pi-keyboard"

for mod in g_ether g_serial g_mass_storage g_multi g_zero g_webcam; do
  if lsmod | grep -q "^${mod} "; then
    echo "Removing conflicting gadget module: ${mod}"
    rmmod "${mod}" 2>/dev/null || true
  fi
done

for mod in usb_f_ecm usb_f_rndis u_ether usb_f_acm u_serial; do
  if lsmod | grep -q "^${mod} "; then
    rmmod "${mod}" 2>/dev/null || true
  fi
done

if [[ -d "${GADGET_DIR}" ]]; then
  CURRENT_UDC=$(cat "${GADGET_DIR}/UDC" 2>/dev/null | tr -d '[:space:]')
  if [[ -n "${CURRENT_UDC}" ]]; then
    echo "USB HID already bound to ${CURRENT_UDC}"
    exit 0
  fi
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

  # ── udev rule so /dev/hidg0 is world-writable ──
  UDEV_RULE="/etc/udev/rules.d/99-morse-pi-hid.rules"
  info "Creating udev rule for /dev/hidg0 permissions…"
  cat > "${UDEV_RULE}" <<'UDEVEOF'
KERNEL=="hidg[0-9]*", MODE="0666"
UDEVEOF
  udevadm control --reload-rules 2>/dev/null || true
  udevadm trigger 2>/dev/null || true
  ok "udev rule created at ${UDEV_RULE}"

  # ── systemd service for HID gadget ──
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
  systemctl enable "${HID_SERVICE_NAME}" 2>&1
  ok "HID service enabled for boot"

  if [[ -d /sys/kernel/config/usb_gadget ]] || modprobe libcomposite 2>/dev/null; then
    if systemctl start "${HID_SERVICE_NAME}" 2>/dev/null; then
      ok "HID gadget is active now"
    else
      warn "HID gadget couldn't start yet — will work after reboot"
      HID_NEEDS_REBOOT=true
    fi
  else
    HID_NEEDS_REBOOT=true
  fi

  if [[ -e /dev/hidg0 ]]; then
    chmod 666 /dev/hidg0
    ok "/dev/hidg0 ready"
  fi

  if [[ "${HID_NEEDS_REBOOT}" == "true" ]]; then
    warn "A reboot is required for USB HID to fully activate"
  fi
else
  info "Not a Raspberry Pi — skipping USB HID gadget setup"
fi

# ===========================================================================
#  STEP 2 — Install Rust toolchain + build dependencies
# ===========================================================================
banner "Step 2 / 4 — Rust Toolchain & Build Dependencies"

info "Refreshing package lists…"
apt-get update -qq || warn "apt-get update had issues — continuing anyway"

# System packages needed for building
PKGS=(git build-essential)

# GPIO libraries (Pi only)
if [[ "${IS_PI}" == "true" ]]; then
  PKGS+=(pigpio libpigpio-dev)
fi

for pkg in "${PKGS[@]}"; do
  if dpkg -s "$pkg" &>/dev/null; then
    ok "$pkg already installed"
  else
    info "Installing $pkg…"
    apt-get install -y "$pkg" -qq
    ok "$pkg installed"
  fi
done

# GPIO daemon (Pi only)
if [[ "${IS_PI}" == "true" ]]; then
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

# Install Rust toolchain
CARGO_HOME="/home/${RUN_USER}/.cargo"

if sudo -u "${RUN_USER}" bash -c "source ${CARGO_HOME}/env 2>/dev/null; command -v cargo" &>/dev/null; then
  CURRENT_RUST=$(sudo -u "${RUN_USER}" bash -c "source ${CARGO_HOME}/env 2>/dev/null; rustc --version" 2>/dev/null || echo "unknown")
  ok "Rust already installed: ${CURRENT_RUST}"
  info "Updating to latest stable…"
  sudo -u "${RUN_USER}" bash -c "source ${CARGO_HOME}/env 2>/dev/null; rustup update stable" 2>/dev/null || true
else
  info "Installing Rust via rustup (as user ${RUN_USER})…"
  sudo -u "${RUN_USER}" bash -c 'curl --proto "=https" --tlsv1.2 -sSf https://sh.rustup.rs | sh -s -- -y --profile minimal' || die "Rust installation failed"

  if [[ -f "${CARGO_HOME}/env" ]]; then
    source "${CARGO_HOME}/env"
  fi
  export PATH="${CARGO_HOME}/bin:${PATH}"

  if ! sudo -u "${RUN_USER}" bash -c "source ${CARGO_HOME}/env 2>/dev/null; command -v cargo" &>/dev/null; then
    die "Cargo not found after installation. Check ${CARGO_HOME}/bin"
  fi
  ok "Rust installed: $(sudo -u "${RUN_USER}" bash -c "source ${CARGO_HOME}/env; rustc --version")"
fi

export PATH="${CARGO_HOME}/bin:${PATH}"

# ===========================================================================
#  STEP 3 — Clone repository & build
# ===========================================================================
banner "Step 3 / 4 — Clone Repository & Build"

info "Cloning ${REPO_URL} → ${INSTALL_DIR}…"
git clone --branch "${BRANCH}" "${REPO_URL}" "${INSTALL_DIR}" || die "Git clone failed"
ok "Repository cloned"

if [[ ! -d "${RUST_SRC}" ]]; then
  die "morse-translator-rust/ not found at ${RUST_SRC}. Is it pushed to the ${BRANCH} branch?"
fi
ok "Rust source found at ${RUST_SRC}"

if [[ ! -d "${APP_DIR}" ]]; then
  die "morse-translator/ not found at ${APP_DIR}. Is the repo structured correctly?"
fi

# Set ownership before building (cargo writes to target/)
chown -R "${RUN_USER}:${RUN_USER}" "${INSTALL_DIR}"
chmod -R u+rw "${INSTALL_DIR}"

# Build the Rust binary
cd "${RUST_SRC}"

if [[ "${IS_PI}" == "true" ]]; then
  info "Building with GPIO support (Raspberry Pi detected)…"
  BUILD_CMD="cargo build --release --features gpio"
else
  info "Building WITHOUT GPIO support (not a Raspberry Pi)…"
  BUILD_CMD="cargo build --release"
fi

info "Running: ${BUILD_CMD}"
info "This may take 10-30 minutes on a Pi Zero. Please be patient…"

if ! sudo -u "${RUN_USER}" bash -c "source ${CARGO_HOME}/env 2>/dev/null; cd ${RUST_SRC}; ${BUILD_CMD}" 2>&1; then
  die "Rust build failed! Check the error output above."
fi

RUST_BINARY="${RUST_SRC}/target/release/${BINARY_NAME}"
if [[ ! -f "${RUST_BINARY}" ]]; then
  die "Build succeeded but binary not found at ${RUST_BINARY}."
fi
ok "Binary built: ${RUST_BINARY} ($(du -h "${RUST_BINARY}" | cut -f1))"

# Install binary into the app directory
info "Installing binary to ${APP_DIR}/${BINARY_NAME}…"
cp "${RUST_BINARY}" "${APP_DIR}/${BINARY_NAME}"
chmod +x "${APP_DIR}/${BINARY_NAME}"
chown "${RUN_USER}:${RUN_USER}" "${APP_DIR}/${BINARY_NAME}"
ok "Binary installed"

# Create default settings.json
SETTINGS_FILE="${APP_DIR}/settings.json"
if [[ ! -f "${SETTINGS_FILE}" ]]; then
  info "Creating default settings.json…"
  cat > "${SETTINGS_FILE}" <<'SETEOF'
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
SETEOF
  chown "${RUN_USER}:${RUN_USER}" "${SETTINGS_FILE}"
  chmod 644 "${SETTINGS_FILE}"
  ok "settings.json created"
fi

# Add user to gpio group
if getent group gpio &>/dev/null; then
  if ! id -nG "${RUN_USER}" | grep -qw "gpio"; then
    usermod -aG gpio "${RUN_USER}"
    ok "${RUN_USER} added to gpio group"
  fi
fi

# ===========================================================================
#  STEP 4 — Auto-start on boot (systemd)
# ===========================================================================
banner "Step 4 / 4 — Auto-start on boot"

# Remove stale drop-in overrides
DROPIN_DIR="/etc/systemd/system/${SERVICE_NAME}.service.d"
[[ -d "${DROPIN_DIR}" ]] && rm -rf "${DROPIN_DIR}"

info "Writing ${SERVICE_FILE}…"
cat > "${SERVICE_FILE}" <<SVCEOF
[Unit]
Description=Morse-Pi — Morse code trainer (Rust backend)
After=network-online.target pigpiod.service ${HID_SERVICE_NAME}.service
Wants=network-online.target pigpiod.service

[Service]
Type=simple
User=${RUN_USER}
Group=${RUN_USER}
WorkingDirectory=${APP_DIR}
ExecStart=${APP_DIR}/${BINARY_NAME}
Restart=always
RestartSec=3
StandardOutput=journal
StandardError=journal
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
    info "Opening port ${PORT} in ufw…"
    ufw allow ${PORT}/tcp --quiet
    ok "Port ${PORT} allowed"
  else
    ok "Port ${PORT} already allowed in ufw"
  fi
fi

# ===========================================================================
#  Done
# ===========================================================================
banner "Installation complete!"
echo -e "${GRN}${BLD}Morse-Pi (Rust) is running!${RST}"

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
echo -e "  To transition back to Python later:"
echo -e "    ${BLD}sudo rm -rf ${INSTALL_DIR}${RST}"
echo -e "    ${BLD}curl -sSL https://raw.githubusercontent.com/Nerd-or-Geek/Morse-Pi/main/install.sh | sudo bash${RST}"
echo ""
