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
if [[ -d "${INSTALL_DIR}/.git" ]]; then
  banner "Morse-Pi Updater"
  echo -e "  ${GRN}★ Existing installation detected — will update${RST}"
else
  banner "Morse-Pi Installer"
  echo -e "  ${CYN}★ Fresh installation${RST}"
fi
echo -e "  Repo   : ${BLD}${REPO_URL}${RST}"
echo -e "  Branch : ${BLD}${BRANCH}${RST}"
echo -e "  Target : ${BLD}${INSTALL_DIR}${RST}"
echo -e "  Port   : ${BLD}${PORT}${RST}"
echo ""

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
banner "Step 1 / 5 — System packages"
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

# ── Clone / update repo ────────────────────────────────────────────────────────
banner "Step 2 / 5 — Repository"
if [[ -d "${INSTALL_DIR}/.git" ]]; then
  IS_UPDATE=true
  info "Existing installation found at ${INSTALL_DIR}. Updating…"
  
  # Backup settings.json before git reset (preserves user configuration)
  SETTINGS_BACKUP=""
  if [[ -f "${APP_DIR}/settings.json" ]]; then
    SETTINGS_BACKUP=$(mktemp)
    cp "${APP_DIR}/settings.json" "${SETTINGS_BACKUP}"
    info "Backed up settings.json"
  fi
  
  git -C "${INSTALL_DIR}" fetch --quiet origin "${BRANCH}"
  git -C "${INSTALL_DIR}" reset --hard "origin/${BRANCH}" --quiet
  
  # Restore settings.json after git reset
  if [[ -n "${SETTINGS_BACKUP}" && -f "${SETTINGS_BACKUP}" ]]; then
    cp "${SETTINGS_BACKUP}" "${APP_DIR}/settings.json"
    rm -f "${SETTINGS_BACKUP}"
    ok "Restored user settings.json"
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
banner "Step 3 / 5 — Python packages"

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
banner "Step 4 / 5 — Systemd service"

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
ok "Service file written to ${SERVICE_FILE}"

info "Reloading systemd daemon…"
systemctl daemon-reload
ok "systemd reloaded"

if systemctl is-active --quiet "${SERVICE_NAME}"; then
  info "Restarting ${SERVICE_NAME}…"
  systemctl restart "${SERVICE_NAME}"
  ok "${SERVICE_NAME} restarted"
else
  info "Enabling and starting ${SERVICE_NAME}…"
  systemctl enable "${SERVICE_NAME}" --now
  ok "${SERVICE_NAME} enabled and started"
fi

# Wait briefly for the service to come up before showing the URL
sleep 2

# ── Firewall ───────────────────────────────────────────────────────────────────
banner "Step 5 / 5 — Firewall"
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
