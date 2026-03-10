#!/usr/bin/env bash
# =============================================================================
#  Morse-Pi  —  Package Updater
#  Run on your Raspberry Pi with:
#    curl -sSL https://raw.githubusercontent.com/Nerd-or-Geek/Morse-Pi/main/packages.sh | sudo bash
#
#  This script ensures all required system and Python packages are
#  installed and up to date. It does NOT modify application code,
#  settings, or services.
#
#  For a fresh install, use install.sh
#  For updating code, use update.sh
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
SERVICE_NAME="morse-pi"

# ── Sanity checks ─────────────────────────────────────────────────────────────
banner "Morse-Pi Package Updater"

if [[ $EUID -ne 0 ]]; then
  die "Run this script with sudo:  sudo bash packages.sh"
fi

IS_PI=false
if grep -qi "raspberry" /proc/device-tree/model 2>/dev/null; then
  IS_PI=true
  ok "Raspberry Pi detected: $(tr -d '\0' < /proc/device-tree/model)"
else
  warn "No Raspberry Pi detected — GPIO packages will be skipped."
fi

# ===========================================================================
#  STEP 1 — Update system package lists
# ===========================================================================
banner "Step 1 / 3 — System packages"

info "Refreshing package lists…"
apt-get update -qq
ok "Package lists updated"

# Core packages — install if missing, upgrade if outdated
CORE_PKGS=(python3 python3-pip git)
for pkg in "${CORE_PKGS[@]}"; do
  if dpkg -s "$pkg" &>/dev/null; then
    ok "$pkg installed"
  else
    info "Installing $pkg…"
    apt-get install -y "$pkg" -qq
    ok "$pkg installed"
  fi
done

# Upgrade core packages to latest available
info "Upgrading core system packages…"
apt-get install -y --only-upgrade "${CORE_PKGS[@]}" -qq 2>/dev/null || true
ok "Core packages up to date"

# GPIO packages (Pi only)
if [[ "${IS_PI}" == "true" ]]; then
  GPIO_PKGS=(python3-gpiozero pigpio python3-pigpio)
  for pkg in "${GPIO_PKGS[@]}"; do
    if dpkg -s "$pkg" &>/dev/null; then
      ok "$pkg installed"
    else
      info "Installing $pkg…"
      apt-get install -y "$pkg" -qq
      ok "$pkg installed"
    fi
  done

  info "Upgrading GPIO packages…"
  apt-get install -y --only-upgrade "${GPIO_PKGS[@]}" -qq 2>/dev/null || true
  ok "GPIO packages up to date"

  # Ensure pigpio daemon is running
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

# ===========================================================================
#  STEP 2 — Python packages
# ===========================================================================
banner "Step 2 / 3 — Python packages"

pkg_ok(){ python3 -c "import $1" 2>/dev/null; }

# Flask — install or upgrade
if pkg_ok flask; then
  FLASK_VER=$(python3 -c "import flask; print(flask.__version__)" 2>/dev/null)
  info "flask currently at v${FLASK_VER} — checking for updates…"
  pip3 install --upgrade flask --quiet --break-system-packages
  NEW_VER=$(python3 -c "import flask; print(flask.__version__)" 2>/dev/null)
  if [[ "${NEW_VER}" != "${FLASK_VER}" ]]; then
    ok "flask upgraded: v${FLASK_VER} → v${NEW_VER}"
  else
    ok "flask already at latest (v${FLASK_VER})"
  fi
else
  info "Installing flask…"
  pip3 install flask --quiet --break-system-packages
  ok "flask installed ($(python3 -c 'import flask;print(flask.__version__)' 2>/dev/null))"
fi

# gpiozero — install or upgrade
if pkg_ok gpiozero; then
  GZ_VER=$(python3 -c "import gpiozero; print(gpiozero.__version__)" 2>/dev/null)
  info "gpiozero currently at v${GZ_VER} — checking for updates…"
  pip3 install --upgrade gpiozero --quiet --break-system-packages
  NEW_VER=$(python3 -c "import gpiozero; print(gpiozero.__version__)" 2>/dev/null)
  if [[ "${NEW_VER}" != "${GZ_VER}" ]]; then
    ok "gpiozero upgraded: v${GZ_VER} → v${NEW_VER}"
  else
    ok "gpiozero already at latest (v${GZ_VER})"
  fi
else
  info "Installing gpiozero…"
  pip3 install gpiozero --quiet --break-system-packages
  ok "gpiozero installed"
fi

# requirements.txt if present
if [[ -f "${INSTALL_DIR}/requirements.txt" ]]; then
  info "Upgrading packages from requirements.txt…"
  pip3 install --upgrade -r "${INSTALL_DIR}/requirements.txt" --quiet --break-system-packages
  ok "requirements.txt packages updated"
fi

# ===========================================================================
#  STEP 3 — Restart service (pick up any updated libraries)
# ===========================================================================
banner "Step 3 / 3 — Restart service"

if systemctl is-active --quiet "${SERVICE_NAME}" 2>/dev/null; then
  info "Restarting ${SERVICE_NAME} to pick up updated packages…"
  systemctl restart "${SERVICE_NAME}"
  sleep 2
  if systemctl is-active --quiet "${SERVICE_NAME}"; then
    ok "${SERVICE_NAME} restarted and running"
  else
    warn "${SERVICE_NAME} may have failed to restart:"
    journalctl -u "${SERVICE_NAME}" --no-pager -n 15 2>/dev/null || true
  fi
elif systemctl is-enabled --quiet "${SERVICE_NAME}" 2>/dev/null; then
  info "Service is enabled but not running — starting…"
  systemctl start "${SERVICE_NAME}"
  sleep 2
  if systemctl is-active --quiet "${SERVICE_NAME}"; then
    ok "${SERVICE_NAME} started"
  else
    warn "${SERVICE_NAME} failed to start"
  fi
else
  info "${SERVICE_NAME} service not found — skipping restart"
  info "Run install.sh first if you haven't installed Morse-Pi yet."
fi

# ===========================================================================
#  Done
# ===========================================================================
banner "Package update complete!"
echo -e "${GRN}${BLD}All Morse-Pi packages are up to date.${RST}"
echo ""
echo -e "  ${BLD}Installed versions:${RST}"
echo -e "    Python   : $(python3 --version 2>/dev/null | awk '{print $2}')"
echo -e "    Flask    : $(python3 -c 'import flask;print(flask.__version__)' 2>/dev/null || echo 'not installed')"
echo -e "    gpiozero : $(python3 -c 'import gpiozero;print(gpiozero.__version__)' 2>/dev/null || echo 'not installed')"
echo -e "    pip      : $(pip3 --version 2>/dev/null | awk '{print $2}')"
echo -e "    git      : $(git --version 2>/dev/null | awk '{print $3}')"
echo ""
