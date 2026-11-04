<#
.SYNOPSIS
    Starts the Sitewise application API (port 3001) with the same stale-port
    hygiene as the web project's serve.ps1.

.DESCRIPTION
    The login and signup pages fetch http://localhost:3001/api/config the
    moment they load. If this API is not running, they render Google sign-in
    and sign-up DISABLED ("not configured") - by design, so the UI never
    pretends auth works when it cannot.

    Keep this window open while using the site. Closing the window does NOT
    reliably stop the process on Windows; re-running this script cleans up
    the previous instance first.

.EXAMPLE
    .\start-api.ps1
#>

param(
    [int]$Port = 3001
)

$ErrorActionPreference = 'Stop'

function Write-Step  { param([string]$m) Write-Host $m }
function Write-Ok    { param([string]$m) Write-Host "  OK    $m" -ForegroundColor Green }
function Write-Warn2 { param([string]$m) Write-Host "  WARN  $m" -ForegroundColor Yellow }
function Write-Err2  { param([string]$m) Write-Host "  ERROR $m" -ForegroundColor Red }

Write-Host "Sitewise application API"
Write-Host "  project : $PSScriptRoot"
Write-Host "  port    : $Port"

# --- Stale-port cleanup -----------------------------------------------------
# Same TIME_WAIT exclusion as serve.ps1: TIME_WAIT sockets are remnants of
# closed connections with no owning process (OwningProcess 0 / "Idle") and
# must not abort the start.
Write-Step "Checking port $Port ..."

$held = @(
    Get-NetTCPConnection -ErrorAction SilentlyContinue |
        Where-Object {
            $_.LocalPort -eq $Port -and
            $_.State -ne 'TimeWait' -and
            $_.OwningProcess -ne 0
        }
)

if ($held.Count -eq 0) {
    Write-Ok "port $Port is free"
} else {
    foreach ($ownerPid in ($held | Select-Object -ExpandProperty OwningProcess -Unique)) {
        $proc = Get-Process -Id $ownerPid -ErrorAction SilentlyContinue
        if (-not $proc) { continue }

        # Only kill the Node/API family; anything else is reported and left alone.
        if ($proc.ProcessName -match '^(node|npm|nodejs)$') {
            Write-Warn2 "Stopping stale API instance: PID $ownerPid ($($proc.ProcessName))"
            Stop-Process -Id $ownerPid -Force -ErrorAction SilentlyContinue
        } else {
            Write-Err2 "'$($proc.ProcessName)' (PID $ownerPid) is not a Node process. Refusing to kill it."
            Write-Err2 "Stop it yourself, or start the API on another port."
            exit 1
        }
    }
    Start-Sleep -Milliseconds 800
    Write-Ok "stale instance cleaned up"
}

# --- Start -------------------------------------------------------------------
Write-Step "Starting: npm run start:app"
Write-Step "(Keep this window open while using the site. The sign-in and sign-up"
Write-Step " pages probe this API when they load; refresh the tab after starting it.)"
Write-Host ""

Set-Location $PSScriptRoot
npm run start:app
