<#
SiteWise (branch joel) - FVM + Python venv + web build + unified FastAPI
and Android mobile startup. Uses the Flutter version pinned in .fvmrc.
Run from the FYP project root:
  powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\Start-SiteWise-All-FVM.ps1
Web only (no USB phone; still uses FVM):
  powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\Start-SiteWise-All-FVM.ps1 -WebOnly
FVM selects the SDK pinned by .fvmrc (currently Flutter 3.44.6).
Python packages are installed into backend/.venv when created or when the
backend/pyproject.toml dependency manifest changes.
Web auth assets and Jaspr client bundle are rebuilt on each run.
Never commit backend/.env or the Flutter JSON configuration with credentials.
#>
[CmdletBinding()]
param([switch]$WebOnly)
$ErrorActionPreference = 'Stop'
$env:NO_PROXY = 'localhost,127.0.0.1,::1'
$env:no_proxy = $env:NO_PROXY
$root = Split-Path -Parent $MyInvocation.MyCommand.Path
$backendDir = Join-Path $root 'backend'
$mobileDir = Join-Path $root 'fyp_mobile_app'
$webDir = Join-Path $root 'fyp_jaspr_web'
$toolDir = Join-Path $webDir 'tool'
$venvDir = Join-Path $backendDir '.venv'
$py = Join-Path $venvDir 'Scripts\python.exe'
$fvmRc = Join-Path $root '.fvmrc'
$pyproject = Join-Path $backendDir 'pyproject.toml'
$dependencyMarker = Join-Path $venvDir '.sitewise-pyproject.sha256'
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
Need $fvmRc 'This project needs its root .fvmrc (the Flutter SDK version pin).'
Need $pyproject 'The FastAPI dependencies are declared in backend/pyproject.toml.'
NeedCommand npm.cmd
NeedCommand node
NeedCommand python

# Resolve FVM. Existing installations are used as-is. When missing, the
# Dart package installer is a one-time bootstrap (Dart must then be on PATH).
$pubCache = if (-not [string]::IsNullOrWhiteSpace($env:PUB_CACHE)) {
    $env:PUB_CACHE
} else { Join-Path $env:LOCALAPPDATA 'Pub\Cache' }
$pubBin = Join-Path $pubCache 'bin'
# Include even when it does not exist yet: dart pub global activate fvm
# creates it during this same run.
$env:PATH = "$pubBin;$env:PATH"
if (-not (Get-Command fvm -ErrorAction SilentlyContinue)) {
    Step 'Install Flutter Version Manager (FVM)'
    NeedCommand dart
    & dart pub global activate fvm
    MustSucceed 'dart pub global activate fvm'
}
NeedCommand fvm
$fvmVersion = [string]((Get-Content -LiteralPath $fvmRc -Raw | ConvertFrom-Json).flutter)
if ([string]::IsNullOrWhiteSpace($fvmVersion)) {
    throw "No Flutter version found in $fvmRc"
}
Step "Select Flutter $fvmVersion with FVM"
Push-Location $root
try {
    & fvm install $fvmVersion
    MustSucceed "fvm install $fvmVersion"
    & fvm use $fvmVersion
    MustSucceed "fvm use $fvmVersion"
    & fvm flutter --version
    MustSucceed 'fvm flutter --version'
} finally { Pop-Location }

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

Step 'Get Flutter/Dart workspace dependencies using FVM'
Push-Location $mobileDir
try {
    & fvm flutter pub get
    MustSucceed 'fvm flutter pub get'
} finally { Pop-Location }

Step 'Set up FastAPI Python virtual environment (backend/.venv)'
$newVenv = -not (Test-Path -LiteralPath $py)
if ($newVenv) {
    & python -m venv $venvDir
    MustSucceed 'python -m venv backend/.venv'
}
Need $py 'Failed to create the backend Python virtual environment.'
& $py --version
MustSucceed 'backend venv Python version'

# A virtualenv does not need Activate.ps1 to run isolated dependencies:
# invoking its Scripts/python.exe is equivalent and avoids PowerShell policy
# and PATH issues. The existing run-sitewise.ps1 uses this exact Python too.
$manifestHash = (Get-FileHash -LiteralPath $pyproject -Algorithm SHA256).Hash
$existingHash = if (Test-Path -LiteralPath $dependencyMarker) {
    (Get-Content -LiteralPath $dependencyMarker -Raw).Trim()
} else { '' }
$installNeeded = $newVenv -or ($existingHash -ne $manifestHash)
if (-not $installNeeded) {
    & $py -c 'import uvicorn, fastapi, sqlmodel, sqlalchemy, psycopg2, joblib'
    $installNeeded = $LASTEXITCODE -ne 0
}
if ($installNeeded) {
    Write-Host 'Installing/updating backend dependencies inside .venv...' -ForegroundColor Yellow
    & $py -m pip install -e $backendDir
    MustSucceed 'pip install -e backend'
    [System.IO.File]::WriteAllText($dependencyMarker, $manifestHash)
} else {
    Write-Host 'Python .venv ready; dependency manifest unchanged.' -ForegroundColor Green
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
    & fvm dart run jaspr_cli:jaspr build
    MustSucceed 'fvm dart run jaspr_cli:jaspr build'
} finally { Pop-Location }
Need (Join-Path $webDir 'build\jaspr\index.html') 'Jaspr did not produce build/jaspr/index.html.'

Step 'Start unified FastAPI on 127.0.0.1:8090 in a separate terminal'
# Avoid a misleading successful health check from a previously-running server
# if the new launcher fails because port 8090 is occupied.
$blocking = @(Get-NetTCPConnection -LocalPort 8090 -ErrorAction SilentlyContinue |
    Where-Object { $_.State -in 'Listen', 'Bound' })
if ($blocking.Count -gt 0) {
    $pidOnPort = $blocking[0].OwningProcess
    throw "Port 8090 is already in use (PID $pidOnPort). Stop the old SiteWise/Jaspr process before starting this script."
}
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

Step 'Run Flutter through FVM on USB Android (no dart-define arguments)'
Push-Location $mobileDir
try {
    & fvm flutter run
    MustSucceed 'fvm flutter run'
} finally { Pop-Location }
