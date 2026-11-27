
<#
SiteWise — Unified Development Launcher

Starts:
  1. FVM Flutter/Dart workspace dependency resolution
  2. FastAPI Python dependency setup
  3. Web authentication asset generation
  4. Unified FastAPI server on the selected port (run-sitewise.ps1 -Rebuild,
     which also compiles the Jaspr web app, deploys it, verifies the deployed
     bundle against the build and proves the database identity first)
  5. Android ADB reverse connection (mobile mode)
  6. Flutter mobile application (mobile mode)

Requirements:
  - FVM configured for the repository
  - Node.js and npm
  - Python
  - Backend .env configuration
  - Android device with USB debugging for mobile mode

Usage:

  Full application (web + Android), the normal one command:
    powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\Start-SiteWise-All.ps1

  Web only (no Android device needed):
    powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\Start-SiteWise-All.ps1 -WebOnly

  Select a particular Android device:
    powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\Start-SiteWise-All.ps1 -DeviceId YOUR_DEVICE_ID

  Run on a different HTTP port for this one session:
    powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\Start-SiteWise-All.ps1 -Port 8100

Configuration (read this before changing anything):

  There are exactly two things an owner normally changes, and neither is
  changed in this file:

  * APPLICATION PORT - edit "$DefaultPort" in run-sitewise.ps1. This script
    reads that value (see section 1b) and aligns the mobile asset, the adb
    reverse rule, the /health probe and the browser URL to it. -Port
    overrides it for one run. Do not add a port constant here.

  * DATABASE - edit the profile env file named in the "EDIT HERE: Database
    configuration" section of run-sitewise.ps1 (backend/var/e2e/pg18/*.env).
    This script holds no connection string and never touches the database.
    The launcher it starts proves the database identity read-only before it
    binds a socket, and refuses to start if the identity is not the expected
    one.

What this script delegates:

  The Jaspr compile, the deploy of the compiled bundle into the profile
  frontend directory, the database-identity preflight and the server itself
  all belong to run-sitewise.ps1, which this script starts with -Rebuild.
  That is deliberate: a build produced here was never deployed, so the
  browser kept serving the previous bundle. One build path, one deploy path,
  one verification.

  The launcher terminal prints the startup receipt when it is ready: the
  profile, the application URL, the database it actually connected to, the
  database port, the principal, the frontend directory and the SHA-256 of the
  bundle the socket is serving. Read that terminal to confirm which database
  and which bundle are live.

Security:
  Never commit backend/.env or credential-containing configuration.
#>

[CmdletBinding()]
param(
    [switch]$WebOnly,
    [string]$DeviceId,
    # HTTP port. 0 means "use the authoritative default", which is read from
    # run-sitewise.ps1 below so the two launchers cannot disagree.
    [int]$Port = 0
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
$runScript = Join-Path $root 'run-sitewise.ps1'

# ============================================================
# 1b. APPLICATION PORT  (single source of truth)
# ============================================================
#
# This script used to hardcode 8090 in three places: the mobile configuration
# assertion, the startup banner and the /health poll. The launcher it delegates
# to defaults to 8093, so the script started a server on one port and then
# polled another for 40 seconds before declaring failure. The port is now READ
# from run-sitewise.ps1 rather than repeated here, which is the only way two
# entry points stay aligned.
#
# EDIT HERE: to change the default port, change $DefaultPort in
# run-sitewise.ps1. Do not add a port constant to this file.
$appPort = $Port
if ($appPort -le 0) {
    if (-not (Test-Path -LiteralPath $runScript)) {
        Write-Host "ERROR: $runScript is missing; cannot resolve the application port." -ForegroundColor Red
        exit 1
    }
    $match = Select-String `
        -LiteralPath $runScript `
        -Pattern '^\$DefaultPort\s*=\s*(\d+)' |
        Select-Object -First 1
    if (-not $match) {
        Write-Host "ERROR: \$DefaultPort not found in run-sitewise.ps1." -ForegroundColor Red
        Write-Host '       The two launchers must agree on the port; fix that line.' -ForegroundColor Red
        exit 1
    }
    $appPort = [int]$match.Matches[0].Groups[1].Value
}

$appUrl = 'http://127.0.0.1:{0}' -f $appPort

# EDIT HERE: how long to wait for the server to answer /health, in seconds.
#
# The launcher is started with -Rebuild, so this window also covers the first
# Jaspr compile and the deploy verification. A warm build finishes in seconds;
# a cold one on a slow machine has been observed to take minutes. Waiting too
# long only delays a real failure, waiting too little reports a false one.
$HealthPollSeconds = 300

# ============================================================
# 1c. DATABASE CONFIGURATION  (deliberately empty)
# ============================================================
#
# EDIT HERE: the database is configured in exactly one place, and it is not
# this file. It is the profile env file that run-sitewise.ps1 selects:
#
#   backend\var\e2e\pg18\app_pg18.env          profile pg18            (default)
#   backend\var\e2e\pg18\app_pg18_demo.env     profile pg18-demo
#   backend\var\e2e\pg18\app_pg18_preview.env  profile pg18-preview
#   backend\var\e2e\pg18\app_pg18_prod_rt24.env profile pg18-prod-rt24
#
# The variables in that file which decide the target are DATABASE_URL,
# M2_DATABASE_URL, PROJECT1_RUNTIME_DATABASE_URL, PROJECT1_AUDIT_DATABASE_URL,
# EE01_DATABASE_URL, and SITEWISE_FRONTEND_DIST for the served bundle.
#
# There is no connection string here on purpose. Before binding a socket the
# launcher proves the target read-only - current_database(), inet_server_port(),
# the server major version, and whether the role is superuser or BYPASSRLS -
# using those same values. A second copy in this script could let the proof and
# the connection disagree, which is the exact failure the proof exists to catch.
#
# -Port changes the HTTP port only. It never changes the PostgreSQL port, which
# is part of the URLs in the profile env file.

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

    Step 'Provision mobile configuration'

    # The asset is git-ignored, so a fresh clone, a new worktree or a branch
    # switch arrives without it and the Flutter build fails on the pubspec
    # asset entry before any Dart code runs. The provisioner writes it from the
    # authorised public defaults (or from backend/.env when that is present)
    # and leaves an existing valid file byte-for-byte untouched.
    $ensureConfig = Join-Path `
        $mobileDir `
        'tool\ensure_sitewise_dev_config.js'

    Need $ensureConfig `
        'The mobile configuration provisioner is missing.'

    # Tell the provisioner which origin to write when it has to CREATE the file.
    # Without this it falls back to its own built-in default, and a freshly
    # written asset points at a port the server is not listening on. Passing
    # the value in means the first write is already correct instead of being
    # corrected immediately afterwards.
    $env:SITEWISE_DEV_ORIGIN = $appUrl

    & node $ensureConfig

    MustSucceed 'Provision mobile configuration'

    Step "Align mobile configuration to the selected port ($appPort)"

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

    # The device reaches the API through "adb reverse tcp:<port>", so the base
    # URL in the asset must carry the SAME port the server binds. This used to
    # be a hardcoded 8090 comparison, which both disagreed with the launcher's
    # default and left the app pointing at a dead port.
    #
    # The alignment cannot live in the provisioner: that script deliberately
    # leaves a complete asset untouched, because a per-machine override is the
    # whole point of a git-ignored file. So it is done here, and identically in
    # run-sitewise.ps1's Sync-MobileConfig, from the same $appPort.
    $mobileChanged = $false

    if ([string]$mobileSettings.API_BASE_URL -ne $appUrl) {
        $mobileSettings.API_BASE_URL = $appUrl
        $mobileChanged = $true
    }

    if ([string]$mobileSettings.WEB_BASE_URL -ne $appUrl) {
        $mobileSettings.WEB_BASE_URL = $appUrl
        $mobileChanged = $true
    }

    if ([string]$mobileSettings.API_HOST_MODE -ne 'adb-reverse') {
        $mobileSettings.API_HOST_MODE = 'adb-reverse'
        $mobileChanged = $true
    }

    if ($mobileChanged) {

        # UTF-8 without a BOM: a BOM breaks the asset reader. The file holds
        # public client values only and is git-ignored.
        $mobileJsonText = $mobileSettings | ConvertTo-Json -Depth 6

        $utf8NoBom = New-Object System.Text.UTF8Encoding($false)

        [System.IO.File]::WriteAllText(
            $mobileJson,
            $mobileJsonText,
            $utf8NoBom
        )

        Write-Host `
            "Mobile configuration aligned: API_BASE_URL = $appUrl" `
            -ForegroundColor Green
    }
    else {
        Write-Host `
            "Mobile configuration already aligned ($appUrl)" `
            -ForegroundColor Green
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

# Step 'Check optional map configuration'

# $backendEnv = Get-Content `
#     -LiteralPath (Join-Path $backendDir '.env')

# $hasMapKey = @(
#     $backendEnv | Where-Object {
#         $_ -match '^\s*CARTO_BASEMAPS_KEY\s*=\s*cb1_'
#     }
# ).Count -gt 0

# if ($hasMapKey) {

#     & npm.cmd run gen-map-config --prefix $toolDir

#     MustSucceed 'npm gen-map-config'
# }
# else {

#     Write-Warning `
#         'CARTO_BASEMAPS_KEY not detected; some map tiles may be unavailable.'
# }

# ============================================================
# 12. DELEGATE THE BUILD, DEPLOY AND DATABASE PREFLIGHT
# ============================================================
#
# This step used to run "fvm dart run jaspr_cli:jaspr build" here. That had two
# defects:
#
#   1. The result was never deployed. run-sitewise.ps1 serves the profile's
#      frontend directory, not build\jaspr, so the browser kept receiving the
#      previous bundle and a rebuild looked like it had no effect.
#   2. Nothing verified the database identity, so a wrong profile surfaced
#      later as a 500 on the first API call instead of as a refusal before any
#      socket was bound.
#
# Both responsibilities now belong to run-sitewise.ps1, which this script
# starts with -Rebuild. It compiles with the pinned FVM SDK, deploys through
# backend/tools/deploy_frontend_dist.py, verifies the deployed bundle against
# the build, and proves the database target read-only before binding.
#
# Keeping a second build here would compile twice and re-open the first gap.

Need `
    (Join-Path $webDir 'pubspec.yaml') `
    'Missing fyp_jaspr_web\pubspec.yaml; there is nothing to build.'

Write-Host `
    'Compile, deploy, database preflight and server: run-sitewise.ps1 -Rebuild' `
    -ForegroundColor DarkGray

# ============================================================
# 13. START FASTAPI SERVER
# ============================================================

Step "Start unified FastAPI server on 127.0.0.1:$appPort"

# The arguments are assembled as a list and joined once, so the port, the
# device and the rebuild flag cannot drift away from the banner above.
$launcherArgs = @('-Port', "$appPort")

if (-not $WebOnly) {

    $launcherArgs += '-Mobile'

    if (-not [string]::IsNullOrWhiteSpace($DeviceId)) {
        $launcherArgs += @('-DeviceId', $DeviceId)
    }
}

# -Rebuild is what makes "start the LATEST application" true. Without it the
# launcher serves whatever was deployed last, which may be an older bundle.
$launcherArgs += '-Rebuild'

# -VerifyFrontend turns "the served bundle is not the build" from a warning into
# a refusal. Combined with -Rebuild the two should always agree, so a mismatch
# means the deploy and the server disagree about SITEWISE_FRONTEND_DIST - the
# exact failure that makes a rebuild appear to have done nothing.
#
# EDIT HERE: drop this argument if you deliberately want to serve a bundle that
# is not the current build (e.g. comparing against a preserved older deploy).
$launcherArgs += '-VerifyFrontend'

$serverCmd = 'call "' + $launcher + '" ' + ($launcherArgs -join ' ')

Write-Host "Launcher command: $serverCmd" -ForegroundColor DarkGray

Start-Process `
    -FilePath 'cmd.exe' `
    -ArgumentList @('/k', $serverCmd) `
    -WorkingDirectory $root |
    Out-Null

# ============================================================
# 14. VERIFY BACKEND HEALTH
# ============================================================

Step 'Verify backend health endpoint'

# The probe URL is derived from $appUrl. It used to be a literal 8090 while the
# launcher bound 8093, so this loop always exhausted its budget and reported a
# failure for a server that was running perfectly.
$healthUrl = $appUrl + '/health'

$ready = $false

for ($i = 0; $i -lt $HealthPollSeconds; $i++) {

    Start-Sleep -Seconds 1

    try {

        $resp = Invoke-WebRequest `
            -Uri $healthUrl `
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
FastAPI health check did not succeed after $HealthPollSeconds seconds.

Probed: $healthUrl

Inspect the newly opened server terminal.

Possible causes:
  - Backend startup exception
  - Database identity preflight refused the profile
  - PostgreSQL not running on the port named in the profile env file
  - Missing backend environment settings
  - Port $appPort already occupied by another process
  - The Jaspr rebuild is still running (it happens before the socket binds)
"@
}

Write-Host `
    'FastAPI health check passed.' `
    -ForegroundColor Green

Write-Host `
    "Web ready: http://localhost:$appPort" `
    -ForegroundColor Green

Start-Process "http://localhost:$appPort" |
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

# The reverse rule must name the SAME port the server binds, otherwise the
# device reaches a port with nothing behind it and the app reports a network
# error while the browser works. run-sitewise.ps1 installs the identical rule
# for its own -Mobile mode; re-applying it here is idempotent and makes this
# script correct even when the launcher was started separately.
$reverseRule = 'tcp:{0}' -f $appPort

Write-Host "Device: $DeviceId"
Write-Host "Mapping device $reverseRule to host $reverseRule"

# Establish the reverse mapping explicitly.
# Do not assume run-sitewise.cmd has already created it.

$reverseOutput = @(
    & $adbExe -s $DeviceId reverse $reverseRule $reverseRule 2>&1
)

if ($LASTEXITCODE -ne 0) {
    throw @"
ADB reverse configuration failed.

Device: $DeviceId
Rule:   $reverseRule

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

$reversePattern = 'tcp:{0}\s+tcp:{0}' -f $appPort

if ($reverseList -notmatch $reversePattern) {
    throw @"
ADB reverse command completed, but the required
$reverseRule -> $reverseRule rule was not confirmed.

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
