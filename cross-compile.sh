#!/usr/bin/env bash
# =============================================================================
#  Morse-Pi — Cross-compile Zig backend and deploy to Raspberry Pi
#
#  Usage:
#    ./cross-compile.sh                          # Interactive
#    ./cross-compile.sh pizero-5                 # Deploy to named Pi
#    ./cross-compile.sh 192.168.1.42             # Deploy to IP
#    ./cross-compile.sh --build-only             # Just build, don't deploy
#
#  Defaults to Pi Zero (armv6l) target.  Override with:
#    PI_MODEL=pi3 ./cross-compile.sh pizero-5    # Build for Pi 3 (aarch64)
#    PI_MODEL=pi4 ./cross-compile.sh pizero-5    # Build for Pi 4 (aarch64)
#
#  Requirements:
#    - Zig 0.13.0+  (https://ziglang.org/download/)
#    - SSH access to the Pi (key-based recommended)
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
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ZIG_SRC="${SCRIPT_DIR}/morse-translator-zig"
BINARY_NAME="morse-pi"
PI_USER="${PI_USER:-pi}"
PI_PATH="${PI_PATH:-/opt/morse-pi}"
PI_MODEL="${PI_MODEL:-pizero}"
BUILD_ONLY=false
PI_HOST=""

# Parse arguments
for arg in "$@"; do
  case "${arg}" in
    --build-only) BUILD_ONLY=true ;;
    --pi3|--pi4|--pi5) PI_MODEL="${arg#--}" ;;
    --pizero)     PI_MODEL="pizero" ;;
    -*)           die "Unknown option: ${arg}" ;;
    *)            PI_HOST="${arg}" ;;
  esac
done

# Target triple based on Pi model
case "${PI_MODEL}" in
  pizero|pi1)
    TARGET="arm-linux-musleabihf"
    CPU="arm1176jzf_s"
    ;;
  pi2)
    TARGET="arm-linux-musleabihf"
    CPU="cortex_a7"
    ;;
  pi3)
    TARGET="aarch64-linux-musl"
    CPU="cortex_a53"
    ;;
  pi4)
    TARGET="aarch64-linux-musl"
    CPU="cortex_a72"
    ;;
  pi5)
    TARGET="aarch64-linux-musl"
    CPU="cortex_a76"
    ;;
  *)
    die "Unknown PI_MODEL: ${PI_MODEL}. Use: pizero, pi1, pi2, pi3, pi4, pi5"
    ;;
esac

# ── Verify source ─────────────────────────────────────────────────────────────
banner "Morse-Pi Cross-Compiler"
echo -e "  Model  : ${BLD}${PI_MODEL}${RST}"
echo -e "  Target : ${BLD}${TARGET}${RST}"
echo -e "  CPU    : ${BLD}${CPU}${RST}"
echo -e "  Source : ${BLD}${ZIG_SRC}${RST}"
echo ""

[[ -d "${ZIG_SRC}" ]]           || die "Zig source dir not found: ${ZIG_SRC}"
[[ -f "${ZIG_SRC}/build.zig" ]] || die "build.zig not found in ${ZIG_SRC}"

# ── Check Zig ─────────────────────────────────────────────────────────────────
banner "Step 1 / 3 — Check Zig"

if ! command -v zig &>/dev/null; then
  die "Zig not found on PATH. Install from https://ziglang.org/download/"
fi

ZIG_VER="$(zig version 2>/dev/null)"
ok "Zig ${ZIG_VER} found at $(command -v zig)"

# ── Cross-compile ─────────────────────────────────────────────────────────────
banner "Step 2 / 3 — Cross-Compile for ${PI_MODEL} (${TARGET})"

cd "${ZIG_SRC}"

BUILD_CMD="zig build -Dtarget=${TARGET} -Dcpu=${CPU} -Dgpio=false -Doptimize=ReleaseSafe"
info "Running: ${BUILD_CMD}"

if ! ${BUILD_CMD} 2>&1; then
  die "Zig build failed!"
fi

BINARY="${ZIG_SRC}/zig-out/bin/${BINARY_NAME}"
if [[ ! -f "${BINARY}" ]]; then
  die "Binary not found at ${BINARY}"
fi

SIZE="$(du -h "${BINARY}" | cut -f1)"
ok "Binary built: ${BINARY} (${SIZE})"

# ── Deploy ────────────────────────────────────────────────────────────────────
if [[ "${BUILD_ONLY}" == "true" ]]; then
  banner "Build Complete (deploy skipped)"
  echo -e "  Binary: ${BLD}${BINARY}${RST}"
  echo ""
  echo -e "  To deploy manually:"
  echo -e "    scp \"${BINARY}\" ${PI_USER}@<pi-host>:${PI_PATH}/morse-translator/${BINARY_NAME}"
  echo -e "    ssh ${PI_USER}@<pi-host> 'sudo bash ${PI_PATH}/transition.sh --deploy'"
  exit 0
fi

banner "Step 3 / 3 — Deploy to Pi"

if [[ -z "${PI_HOST}" ]]; then
  echo -n "Enter Pi hostname or IP (e.g. pizero-5): "
  read -r PI_HOST
  [[ -z "${PI_HOST}" ]] && die "No Pi host specified."
fi

info "Deploying to ${PI_USER}@${PI_HOST}:${PI_PATH}/morse-translator/${BINARY_NAME}"

scp "${BINARY}" "${PI_USER}@${PI_HOST}:${PI_PATH}/morse-translator/${BINARY_NAME}" \
  || die "SCP failed. Ensure SSH access to ${PI_USER}@${PI_HOST} is configured."
ok "Binary copied to Pi"

info "Running transition.sh --deploy on Pi…"
# shellcheck disable=SC2029
ssh "${PI_USER}@${PI_HOST}" "sudo bash ${PI_PATH}/transition.sh --deploy" \
  || warn "transition.sh exited with non-zero — check output above"

echo ""
banner "Done!"
echo -e "  ${YEL}NOTE:${RST} GPIO is disabled in cross-compiled builds."
echo -e "  The web UI and all other features work normally."
echo -e "  For GPIO support, build directly on a Pi 3/4/5 with more disk space."
echo ""
