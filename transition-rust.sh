#!/usr/bin/env bash
# =============================================================================
#  Morse-Pi  —  Transition Script: Python → Rust backend
#
#  One-liner install:
#    curl -sSL https://raw.githubusercontent.com/Nerd-or-Geek/Morse-Pi/main/transition-rust.sh | sudo bash
#
#  This script:
#    1. Installs the Rust toolchain via rustup             (200–400 MB)
#    2. Installs C build dependencies (pigpio headers)
#    3. Builds the Rust backend binary (cargo build)
#    4. Stops the current Python-based service
#    5. Backs up settings, stats, word lists
#    6. Removes the Python source files
#    7. Installs the Rust binary in place
#    8. Updates the systemd service to run the native binary
#    9. Starts the Rust-based service
#
#  Rollback: if the build fails, everything stays as-is.
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
BINARY_NAME="morse-pi"

# Detect architecture
ARCH="$(uname -m)"
info "Detected architecture: ${ARCH}"

# ── Sanity checks ─────────────────────────────────────────────────────────────
banner "Morse-Pi  —  Python → Rust Transition"
echo -e "  ${CYN}★ Transition to native Rust backend${RST}"
echo -e "  Install dir : ${BLD}${INSTALL_DIR}${RST}"
echo -e "  Architecture: ${BLD}${ARCH}${RST}"
echo ""

if [[ $EUID -ne 0 ]]; then
  die "Run this script with sudo:  sudo bash transition-rust.sh"
fi

# ── Disk space check ──────────────────────────────────────────────────────────
AVAIL_ROOT_MB=$(df -BM / 2>/dev/null | awk 'NR==2{gsub(/M/,""); print $4}' || echo 0)
NEEDED_MB=600
info "Available disk space: / = ${AVAIL_ROOT_MB} MB (need ~${NEEDED_MB} MB for Rust toolchain + build)"

if [[ "${AVAIL_ROOT_MB}" -lt "${NEEDED_MB}" ]]; then
  warn "Low disk space — attempting cleanup…"
  apt-get clean 2>/dev/null || true
  apt-get autoremove -y -qq 2>/dev/null || true
  rm -rf "${APP_DIR}/__pycache__" 2>/dev/null || true
  journalctl --vacuum-size=10M 2>/dev/null || true

  AVAIL_ROOT_MB=$(df -BM / 2>/dev/null | awk 'NR==2{gsub(/M/,""); print $4}' || echo 0)
  info "After cleanup: ${AVAIL_ROOT_MB} MB available"

  if [[ "${AVAIL_ROOT_MB}" -lt "${NEEDED_MB}" ]]; then
    die "Not enough disk space (${AVAIL_ROOT_MB} MB free, need ~${NEEDED_MB} MB).
    The Rust toolchain + build cache need ~500-600 MB.
    Free some space and try again."
  fi
fi

# ── Pull the full repo ────────────────────────────────────────────────────────
banner "Updating Repository"

if [[ -d "${INSTALL_DIR}/.git" ]]; then
  info "Git repo found at ${INSTALL_DIR} — pulling latest…"
  cd "${INSTALL_DIR}"
  git fetch --all --prune || true
  git checkout "${BRANCH}" 2>/dev/null || true
  git reset --hard "origin/${BRANCH}" || die "Git reset failed"
  ok "Repository updated via git pull"
elif [[ -d "${INSTALL_DIR}" ]]; then
  info "No git repo at ${INSTALL_DIR} — re-cloning full repo…"
  TMPBACKUP="$(mktemp -d)"
  for f in settings.json stats.json words.json; do
    [[ -f "${APP_DIR}/${f}" ]] && cp "${APP_DIR}/${f}" "${TMPBACKUP}/"
  done
  [[ -d "${APP_DIR}/templates" ]] && cp -r "${APP_DIR}/templates" "${TMPBACKUP}/templates"
  rm -rf "${INSTALL_DIR}"
  git clone --branch "${BRANCH}" "${REPO_URL}" "${INSTALL_DIR}" || die "Git clone failed"
  for f in settings.json stats.json words.json; do
    [[ -f "${TMPBACKUP}/${f}" ]] && cp "${TMPBACKUP}/${f}" "${APP_DIR}/${f}"
  done
  [[ -d "${TMPBACKUP}/templates" ]] && cp -r "${TMPBACKUP}/templates/"* "${APP_DIR}/templates/" 2>/dev/null || true
  rm -rf "${TMPBACKUP}"
  ok "Full repo cloned and user data preserved"
else
  info "No installation found — cloning fresh…"
  git clone --branch "${BRANCH}" "${REPO_URL}" "${INSTALL_DIR}" || die "Git clone failed"
  ok "Repository cloned"
fi

if [[ ! -d "${APP_DIR}" ]]; then
  die "morse-translator/ not found at ${APP_DIR}. Is the repo structured correctly?"
fi

if [[ ! -d "${RUST_SRC}" ]]; then
  die "morse-translator-rust/ not found at ${RUST_SRC}. Is it pushed to the ${BRANCH} branch?"
fi
ok "Rust source found at ${RUST_SRC}"

# ── Self-update: re-exec from the repo copy if we're running from curl/stdin ──
REPO_SCRIPT="${INSTALL_DIR}/transition-rust.sh"
if [[ -f "${REPO_SCRIPT}" ]] && [[ "${BASH_SOURCE[0]:-}" != "${REPO_SCRIPT}" ]]; then
  info "Re-executing transition-rust.sh from ${REPO_SCRIPT}…"
  exec bash "${REPO_SCRIPT}" "$@"
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
#  STEP 1 — Install Rust toolchain
# ===========================================================================
banner "Step 1 / 5 — Install Rust Toolchain"

NEED_RUST=true
if command -v cargo &>/dev/null; then
  CURRENT_RUST="$(rustc --version 2>/dev/null || echo "unknown")"
  ok "Rust already installed: ${CURRENT_RUST}"
  info "Updating to latest stable…"
  # Update as the user who owns the toolchain
  sudo -u "${RUN_USER}" rustup update stable 2>/dev/null || true
  NEED_RUST=false
fi

if [[ "${NEED_RUST}" == "true" ]]; then
  info "Installing Rust via rustup (as user ${RUN_USER})…"

  # rustup installs per-user by default — install for the run user
  sudo -u "${RUN_USER}" bash -c 'curl --proto "=https" --tlsv1.2 -sSf https://sh.rustup.rs | sh -s -- -y --profile minimal' || die "Rust installation failed"

  # Source the environment
  CARGO_HOME="/home/${RUN_USER}/.cargo"
  if [[ -f "${CARGO_HOME}/env" ]]; then
    source "${CARGO_HOME}/env"
  fi
  # Also make cargo available for this script
  export PATH="${CARGO_HOME}/bin:${PATH}"

  if ! command -v cargo &>/dev/null; then
    die "Cargo not found after installation. Check ~/.cargo/bin"
  fi
  ok "Rust installed: $(rustc --version)"
fi

# Ensure cargo is on our PATH for the rest of the script
CARGO_HOME="/home/${RUN_USER}/.cargo"
export PATH="${CARGO_HOME}/bin:${PATH}"

# ===========================================================================
#  STEP 2 — Install C build dependencies
# ===========================================================================
banner "Step 2 / 5 — Install Build Dependencies"

info "Updating package lists…"
apt-get update -qq || warn "apt-get update had issues — continuing anyway"

PKGS_TO_INSTALL=()

if ! dpkg -s libpigpio-dev &>/dev/null 2>&1; then
  PKGS_TO_INSTALL+=(libpigpio-dev)
fi
if ! dpkg -s pigpio &>/dev/null 2>&1; then
  PKGS_TO_INSTALL+=(pigpio)
fi
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
#  STEP 3 — Build the Rust binary
# ===========================================================================
banner "Step 3 / 5 — Build Rust Backend"

cd "${RUST_SRC}"

# Determine if GPIO should be enabled (only on Raspberry Pi)
IS_PI=false
if grep -qi "raspberry" /proc/device-tree/model 2>/dev/null; then
  IS_PI=true
fi

if [[ "${IS_PI}" == "true" ]]; then
  info "Building with GPIO support (Raspberry Pi detected)…"
  BUILD_CMD="cargo build --release --features gpio"
else
  info "Building WITHOUT GPIO support (not a Raspberry Pi)…"
  BUILD_CMD="cargo build --release"
fi

info "Running: ${BUILD_CMD}"
info "This may take 10-30 minutes on a Pi Zero. Please be patient…"

# Build as the run user (so cargo uses their toolchain)
if ! sudo -u "${RUN_USER}" bash -c "source ${CARGO_HOME}/env 2>/dev/null; cd ${RUST_SRC}; ${BUILD_CMD}" 2>&1; then
  die "Rust build failed! Python backend is still intact and running."
fi

# Verify binary exists
RUST_BINARY="${RUST_SRC}/target/release/${BINARY_NAME}"
if [[ ! -f "${RUST_BINARY}" ]]; then
  die "Build succeeded but binary not found at ${RUST_BINARY}. Check Cargo.toml [[bin]] name."
fi
ok "Binary built: ${RUST_BINARY} ($(du -h "${RUST_BINARY}" | cut -f1))"

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
rm -rf "${APP_DIR}/__pycache__"

# Install the Rust binary
info "Installing Rust binary to ${APP_DIR}/${BINARY_NAME}…"
cp "${RUST_BINARY}" "${APP_DIR}/${BINARY_NAME}"
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

if [[ -d "${BACKUP_DIR}/templates" ]]; then
  cp -r "${BACKUP_DIR}/templates/"* "${APP_DIR}/templates/"
  ok "Templates restored"
fi

# ===========================================================================
#  STEP 5 — Update systemd & start
# ===========================================================================
banner "Step 5 / 5 — Update Service & Start"

HID_SERVICE_NAME="morse-pi-hid"

info "Updating ${SERVICE_FILE}…"
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
ok "Service file updated"

systemctl daemon-reload
ok "systemd daemon reloaded"

systemctl start "${SERVICE_NAME}"

sleep 2
if systemctl is-active --quiet "${SERVICE_NAME}"; then
  ok "${SERVICE_NAME} is running with Rust backend"
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
echo -e "  ${GRN}✔ Rust backend is installed and running${RST}"
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
