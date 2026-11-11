<#
SiteWise (branch joel) - install/get, build the Jaspr web frontend,
start the unified FastAPI server, and run Flutter mobile.
Run from the FYP project root:
  powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\Start-SiteWise-All.ps1
Web only (no USB phone):
  powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\Start-SiteWise-All.ps1 -WebOnly
A repeat run resolves only missing backend Python packages, but regenerates
web auth assets and rebuilds the client bundle.
Never commit backend/.env or the Flutter JSON configuration with credentials.
#>
[CmdletBinding()]
param([switch]$WebOnly)
$ErrorActionPreference = 'Stop'
$root = Split-Path -Parent $MyInvocation.MyCommand.Path
$backendDir = Join-Path $root 'backend'
$mobileDir = Join-Path $root 'fyp_mobile_app'
$webDir = Join-Path $root 'fyp_jaspr_web'
$toolDir = Join-Path $webDir 'tool'
$py = Join-Path $backendDir '.venv\Scripts\python.exe'
$mobileJson = Join-Path $mobileDir 'assets\config\sitewise_dev.json'

function Step([string]$name) { Write-Host "`n==> $name" -ForegroundColor Cyan }
function MustSucceed([string]$step) {
    if ($LASTEXITCODE -ne 0) { throw "$step failed (exit $LASTEXITCODE). See output above." }
}
function Need([string]$file, [string]$help) {
    if (-not (Test-Path -LiteralPath $file)) { throw "Missing $file`n$help" }
}
function NeedCommand([string]$name) {
    if (-not (Get-Command $name -ErrorAction SilentlyContinue)) {
        throw "Required command not found: $name. Install it and restart PowerShell."
    }
}

Need (Join-Path $root 'run-sitewise.cmd') 'Place this script in the FYP repository root.'
Need (Join-Path $backendDir '.env') 'Create backend/.env from backend/.env.example, then configure the DB and Supabase server settings.'
NeedCommand flutter
NeedCommand dart
NeedCommand npm.cmd
NeedCommand node
NeedCommand python

if (-not $WebOnly) {
    Need $mobileJson 'Place your public SiteWise JSON in fyp_mobile_app/assets/config/sitewise_dev.json.'
    $mobileSettings = Get-Content -LiteralPath $mobileJson -Raw | ConvertFrom-Json
    if ([string]$mobileSettings.SITEWISE_DEV_AUTH_BYPASS -eq 'true') {
        throw 'SITEWISE_DEV_AUTH_BYPASS is true. Change it to false in the JSON to require Login / Sign Up.'
    }
    if ([string]$mobileSettings.API_HOST_MODE -ne 'adb-reverse' -or [string]$mobileSettings.API_BASE_URL -ne 'http://127.0.0.1:8090') {
        throw 'This script expects a USB Android device: use API_HOST_MODE=adb-reverse and API_BASE_URL=http://127.0.0.1:8090, or use -WebOnly.'
    }
}

Step 'Get Flutter/Dart workspace dependencies'
Push-Location $mobileDir
try {
    & flutter pub get
    MustSucceed 'flutter pub get'
} finally { Pop-Location }

Step 'Set up FastAPI Python environment'
if (-not (Test-Path -LiteralPath $py)) {
    & python -m venv (Join-Path $backendDir '.venv')
    MustSucceed 'python -m venv'
}
& $py -c 'import uvicorn, fastapi, sqlmodel, sqlalchemy, psycopg2, joblib'
if ($LASTEXITCODE -ne 0) {
    Write-Host 'Installing Python dependencies from backend/pyproject.toml' -ForegroundColor Yellow
    & $py -m pip install -e $backendDir
    MustSucceed 'backend Python dependency install'
}

Step 'Get web Node dependencies'
& npm.cmd install --prefix $toolDir
MustSucceed 'npm install web/tool'

Step 'Build public browser auth configuration and bundle'
& npm.cmd run gen-auth-config --prefix $toolDir
MustSucceed 'npm gen-auth-config'
& npm.cmd run build-auth --prefix $toolDir
MustSucceed 'npm build-auth'

# Optional licensed map tiles, when a public CARTO Basemaps key is configured.
$backendEnv = Get-Content -LiteralPath (Join-Path $backendDir '.env')
$hasMapKey = @($backendEnv | Where-Object { $_ -match '^\s*CARTO_BASEMAPS_KEY\s*=\s*cb1_' }).Count -gt 0
if ($hasMapKey) {
    & npm.cmd run gen-map-config --prefix $toolDir
    MustSucceed 'npm gen-map-config'
} else {
    Write-Warning 'CARTO_BASEMAPS_KEY not detected; maps that need that tile provider may be unavailable.'
}

Step 'Build Jaspr web application (client mode)'
Push-Location $webDir
try {
    & dart run jaspr_cli:jaspr build
    MustSucceed 'jaspr build'
} finally { Pop-Location }
Need (Join-Path $webDir 'build\jaspr\index.html') 'Jaspr did not produce build/jaspr/index.html.'

Step 'Start unified FastAPI on 127.0.0.1:8090 in a separate terminal'
$launcher = Join-Path $root 'run-sitewise.cmd'
$mode = if ($WebOnly) { '' } else { ' -Mobile' }
$serverCmd = 'call "' + $launcher + '"' + $mode
Start-Process -FilePath 'cmd.exe' -ArgumentList @('/k', $serverCmd) -WorkingDirectory $root | Out-Null

Write-Host 'Waiting for the backend health endpoint to become reachable...' -ForegroundColor DarkGray
$ready = $false
for ($i = 0; $i -lt 40; $i++) {
    Start-Sleep -Seconds 1
    try {
        $resp = Invoke-WebRequest -Uri 'http://127.0.0.1:8090/health' -UseBasicParsing -TimeoutSec 2 -ErrorAction Stop
        if ($resp.StatusCode -ge 200 -and $resp.StatusCode -lt 300) { $ready = $true; break }
    } catch { }
}
if (-not $ready) {
    throw 'FastAPI health check did not succeed. Inspect the NEW server terminal for the actual Python/DB/port error.'
}
Write-Host 'Web ready: http://localhost:8090' -ForegroundColor Green
Start-Process 'http://localhost:8090' | Out-Null

if ($WebOnly) {
    Write-Host 'Web-only mode complete. Keep the FastAPI terminal open.' -ForegroundColor Green
    exit 0
}

Step 'Verify ADB reverse rule installed by the -Mobile launcher'
$adbExe = (Get-Command adb -ErrorAction SilentlyContinue).Source
if (-not $adbExe) {
    $adbExe = Join-Path $env:LOCALAPPDATA 'Android\Sdk\platform-tools\adb.exe'
}
Need $adbExe 'Install Android SDK platform-tools and authorize USB debugging on the phone.'
$reverseList = @(& $adbExe reverse --list 2>&1) -join "`n"
if ($reverseList -notmatch 'tcp:8090\s+tcp:8090') {
    throw 'ADB reverse rule missing. Check the server terminal and run adb reverse tcp:8090 tcp:8090.'
}

Step 'Run Flutter on the attached Android device (no dart-define arguments)'
Push-Location $mobileDir
try {
    & flutter run
    MustSucceed 'flutter run'
} finally { Pop-Location }
