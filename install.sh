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
REPO_URL="https://github.com/Nerd-or-Geek/Morse-Pi.git"   # ← edit before running
BRANCH="main"
INSTALL_DIR="/opt/morse-pi"
VENV_DIR="${INSTALL_DIR}/venv"
APP_DIR="${INSTALL_DIR}/morse-translator"
SERVICE_NAME="morse-pi"
SERVICE_FILE="/etc/systemd/system/${SERVICE_NAME}.service"
PORT=5000

# ── Sanity checks ──────────────────────────────────────────────────────────────
banner "Morse-Pi Installer"
echo -e "  Repo   : ${BLD}${REPO_URL}${RST}"
echo -e "  Branch : ${BLD}${BRANCH}${RST}"
echo -e "  Target : ${BLD}${INSTALL_DIR}${RST}"
echo -e "  Port   : ${BLD}${PORT}${RST}"
echo ""

if [[ "${REPO_URL}" == *"YOUR_USERNAME"* ]]; then
  die "Please edit REPO_URL in this script before running it."
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
banner "Step 1 / 5 — System packages"
info "Refreshing package lists…"
apt-get update -qq

PKGS=(python3 python3-pip python3-venv git)
for pkg in "${PKGS[@]}"; do
  if dpkg -s "$pkg" &>/dev/null; then
    ok "$pkg already installed"
  else
    info "Installing $pkg…"
    apt-get install -y "$pkg" -qq
    ok "$pkg installed"
  fi
done

# gpiozero + pigpio work best from apt on Pi OS
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

  # Enable pigpio daemon so gpiozero hardware PWM works
  if ! systemctl is-enabled pigpiod &>/dev/null; then
    info "Enabling pigpio daemon…"
    systemctl enable pigpiod --now
    ok "pigpio daemon started"
  else
    ok "pigpio daemon already enabled"
  fi
fi

# ── Clone / update repo ────────────────────────────────────────────────────────
banner "Step 2 / 5 — Repository"
if [[ -d "${INSTALL_DIR}/.git" ]]; then
  info "Repo already exists at ${INSTALL_DIR}. Pulling latest changes…"
  git -C "${INSTALL_DIR}" fetch --quiet origin "${BRANCH}"
  git -C "${INSTALL_DIR}" reset --hard "origin/${BRANCH}" --quiet
  ok "Repository updated to latest ${BRANCH}"
else
  info "Cloning ${REPO_URL} → ${INSTALL_DIR}…"
  git clone --branch "${BRANCH}" --depth 1 "${REPO_URL}" "${INSTALL_DIR}"
  ok "Repository cloned"
fi

if [[ ! -f "${APP_DIR}/app.py" ]]; then
  die "app.py not found at ${APP_DIR}. Check your REPO_URL and directory structure."
fi
ok "app.py found at ${APP_DIR}"

# ── Python virtual environment ─────────────────────────────────────────────────
banner "Step 3 / 5 — Python environment"
if [[ -d "${VENV_DIR}" ]]; then
  ok "Virtual environment already exists at ${VENV_DIR}"
else
  info "Creating virtual environment…"
  python3 -m venv "${VENV_DIR}"
  ok "Virtual environment created"
fi

info "Upgrading pip…"
"${VENV_DIR}/bin/pip" install --upgrade pip --quiet
ok "pip up to date"

# Core Python dependencies
PYTHON_PKGS=(flask)
# gpiozero via pip as fallback if apt version unavailable
if ! python3 -c "import gpiozero" 2>/dev/null; then
  PYTHON_PKGS+=(gpiozero)
fi

info "Installing Python packages: ${PYTHON_PKGS[*]}…"
"${VENV_DIR}/bin/pip" install "${PYTHON_PKGS[@]}" --quiet
ok "Python packages installed"

# Install from requirements.txt if present
if [[ -f "${INSTALL_DIR}/requirements.txt" ]]; then
  info "Installing from requirements.txt…"
  "${VENV_DIR}/bin/pip" install -r "${INSTALL_DIR}/requirements.txt" --quiet
  ok "requirements.txt packages installed"
fi

# ── Systemd service ────────────────────────────────────────────────────────────
banner "Step 4 / 5 — Systemd service"

# Resolve the actual user who invoked sudo (fall back to 'pi' → root)
if [[ -n "${SUDO_USER:-}" ]]; then
  RUN_USER="${SUDO_USER}"
else
  RUN_USER="$(id -un)"
fi
info "Service will run as user: ${RUN_USER}"

cat > "${SERVICE_FILE}" <<EOF
[Unit]
Description=Morse-Pi — Morse code trainer web app
After=network.target
Wants=network.target

[Service]
Type=simple
User=${RUN_USER}
WorkingDirectory=${APP_DIR}
ExecStart=${VENV_DIR}/bin/python app.py
Restart=on-failure
RestartSec=5
StandardOutput=journal
StandardError=journal
# Give gpiozero/pigpio time to initialise on boot
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
banner "Installation complete!"

# Determine the Pi's LAN IP(s) for display
IPS=$(hostname -I 2>/dev/null | tr ' ' '\n' | grep -v '^$' | grep -v '^127\.' | head -5)

echo -e "${GRN}${BLD}Morse-Pi is running!${RST}"
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
echo -e "  To update later, re-run this script or:"
echo -e "    ${BLD}sudo git -C ${INSTALL_DIR} pull && sudo systemctl restart ${SERVICE_NAME}${RST}"
echo ""
