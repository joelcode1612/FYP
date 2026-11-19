<#
.SYNOPSIS
    Legacy Jaspr `serve` compatibility entrypoint for unified SiteWise.
.DESCRIPTION
    The Jaspr frontend is compiled in client mode and hosted by FastAPI.
    This script delegates to repo-root run-sitewise.ps1 on port 8090.
    It NEVER starts the retired SSR proxy or a second backend on 8000.
#>
[CmdletBinding()]
param(
    [ValidateRange(1, 65535)] [int]$Port = 8090,
    [switch]$CheckOnly,
    [switch]$NoKill
)
$ErrorActionPreference = 'Stop'
$root = Split-Path -Parent $PSScriptRoot
$launcher = Join-Path $root 'run-sitewise.ps1'
if (-not (Test-Path -LiteralPath $launcher)) {
    throw "Unified SiteWise launcher not found: $launcher"
}
if ($CheckOnly) {
    foreach ($uri in @("http://127.0.0.1:$Port/health", "http://127.0.0.1:$Port/api/v1/health")) {
        try {
            $result = Invoke-WebRequest -Uri $uri -UseBasicParsing -TimeoutSec 5 -Headers @{ Accept = 'application/json' }
            $ctype = [string]$result.Headers['Content-Type']
            if ($ctype -notmatch 'application/json') { throw "Expected JSON, received $ctype" }
            $body = $result.Content | ConvertFrom-Json
            if ($body.status -notin @('ok', 'degraded')) { throw 'Unexpected health status' }
            if ($uri -like '*/api/v1/health' -and $body.status -ne 'ok') { throw 'Database health is degraded' }
            Write-Host "OK: $uri" -ForegroundColor Green
        } catch {
            Write-Host "UNAVAILABLE: $uri - $($_.Exception.Message)" -ForegroundColor Red
            exit 1
        }
    }
    exit 0
}
if ($NoKill) { Write-Host 'The unified launcher never kills running processes.' -ForegroundColor Cyan }
Write-Host 'Redirecting the legacy Jaspr command to unified FastAPI :8090.' -ForegroundColor Cyan
& powershell.exe -NoProfile -ExecutionPolicy Bypass -File $launcher -Port $Port
exit $LASTEXITCODE
