<#
.SYNOPSIS
    Starts both Sitewise local services with one command.

.DESCRIPTION
    The web app (port 8090) and the auth/data API (port 3001) are separate
    processes. The signup/login pages need the API for /api/config; when it is
    down they disable Google sign-in and show "Social sign-up is not
    configured in this deployment" (which is exactly the recurring symptom).

    This script opens the API in its own window (so you can see its logs) and
    runs the Jaspr dev server in the current window. Keep BOTH windows open
    while using the site; Ctrl+C in this window stops the web server.

    Since auth_client.js now retries and auto-recovers, a page opened while
    the API was starting will enable Google automatically within ~3 seconds
    of the API coming up - no manual refresh required.

.EXAMPLE
    .\start-sitewise.ps1
#>

$ErrorActionPreference = 'Stop'
$root = Split-Path -Parent $MyInvocation.MyCommand.Path
$webDir = Join-Path $root 'fyp_jaspr_web'
$apiScript = Join-Path $root 'test\start-api.ps1'
$serveScript = Join-Path $webDir 'serve.ps1'

function Test-Port([int]$port) {
    $listeners = Get-NetTCPConnection -LocalPort $port -State Listen -ErrorAction SilentlyContinue
    return [bool]$listeners
}

Write-Host 'Sitewise - starting local services' -ForegroundColor Cyan
Write-Host "  project : $root"

# --- API (port 3001) --------------------------------------------------------
if (Test-Port 3001) {
    Write-Host '  OK     API already running on port 3001' -ForegroundColor Green
} else {
    if (-not (Test-Path $apiScript)) { throw "Missing $apiScript" }
    Write-Host '  START  opening the API in a separate window (port 3001)' -ForegroundColor Yellow
    Start-Process -FilePath 'powershell.exe' -ArgumentList @(
        '-NoExit',
        '-ExecutionPolicy', 'Bypass',
        '-File', ('"{0}"' -f $apiScript)
    ) -WorkingDirectory (Join-Path $root 'test')
}

# --- Generated auth bundle --------------------------------------------------
# auth_bundle.js is generated and git-ignored. Regenerate it on a fresh clone
# so the pages always have the real Supabase bridge (with retry/recovery).
$bundle = Join-Path $webDir 'web\auth_bundle.js'
if (-not (Test-Path $bundle)) {
    Write-Host '  BUILD  generating web/auth_bundle.js' -ForegroundColor Yellow
    Push-Location (Join-Path $webDir 'tool')
    try { & npm.cmd run build-auth } finally { Pop-Location }
}

# --- Web (port 8090) --------------------------------------------------------
Write-Host '  START  Jaspr dev server in this window (port 8090)' -ForegroundColor Yellow
Write-Host '         Keep this window open. The first build can take 1-2 minutes.'
Write-Host ''
Set-ExecutionPolicy -Scope Process -ExecutionPolicy Bypass -Force
Set-Location $webDir
& $serveScript
