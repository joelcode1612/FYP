
<#
SiteWise — Unified Development Launcher

Starts:
  1. FVM Flutter/Dart workspace dependency resolution
  2. FastAPI Python dependency setup
  3. Web authentication asset generation
  4. Jaspr web build
  5. Unified FastAPI server
  6. Android ADB reverse connection (mobile mode)
  7. Flutter mobile application (mobile mode)

Requirements:
  - FVM configured for the repository
  - Node.js and npm
  - Python
  - Backend .env configuration
  - Android device with USB debugging for mobile mode

Usage:

  Full application:
    powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\Start-SiteWise-All.ps1

  Web only:
    powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\Start-SiteWise-All.ps1 -WebOnly

  Select a particular Android device:
    powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\Start-SiteWise-All.ps1 -DeviceId YOUR_DEVICE_ID

Security:
  Never commit backend/.env or credential-containing configuration.
#>

[CmdletBinding()]
param(
    [switch]$WebOnly,
    [string]$DeviceId
)

$ErrorActionPreference = 'Stop'

# ============================================================
# 1. PROJECT PATHS
# ============================================================

$root = Split-Path -Parent $MyInvocation.MyCommand.Path

$backendDir = Join-Path $root 'backend'
$mobileDir = Join-Path $root 'fyp_mobile_app'
$webDir = Join-Path $root 'fyp_jaspr_web'
$toolDir = Join-Path $webDir 'tool'

$py = Join-Path $backendDir '.venv\Scripts\python.exe'

$mobileJson = Join-Path `
    $mobileDir `
    'assets\config\sitewise_dev.json'

$launcher = Join-Path $root 'run-sitewise.cmd'

Set-Location $root

# ============================================================
# 2. UTILITY FUNCTIONS
# ============================================================

function Step([string]$name) {
    Write-Host "`n==> $name" -ForegroundColor Cyan
}

function MustSucceed([string]$step) {
    if ($LASTEXITCODE -ne 0) {
        throw "$step failed (exit $LASTEXITCODE). See output above."
    }
}

function Need(
    [string]$file,
    [string]$help
) {
    if (-not (Test-Path -LiteralPath $file)) {
        throw "Missing $file`n$help"
    }
}

function NeedCommand([string]$name) {
    if (-not (Get-Command $name -ErrorAction SilentlyContinue)) {
        throw "Required command not found: $name"
    }
}

# ============================================================
# 3. CHECK REQUIRED FILES AND TOOLS
# ============================================================

Step 'Verify required files and tools'

Need $launcher `
    'Place this launcher in the FYP repository root.'

Need (Join-Path $backendDir '.env') `
    'Create backend/.env from backend/.env.example.'

NeedCommand fvm
NeedCommand npm.cmd
NeedCommand node
NeedCommand python

# ============================================================
# 4. VERIFY FVM SDK
# ============================================================

Step 'Verify project FVM Flutter/Dart toolchain'

& fvm flutter --version
MustSucceed 'FVM Flutter version check'

$dartVersionOutput = (
    & fvm dart --version 2>&1 | Out-String
).Trim()

MustSucceed 'FVM Dart version check'

Write-Host $dartVersionOutput

if ($dartVersionOutput -notmatch 'Dart SDK version:\s*(\d+\.\d+\.\d+)') {
    throw "Unable to determine FVM Dart SDK version: $dartVersionOutput"
}

$dartVersion = [version]$Matches[1]

if (
    $dartVersion -lt [version]'3.7.0' -or
    $dartVersion -ge [version]'3.13.0'
) {
    throw @"
Incompatible FVM Dart version: $dartVersion

The current build_web_compilers 4.6.0 dependency
requires Dart >=3.7.0 and <3.13.0.

Use the team's approved FVM Flutter version.
Do not resolve this by calling the global flutter executable.
"@
}

Write-Host "FVM Dart version accepted: $dartVersion" `
    -ForegroundColor Green

# ============================================================
# 5. MOBILE CONFIGURATION VALIDATION
# ============================================================

if (-not $WebOnly) {

    Step 'Validate mobile configuration'

    Need $mobileJson `
        'Missing fyp_mobile_app/assets/config/sitewise_dev.json.'

    $mobileSettings = Get-Content `
        -LiteralPath $mobileJson `
        -Raw |
        ConvertFrom-Json

    if (
        [string]$mobileSettings.SITEWISE_DEV_AUTH_BYPASS -eq 'true'
    ) {
        throw @"
SITEWISE_DEV_AUTH_BYPASS is true.

Set it to false so that Login / Sign Up
authentication remains required.
"@
    }

    if (
        [string]$mobileSettings.API_HOST_MODE -ne 'adb-reverse' -or
        [string]$mobileSettings.API_BASE_URL -ne 'http://127.0.0.1:8090'
    ) {
        throw @"
Mobile API configuration mismatch.

Expected:
  API_HOST_MODE = adb-reverse
  API_BASE_URL  = http://127.0.0.1:8090

Correct the configuration or use -WebOnly.
"@
    }
}

# ============================================================
# 6. DETECT AND VALIDATE ANDROID DEVICE
# ============================================================

$adbExe = $null

if (-not $WebOnly) {

    Step 'Detect Android Debug Bridge'

    $adbCommand = Get-Command adb.exe -ErrorAction SilentlyContinue

    if ($adbCommand) {
        $adbExe = $adbCommand.Source
    }
    else {
        $adbExe = Join-Path `
            $env:LOCALAPPDATA `
            'Android\Sdk\platform-tools\adb.exe'
    }

    Need $adbExe `
        'Install Android SDK platform-tools and enable USB debugging.'

    Write-Host "Using ADB: $adbExe"

    Step 'Check connected Android devices'

    $deviceOutput = @(
        & $adbExe devices -l 2>&1
    )

    MustSucceed 'ADB device discovery'

    $deviceOutput | ForEach-Object {
        Write-Host $_
    }

    $connectedDevices = @(
        foreach ($line in $deviceOutput) {
            if (
                [string]$line -match '^\s*(\S+)\s+device(?:\s|$)'
            ) {
                $Matches[1]
            }
        }
    )

    if ($connectedDevices.Count -eq 0) {
        throw @"
No authorized Android device detected.

Check:
  1. Android phone or emulator is connected.
  2. USB debugging is enabled.
  3. The device has authorized this computer.
  4. adb devices -l shows status 'device'.

ADB reported:
$($deviceOutput -join "`n")
"@
    }

    if ([string]::IsNullOrWhiteSpace($DeviceId)) {

        if ($connectedDevices.Count -gt 1) {
            throw @"
Multiple Android devices were detected:

$($connectedDevices -join "`n")

Specify the device to use:

.\Start-SiteWise-All.ps1 -DeviceId YOUR_DEVICE_ID
"@
        }

        $DeviceId = $connectedDevices[0]
    }
    elseif ($connectedDevices -notcontains $DeviceId) {
        throw @"
Requested Android device '$DeviceId' is not available
or not authorized.

Available devices:
$($connectedDevices -join "`n")
"@
    }

    Write-Host "Selected Android device: $DeviceId" `
        -ForegroundColor Green
}

# ============================================================
# 7. GET FLUTTER WORKSPACE DEPENDENCIES
# ============================================================

Step 'Get Flutter/Dart workspace dependencies using FVM'

Push-Location $mobileDir

try {
    & fvm flutter pub get
    MustSucceed 'FVM Flutter pub get'
}
finally {
    Pop-Location
}

# ============================================================
# 8. PREPARE FASTAPI PYTHON ENVIRONMENT
# ============================================================

Step 'Set up FastAPI Python environment'

if (-not (Test-Path -LiteralPath $py)) {

    & python -m venv (Join-Path $backendDir '.venv')

    MustSucceed 'Python virtual environment creation'
}

& $py -c 'import uvicorn, fastapi, sqlmodel, sqlalchemy, psycopg2, joblib'

if ($LASTEXITCODE -ne 0) {

    Write-Host `
        'Installing backend Python dependencies...' `
        -ForegroundColor Yellow

    & $py -m pip install -e $backendDir

    MustSucceed 'Backend Python dependency installation'
}

# ============================================================
# 9. INSTALL WEB NODE DEPENDENCIES
# ============================================================

Step 'Get web Node dependencies'

& npm.cmd install --prefix $toolDir

MustSucceed 'npm install web/tool'

# ============================================================
# 10. GENERATE WEB AUTHENTICATION ASSETS
# ============================================================

Step 'Build public browser authentication configuration'

& npm.cmd run gen-auth-config --prefix $toolDir
MustSucceed 'npm gen-auth-config'

& npm.cmd run build-auth --prefix $toolDir
MustSucceed 'npm build-auth'

# ============================================================
# 11. OPTIONAL MAP CONFIGURATION
# ============================================================

Step 'Check optional map configuration'

$backendEnv = Get-Content `
    -LiteralPath (Join-Path $backendDir '.env')

$hasMapKey = @(
    $backendEnv | Where-Object {
        $_ -match '^\s*CARTO_BASEMAPS_KEY\s*=\s*cb1_'
    }
).Count -gt 0

if ($hasMapKey) {

    & npm.cmd run gen-map-config --prefix $toolDir

    MustSucceed 'npm gen-map-config'
}
else {

    Write-Warning `
        'CARTO_BASEMAPS_KEY not detected; some map tiles may be unavailable.'
}

# ============================================================
# 12. BUILD JASPR WEB WITH FVM DART
# ============================================================

Step 'Build Jaspr web application using FVM Dart'

Push-Location $webDir

try {

    & fvm dart run jaspr_cli:jaspr build

    MustSucceed 'Jaspr web build'
}
finally {
    Pop-Location
}

Need `
    (Join-Path $webDir 'build\jaspr\index.html') `
    'Jaspr did not produce build/jaspr/index.html.'

Write-Host 'Jaspr web build completed.' `
    -ForegroundColor Green

# ============================================================
# 13. START FASTAPI SERVER
# ============================================================

Step 'Start unified FastAPI server on 127.0.0.1:8090'

$mode = if ($WebOnly) {
    ''
}
else {
    ' -Mobile'
}

$serverCmd = 'call "' + $launcher + '"' + $mode

Start-Process `
    -FilePath 'cmd.exe' `
    -ArgumentList @('/k', $serverCmd) `
    -WorkingDirectory $root |
    Out-Null

# ============================================================
# 14. VERIFY BACKEND HEALTH
# ============================================================

Step 'Verify backend health endpoint'

$ready = $false

for ($i = 0; $i -lt 40; $i++) {

    Start-Sleep -Seconds 1

    try {

        $resp = Invoke-WebRequest `
            -Uri 'http://127.0.0.1:8090/health' `
            -UseBasicParsing `
            -TimeoutSec 2 `
            -ErrorAction Stop

        if (
            $resp.StatusCode -ge 200 -and
            $resp.StatusCode -lt 300
        ) {
            $ready = $true
            break
        }
    }
    catch {
        # Continue probing until the health-check limit.
    }
}

if (-not $ready) {
    throw @"
FastAPI health check did not succeed.

Inspect the newly opened server terminal.

Possible causes:
  - Backend startup exception
  - PostgreSQL connection failure
  - Missing backend environment settings
  - Port 8090 already occupied
"@
}

Write-Host `
    'FastAPI health check passed.' `
    -ForegroundColor Green

Write-Host `
    'Web ready: http://localhost:8090' `
    -ForegroundColor Green

Start-Process 'http://localhost:8090' |
    Out-Null

# ============================================================
# 15. WEB-ONLY MODE
# ============================================================

if ($WebOnly) {

    Write-Host `
        'Web-only startup complete.' `
        -ForegroundColor Green

    Write-Host `
        'Keep the FastAPI terminal open.'

    exit 0
}

# ============================================================
# 16. CONFIGURE ADB REVERSE AUTOMATICALLY
# ============================================================

Step 'Configure ADB reverse for the selected Android device'

Write-Host "Device: $DeviceId"
Write-Host 'Mapping device tcp:8090 to host tcp:8090'

# Establish the reverse mapping explicitly.
# Do not assume run-sitewise.cmd has already created it.

$reverseOutput = @(
    & $adbExe -s $DeviceId reverse tcp:8090 tcp:8090 2>&1
)

if ($LASTEXITCODE -ne 0) {
    throw @"
ADB reverse configuration failed.

Device: $DeviceId

ADB output:
$($reverseOutput -join "`n")

Ensure that USB debugging is authorized and
the device remains connected.
"@
}

# Confirm the reverse rule is really installed.

$reverseListOutput = @(
    & $adbExe -s $DeviceId reverse --list 2>&1
)

MustSucceed 'ADB reverse rule verification'

$reverseList = $reverseListOutput -join "`n"

Write-Host $reverseList

if ($reverseList -notmatch 'tcp:8090\s+tcp:8090') {
    throw @"
ADB reverse command completed, but the required
tcp:8090 -> tcp:8090 rule was not confirmed.

Device: $DeviceId

ADB reverse list:
$reverseList
"@
}

Write-Host `
    'ADB reverse connection verified successfully.' `
    -ForegroundColor Green

# ============================================================
# 17. RUN FLUTTER MOBILE USING FVM
# ============================================================

Step 'Run Flutter mobile application using FVM'

Push-Location $mobileDir

try {

    Write-Host "Launching application on device: $DeviceId"

    & fvm flutter run -d $DeviceId

    MustSucceed 'Flutter mobile run'
}
finally {
    Pop-Location
}

# ============================================================
# END
# ============================================================
