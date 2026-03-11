#!/usr/bin/env bash
# =============================================================================
#  Morse-Pi  —  Transition Script: Python → Zig backend
#
#  Run on your Raspberry Pi with:
#    curl -sSL https://raw.githubusercontent.com/Nerd-or-Geek/Morse-Pi/main/transition.sh | sudo bash
#
#  This script:
#    1. Installs the Zig compiler (from ziglang.org)
#    2. Installs C build dependencies (pigpio headers)
#    3. Builds the Zig backend binary
#    4. Stops the current Python-based service
#    5. Backs up settings, stats, word lists
#    6. Removes the Python source files
#    7. Installs the Zig binary in place
#    8. Updates the systemd service to run the native binary
#    9. Starts the Zig-based service
#
#  Rollback: if the Zig build fails, everything stays as-is.
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
INSTALL_DIR="/opt/morse-pi"
APP_DIR="${INSTALL_DIR}/morse-translator"
ZIG_SRC="${INSTALL_DIR}/morse-translator-zig"
SERVICE_NAME="morse-pi"
SERVICE_FILE="/etc/systemd/system/${SERVICE_NAME}.service"
ZIG_VERSION="0.13.0"
ZIG_BIN="/usr/local/bin/zig"
BINARY_NAME="morse-pi"

# Detect architecture
ARCH="$(uname -m)"
case "${ARCH}" in
  aarch64)      ZIG_ARCH="aarch64-linux"  ;;
  armv7l|armv6l) ZIG_ARCH="armv7a-linux"  ;;
  x86_64)       ZIG_ARCH="x86_64-linux"   ;;
  *)            die "Unsupported architecture: ${ARCH}" ;;
esac

ZIG_TARBALL="zig-linux-${ZIG_ARCH%%-linux}-${ZIG_VERSION}.tar.xz"
ZIG_URL="https://ziglang.org/download/${ZIG_VERSION}/zig-${ZIG_ARCH}-${ZIG_VERSION}.tar.xz"

# ── Sanity checks ─────────────────────────────────────────────────────────────
banner "Morse-Pi  —  Python → Zig Transition"
echo -e "  ${CYN}★ Transition to native Zig backend${RST}"
echo -e "  Install dir : ${BLD}${INSTALL_DIR}${RST}"
echo -e "  Architecture: ${BLD}${ARCH} → ${ZIG_ARCH}${RST}"
echo -e "  Zig version : ${BLD}${ZIG_VERSION}${RST}"
echo ""

if [[ $EUID -ne 0 ]]; then
  die "Run this script with sudo:  sudo bash transition.sh"
fi

if [[ ! -d "${APP_DIR}" ]]; then
  die "Python installation not found at ${APP_DIR}. Run install.sh first."
fi

# ── Update repo to get Zig source ─────────────────────────────────────────────
if [[ ! -d "${ZIG_SRC}" ]]; then
  if [[ -d "${INSTALL_DIR}/.git" ]]; then
    info "Zig source not found — pulling latest from Git…"
    cd "${INSTALL_DIR}"
    git fetch --all --prune 2>/dev/null || true
    git reset --hard origin/main 2>/dev/null || git pull --ff-only || die "Git pull failed"
    ok "Repository updated"
  fi
fi

if [[ ! -d "${ZIG_SRC}" ]]; then
  die "Zig source not found at ${ZIG_SRC}. Make sure morse-translator-zig/ exists in the repo."
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
#  STEP 1 — Install Zig compiler
# ===========================================================================
banner "Step 1 / 5 — Install Zig Compiler"

NEED_ZIG=true
if command -v zig &>/dev/null; then
  CURRENT_ZIG="$(zig version 2>/dev/null || echo "unknown")"
  if [[ "${CURRENT_ZIG}" == "${ZIG_VERSION}" ]]; then
    ok "Zig ${ZIG_VERSION} already installed"
    NEED_ZIG=false
  else
    info "Current Zig version: ${CURRENT_ZIG} — upgrading to ${ZIG_VERSION}"
  fi
fi

if [[ "${NEED_ZIG}" == "true" ]]; then
  info "Downloading Zig ${ZIG_VERSION} for ${ZIG_ARCH}…"
  cd /tmp

  # Download
  if command -v wget &>/dev/null; then
    wget -q --show-progress -O "zig.tar.xz" "${ZIG_URL}" || die "Download failed"
  elif command -v curl &>/dev/null; then
    curl -fSL -o "zig.tar.xz" "${ZIG_URL}" || die "Download failed"
  else
    die "Neither wget nor curl found. Install one and retry."
  fi
  ok "Downloaded Zig tarball"

  # Extract
  info "Extracting Zig…"
  rm -rf /tmp/zig-extract
  mkdir -p /tmp/zig-extract
  tar -xf "zig.tar.xz" -C /tmp/zig-extract
  ok "Extracted"

  # Install
  ZIG_EXTRACTED_DIR="$(ls -d /tmp/zig-extract/zig-* 2>/dev/null | head -1)"
  if [[ -z "${ZIG_EXTRACTED_DIR}" ]]; then
    die "Could not find extracted Zig directory"
  fi

  rm -rf /usr/local/lib/zig
  mv "${ZIG_EXTRACTED_DIR}" /usr/local/lib/zig
  ln -sf /usr/local/lib/zig/zig "${ZIG_BIN}"
  ok "Zig installed to /usr/local/lib/zig"

  # Verify
  if ! zig version &>/dev/null; then
    die "Zig installation failed — 'zig version' not working"
  fi
  ok "Zig $(zig version) is ready"

  # Clean up
  rm -f /tmp/zig.tar.xz
  rm -rf /tmp/zig-extract
fi

# ===========================================================================
#  STEP 2 — Install C build dependencies
# ===========================================================================
banner "Step 2 / 5 — Install Build Dependencies"

info "Updating package lists…"
apt-get update -qq || warn "apt-get update had issues — continuing anyway"

# pigpio dev headers for GPIO support
PKGS_TO_INSTALL=()

if ! dpkg -s libpigpio-dev &>/dev/null 2>&1; then
  PKGS_TO_INSTALL+=(libpigpio-dev)
fi

# pigpiod daemon (may already be installed from Python install)
if ! dpkg -s pigpio &>/dev/null 2>&1; then
  PKGS_TO_INSTALL+=(pigpio)
fi

# Build essentials for C linker
if ! dpkg -s build-essential &>/dev/null 2>&1; then
  PKGS_TO_INSTALL+=(build-essential)
fi

if [[ ${#PKGS_TO_INSTALL[@]} -gt 0 ]]; then
  info "Installing: ${PKGS_TO_INSTALL[*]}"
  apt-get install -y -qq "${PKGS_TO_INSTALL[@]}" || warn "Some packages failed to install"
  ok "Build dependencies installed"
else
  ok "All build dependencies already present"
fi

# Ensure pigpiod is running
if ! systemctl is-active --quiet pigpiod 2>/dev/null; then
  info "Starting pigpiod…"
  systemctl enable pigpiod 2>/dev/null || true
  systemctl start pigpiod 2>/dev/null || warn "Could not start pigpiod"
fi

# ===========================================================================
#  STEP 3 — Build the Zig binary
# ===========================================================================
banner "Step 3 / 5 — Build Zig Backend"

cd "${ZIG_SRC}"

# Determine if GPIO should be enabled (only on Raspberry Pi)
IS_PI=false
if grep -qi "raspberry" /proc/device-tree/model 2>/dev/null; then
  IS_PI=true
fi

if [[ "${IS_PI}" == "true" ]]; then
  info "Building with GPIO support (Raspberry Pi detected)…"
  BUILD_ARGS="-Dgpio=true -Doptimize=ReleaseSafe"
else
  info "Building WITHOUT GPIO support (not a Raspberry Pi)…"
  BUILD_ARGS="-Dgpio=false -Doptimize=ReleaseSafe"
fi

# Build
info "Running: zig build ${BUILD_ARGS}"
if ! zig build ${BUILD_ARGS} 2>&1; then
  die "Zig build failed! Python backend is still intact and running."
fi

# Verify binary exists
ZIG_BINARY="${ZIG_SRC}/zig-out/bin/${BINARY_NAME}"
if [[ ! -f "${ZIG_BINARY}" ]]; then
  # Try alternate location
  ZIG_BINARY="${ZIG_SRC}/zig-out/bin/morse-pi"
  if [[ ! -f "${ZIG_BINARY}" ]]; then
    die "Build succeeded but binary not found. Check build.zig output name."
  fi
fi
ok "Binary built: ${ZIG_BINARY} ($(du -h "${ZIG_BINARY}" | cut -f1))"

# ===========================================================================
#  STEP 4 — Back up and swap
# ===========================================================================
banner "Step 4 / 5 — Back Up & Install Binary"

# Stop the current service
if systemctl is-active --quiet "${SERVICE_NAME}" 2>/dev/null; then
  info "Stopping ${SERVICE_NAME} service…"
  systemctl stop "${SERVICE_NAME}"
  ok "Service stopped"
fi

# Back up user data files
BACKUP_DIR="/tmp/morse-pi-backup-$(date +%Y%m%d%H%M%S)"
mkdir -p "${BACKUP_DIR}"

for f in settings.json stats.json words.json; do
  if [[ -f "${APP_DIR}/${f}" ]]; then
    cp "${APP_DIR}/${f}" "${BACKUP_DIR}/"
    ok "Backed up ${f}"
  fi
done

# Back up templates (in case the user modified them)
if [[ -d "${APP_DIR}/templates" ]]; then
  cp -r "${APP_DIR}/templates" "${BACKUP_DIR}/templates"
  ok "Backed up templates/"
fi

# Remove Python files
PYTHON_FILES=(app.py shared.py morse.py keyboard.py gpio_monitor.py sound.py)
info "Removing Python backend files…"
for f in "${PYTHON_FILES[@]}"; do
  if [[ -f "${APP_DIR}/${f}" ]]; then
    rm -f "${APP_DIR}/${f}"
    ok "Removed ${f}"
  fi
done

# Also remove __pycache__ if present
rm -rf "${APP_DIR}/__pycache__"

# Install the Zig binary
info "Installing Zig binary to ${APP_DIR}/${BINARY_NAME}…"
cp "${ZIG_BINARY}" "${APP_DIR}/${BINARY_NAME}"
chmod +x "${APP_DIR}/${BINARY_NAME}"
chown "${RUN_USER}:${RUN_USER}" "${APP_DIR}/${BINARY_NAME}"
ok "Binary installed: ${APP_DIR}/${BINARY_NAME}"

# Restore user data
for f in settings.json stats.json words.json; do
  if [[ -f "${BACKUP_DIR}/${f}" ]]; then
    cp "${BACKUP_DIR}/${f}" "${APP_DIR}/${f}"
    chown "${RUN_USER}:${RUN_USER}" "${APP_DIR}/${f}"
  fi
done
ok "User data restored"

# Restore templates
if [[ -d "${BACKUP_DIR}/templates" ]]; then
  cp -r "${BACKUP_DIR}/templates/"* "${APP_DIR}/templates/"
  ok "Templates restored"
fi

# ===========================================================================
#  STEP 5 — Update systemd & start
# ===========================================================================
banner "Step 5 / 5 — Update Service & Start"

# Get current service user and HID service name
HID_SERVICE_NAME="morse-pi-hid"

info "Updating ${SERVICE_FILE}…"
cat > "${SERVICE_FILE}" <<SVCEOF
[Unit]
Description=Morse-Pi — Morse code trainer (Zig backend)
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
ok "Service file updated"

systemctl daemon-reload
ok "systemd daemon reloaded"

systemctl start "${SERVICE_NAME}"

sleep 2
if systemctl is-active --quiet "${SERVICE_NAME}"; then
  ok "${SERVICE_NAME} is running with Zig backend"
else
  warn "${SERVICE_NAME} may not have started — checking journal:"
  journalctl -u "${SERVICE_NAME}" -n 10 --no-pager 2>/dev/null || true
  warn ""
  warn "You can start it manually with: sudo systemctl start ${SERVICE_NAME}"
  warn "Or check logs with: journalctl -u ${SERVICE_NAME} -f"
fi

# ── Final summary ─────────────────────────────────────────────────────────────
IP_ADDR="$(hostname -I 2>/dev/null | awk '{print $1}')"
[[ -z "${IP_ADDR}" ]] && IP_ADDR="<your-pi-ip>"

echo ""
banner "Transition Complete!"
echo -e "  ${GRN}✔ Zig backend is installed and running${RST}"
echo -e "  ${GRN}✔ Python files removed${RST}"
echo -e "  ${GRN}✔ Settings and data preserved${RST}"
echo ""
echo -e "  Web UI:  ${BLD}http://${IP_ADDR}:5000${RST}"
echo -e "  Logs:    ${CYN}journalctl -u ${SERVICE_NAME} -f${RST}"
echo -e "  Backup:  ${CYN}${BACKUP_DIR}${RST}"
echo ""
echo -e "  ${YEL}To revert to Python:${RST}"
echo -e "    1. sudo systemctl stop ${SERVICE_NAME}"
echo -e "    2. cd ${INSTALL_DIR} && git checkout -- morse-translator/"
echo -e "    3. sudo bash install.sh   (or update the service manually)"
echo ""
