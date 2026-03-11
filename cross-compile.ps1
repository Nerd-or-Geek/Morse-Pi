# =============================================================================
#  Morse-Pi — Cross-compile Zig backend and deploy to Raspberry Pi
#
#  Usage:
#    .\cross-compile.ps1                       # Interactive (asks for Pi address)
#    .\cross-compile.ps1 -PiHost pizero-5      # Direct deploy to named Pi
#    .\cross-compile.ps1 -PiHost 192.168.1.42  # Direct deploy to IP
#    .\cross-compile.ps1 -BuildOnly            # Just build, don't deploy
#
#  Requirements:
#    - Zig 0.13.0+ installed and on PATH  (winget install zig.zig)
#    - SSH access to the Pi (key-based recommended)
# =============================================================================
param(
    [string]$PiHost = "",
    [string]$PiUser = "pi",
    [string]$PiPath = "/opt/morse-pi",
    [string]$Target = "arm-linux-musleabihf",
    [string]$Cpu    = "arm1176jzf_s",
    [switch]$BuildOnly,
    [switch]$PiZero,
    [switch]$Pi3,
    [switch]$Pi4,
    [switch]$Pi5
)

$ErrorActionPreference = "Stop"

# ── Colours ──────────────────────────────────────────────────────────────────
function Write-Info  { Write-Host "[INFO]  $args" -ForegroundColor Cyan }
function Write-Ok    { Write-Host "[  OK]  $args" -ForegroundColor Green }
function Write-Warn  { Write-Host "[WARN]  $args" -ForegroundColor Yellow }
function Write-Fail  { Write-Host "[FAIL]  $args" -ForegroundColor Red; exit 1 }
function Write-Banner { Write-Host "`n===  $args  ===`n" -ForegroundColor Cyan }

# ── Detect target from switches ──────────────────────────────────────────────
if ($PiZero) {
    $Target = "arm-linux-musleabihf"
    $Cpu    = "arm1176jzf_s"
} elseif ($Pi3) {
    $Target = "aarch64-linux-musl"
    $Cpu    = "cortex_a53"
} elseif ($Pi4) {
    $Target = "aarch64-linux-musl"
    $Cpu    = "cortex_a72"
} elseif ($Pi5) {
    $Target = "aarch64-linux-musl"
    $Cpu    = "cortex_a76"
}

$BinaryName = "morse-pi"
$ZigSrcDir  = Join-Path $PSScriptRoot "morse-translator-zig"

# ── Verify Zig directory structure ───────────────────────────────────────────
Write-Banner "Morse-Pi Cross-Compiler"
Write-Host "  Target : $Target"
Write-Host "  CPU    : $Cpu"
Write-Host "  Source : $ZigSrcDir"
Write-Host ""

if (-not (Test-Path $ZigSrcDir)) {
    Write-Fail "Zig source directory not found: $ZigSrcDir"
}

if (-not (Test-Path (Join-Path $ZigSrcDir "build.zig"))) {
    Write-Fail "build.zig not found in $ZigSrcDir"
}

# ── Check Zig is installed ───────────────────────────────────────────────────
Write-Banner "Step 1 / 3 — Check Zig"

$zigCmd = Get-Command zig -ErrorAction SilentlyContinue
if (-not $zigCmd) {
    Write-Fail "Zig not found on PATH. Install it:
    winget install zig.zig
  or download from https://ziglang.org/download/"
}

$zigVersion = & zig version 2>&1
Write-Ok "Zig $zigVersion found at $($zigCmd.Source)"

# ── Cross-compile ────────────────────────────────────────────────────────────
Write-Banner "Step 2 / 3 — Cross-Compile for ARM"

Push-Location $ZigSrcDir

$buildArgs = @(
    "build",
    "-Dtarget=$Target",
    "-Dcpu=$Cpu",
    "-Dgpio=false",
    "-Doptimize=ReleaseSafe"
)

Write-Info "Running: zig $($buildArgs -join ' ')"

try {
    & zig @buildArgs 2>&1 | ForEach-Object { Write-Host $_ }
    if ($LASTEXITCODE -ne 0) {
        Write-Fail "Zig build failed with exit code $LASTEXITCODE"
    }
} catch {
    Write-Fail "Zig build failed: $_"
}

$binaryPath = Join-Path $ZigSrcDir "zig-out\bin\$BinaryName"
if (-not (Test-Path $binaryPath)) {
    Write-Fail "Binary not found at $binaryPath"
}

$size = (Get-Item $binaryPath).Length
$sizeMB = [math]::Round($size / 1MB, 2)
Write-Ok "Binary built: $binaryPath ($sizeMB MB)"

Pop-Location

# ── Deploy to Pi ─────────────────────────────────────────────────────────────
if ($BuildOnly) {
    Write-Banner "Build Complete (deploy skipped)"
    Write-Host "  Binary: $binaryPath"
    Write-Host ""
    Write-Host "  To deploy manually:"
    Write-Host "    scp `"$binaryPath`" ${PiUser}@<pi-host>:${PiPath}/morse-translator/$BinaryName"
    Write-Host "    ssh ${PiUser}@<pi-host> 'sudo bash ${PiPath}/transition.sh --deploy'"
    exit 0
}

Write-Banner "Step 3 / 3 — Deploy to Pi"

if ([string]::IsNullOrEmpty($PiHost)) {
    $PiHost = Read-Host "Enter Pi hostname or IP (e.g. pizero-5, 192.168.1.42)"
    if ([string]::IsNullOrEmpty($PiHost)) {
        Write-Fail "No Pi host specified."
    }
}

Write-Info "Deploying to ${PiUser}@${PiHost}:${PiPath}/morse-translator/$BinaryName"

# Copy binary via SCP
try {
    & scp "$binaryPath" "${PiUser}@${PiHost}:${PiPath}/morse-translator/$BinaryName" 2>&1
    if ($LASTEXITCODE -ne 0) {
        Write-Fail "SCP failed. Ensure SSH access to ${PiUser}@${PiHost} is configured."
    }
    Write-Ok "Binary copied to Pi"
} catch {
    Write-Fail "SCP failed: $_"
}

# Run transition script in deploy mode
Write-Info "Running transition.sh --deploy on Pi…"
try {
    & ssh "${PiUser}@${PiHost}" "sudo bash ${PiPath}/transition.sh --deploy" 2>&1 | ForEach-Object { Write-Host $_ }
    if ($LASTEXITCODE -ne 0) {
        Write-Warn "transition.sh exited with code $LASTEXITCODE — check output above"
    } else {
        Write-Ok "Deployment complete!"
    }
} catch {
    Write-Warn "SSH command failed: $_"
    Write-Host ""
    Write-Host "  You can finish manually on the Pi:"
    Write-Host "    ssh ${PiUser}@${PiHost}"
    Write-Host "    sudo bash ${PiPath}/transition.sh --deploy"
}

Write-Host ""
Write-Banner "Done!"
Write-Host "  NOTE: GPIO is disabled in cross-compiled builds."
Write-Host "  The web UI and all other features work normally."
Write-Host "  For GPIO support, build directly on a Pi 3/4/5 with more disk space."
Write-Host ""
