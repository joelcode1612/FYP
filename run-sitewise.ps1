<#
.SYNOPSIS
    Starts Unified SiteWise: one FastAPI application server on port 8090.

.DESCRIPTION
    FastAPI is the ONLY application server. It serves the compiled Jaspr
    frontend (fyp_jaspr_web/build/jaspr, produced by `jaspr build` in client
    mode) together with the REST API (/api/v1/*, /health, /docs):

        Browser / Flutter Mobile
                |
                v
        Unified FastAPI :8090
                |
                +-- compiled Jaspr frontend + SPA fallback
                +-- /api/v1/*  /health  /docs
                +-- Supabase authentication, PostgreSQL / PostGIS

    No Jaspr SSR process, no second FastAPI instance, no Express/Node server.

    Frontend compilation is a separate build step:
        cd fyp_jaspr_web
        jaspr build          (or: dart run jaspr_cli:jaspr build)

    ### Why a phone cannot reach the default launcher

    Uvicorn binds 127.0.0.1 by default. That loopback address exists only on
    this PC: an Android device has its OWN 127.0.0.1, and the PC's LAN IP is
    not reachable when the phone is on a different subnet (USB tethering,
    guest Wi-Fi, etc.). A successful `curl http://127.0.0.1:8090/health` on
    Windows therefore proves nothing about the device.

    This launcher installs `adb reverse tcp:<Port> tcp:<Port>` whenever an
    authorized device/emulator is attached. The device then talks to
    http://127.0.0.1:<Port> and adb forwards it to this PC, with no LAN IP,
    no 0.0.0.0 bind and no firewall change. `-AllowLan` remains available for
    devices that must use a real LAN address.

    ### Starting this script does NOT rebuild the Flutter app

    SUPABASE_URL / SUPABASE_PUBLISHABLE_KEY / API_BASE_URL are Dart
    compile-time defines baked into the APK at `flutter run`. A server process
    cannot inject them into an already-built binary. Re-run the app from
    Android Studio (or `flutter run`) with
    `--dart-define-from-file=fyp_mobile_app/config/dev.env` after changing
    that file or the selected host mode.

.EXAMPLE
    .\run-sitewise.ps1
.EXAMPLE
    .\run-sitewise.ps1 -Mobile
.EXAMPLE
    .\run-sitewise.ps1 -AllowLan
.EXAMPLE
    .\run-sitewise.ps1 -Port 8091
.EXAMPLE
    .\run-sitewise.ps1 -BindHost 0.0.0.0
#>
[CmdletBinding()]
param(
    [ValidateRange(1, 65535)] [int]$Port = 8090,
    [string]$BindHost = '127.0.0.1',
    # Require a working adb reverse rule (fails loudly instead of silently
    # leaving a physical device unable to reach /api/v1/auth/me).
    [switch]$Mobile,
    # Bind all interfaces so a device on the same LAN can reach the API.
    [switch]$AllowLan
)

$ErrorActionPreference = 'Stop'
$root = Split-Path -Parent $MyInvocation.MyCommand.Path
$backendDir = Join-Path $root 'backend'
$distDir = Join-Path $root 'fyp_jaspr_web\build\jaspr'
$pythonExe = Join-Path $backendDir '.venv\Scripts\python.exe'

Write-Host 'Unified SiteWise launcher' -ForegroundColor Cyan

if ($AllowLan -and $BindHost -eq '127.0.0.1') {
    $BindHost = '0.0.0.0'
}

if (-not (Test-Path -LiteralPath $pythonExe)) {
    Write-Host "ERROR: missing backend virtual environment: $pythonExe" -ForegroundColor Red
    Write-Host '       create it first (python -m venv backend/.venv + pip install -r backend/requirements.txt).'
    exit 1
}

if (-not (Test-Path -LiteralPath (Join-Path $distDir 'index.html'))) {
    Write-Host "ERROR: compiled frontend not found: $distDir\index.html" -ForegroundColor Red
    Write-Host '       build the frontend first, then run this launcher again:'
    Write-Host '         cd fyp_jaspr_web'
    Write-Host '         jaspr build'
    exit 1
}

# Check ALL TCP states, not just Listen: a stale Dart build daemon holds the
# port in Bound state (netstat shows nothing), which makes uvicorn fail with
# WSAEACCES 10013 — the same trap serve.impl.ps1 documents for the SSR server.
# Only Listen/Bound actually prevent a new bind; kernel-owned transient states
# (TimeWait, CloseWait, ...) from already-closed connections must not block.
$blocking = Get-NetTCPConnection -LocalPort $Port -ErrorAction SilentlyContinue |
    Where-Object { $_.State -in 'Listen', 'Bound' }
if ($blocking) {
    $holder = $blocking | Select-Object -First 1
    $holderName = try {
        (Get-Process -Id $holder.OwningProcess -ErrorAction Stop).ProcessName
    } catch { "PID $($holder.OwningProcess)" }
    Write-Host "ERROR: port $Port is held in state $($holder.State) by $holderName (PID $($holder.OwningProcess))." -ForegroundColor Red
    Write-Host '       stop that process (e.g. Stop-Process -Id <pid>), or run with -Port <other>.'
    exit 1
}

# --- Device reachability ----------------------------------------------------
# adb lives in the Android SDK platform-tools; it is not always on PATH when
# the launcher is started from a plain cmd.exe window.
$adbExe = $null
$adbCommand = Get-Command adb -ErrorAction SilentlyContinue
if ($adbCommand) { $adbExe = $adbCommand.Source }
if (-not $adbExe) {
    $sdkCandidate = Join-Path $env:LOCALAPPDATA 'Android\Sdk\platform-tools\adb.exe'
    if (Test-Path -LiteralPath $sdkCandidate) { $adbExe = $sdkCandidate }
}

$reverseInstalled = $false
if ($adbExe) {
    $deviceLines = @(& $adbExe devices 2>$null)
    $ready = @($deviceLines | Where-Object { $_ -match '^\S+\s+device\s*$' })
    if ($ready.Count -gt 0) {
        $portArg = "tcp:$Port"
        & $adbExe reverse $portArg $portArg 2>&1 |
            ForEach-Object { Write-Host "  adb:      $_" -ForegroundColor DarkGray }
        if ($LASTEXITCODE -eq 0) {
            $reverseInstalled = $true
            Write-Host "  Mobile:   http://127.0.0.1:$Port on the device -> this PC (adb reverse)" -ForegroundColor Green
        } else {
            Write-Host "  WARNING: adb reverse $portArg failed; the device cannot reach the API." -ForegroundColor Yellow
            if ($Mobile) { exit 1 }
        }
    } elseif ($Mobile) {
        Write-Host 'ERROR: -Mobile was requested but no authorized device is attached.' -ForegroundColor Red
        Write-Host '       connect the phone over USB, accept the RSA prompt, then retry.'
        exit 1
    } else {
        Write-Host '  Mobile:   no device attached; adb reverse skipped.' -ForegroundColor DarkGray
    }
} elseif ($Mobile) {
    Write-Host 'ERROR: -Mobile needs adb (Android SDK platform-tools) on PATH.' -ForegroundColor Red
    Write-Host "       expected: $env:LOCALAPPDATA\Android\Sdk\platform-tools\adb.exe"
    exit 1
}

# The API resolves backend/.env relative to the working directory; keep it at
# backend/. Local HTTP stays out of any configured proxy.
$env:PYTHONPATH = Join-Path $backendDir 'src'
$env:PYTHONUTF8 = '1'
$env:NO_PROXY = 'localhost,127.0.0.1,::1'
$env:no_proxy = $env:NO_PROXY

Write-Host "  App:      http://localhost:$Port" -ForegroundColor Green
Write-Host "  Bind:     $BindHost" -ForegroundColor Green
Write-Host '  API docs: /docs   Health: /health' -ForegroundColor Green

if ($reverseInstalled) {
    $mobileOrigin = 'http://127.0.0.1:{0}' -f $Port
    Write-Host "  Flutter:  API_HOST_MODE=adb-reverse -> $mobileOrigin (device side)" -ForegroundColor Cyan
}
if ($BindHost -eq '0.0.0.0') {
    $lanIps = @(Get-NetIPAddress -AddressFamily IPv4 -ErrorAction SilentlyContinue |
        Where-Object { $_.IPAddress -ne '127.0.0.1' } |
        Select-Object -ExpandProperty IPAddress)
    foreach ($ip in $lanIps) {
        $origin = 'http://{0}:{1}' -f $ip, $Port
        Write-Host "  Flutter:  API_BASE_URL=$origin (device on the same subnet)" -ForegroundColor Cyan
    }
    Write-Host '  NOTE: Windows Firewall must allow inbound Python on this port.' -ForegroundColor Yellow
}
Write-Host '  NOTE: this does NOT rebuild Flutter. Re-run the app with its Dart defines if they changed.' -ForegroundColor Yellow
Write-Host '  Press Ctrl+C to stop.' -ForegroundColor DarkGray
Write-Host ''

Push-Location $backendDir
try {
    & $pythonExe -m uvicorn sitewise.main:app --host $BindHost --port $Port
    exit $LASTEXITCODE
} finally {
    Pop-Location
    # The rule is only useful while this server is up; remove it so a later
    # device session does not forward into a closed port.
    if ($reverseInstalled -and $adbExe) {
        & $adbExe reverse --remove "tcp:$Port" 2>&1 | Out-Null
    }
}
