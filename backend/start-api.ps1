<#
.SYNOPSIS
    Compatibility launcher: starts the ONE unified SiteWise FastAPI server on 8090.
.DESCRIPTION
    The compiled Jaspr client and /api/v1/* are served by the same FastAPI
    process. No separate Jaspr SSR or port 8000 backend is started.
    Prefer the repository-root run-sitewise.cmd for daily development.
#>
[CmdletBinding()]
param(
    [ValidateRange(1, 65535)] [int]$Port = 8090
)
$ErrorActionPreference = 'Stop'
$root = Split-Path -Parent $PSScriptRoot
$launcher = Join-Path $root 'run-sitewise.ps1'
if (-not (Test-Path -LiteralPath $launcher)) {
    throw "Unified SiteWise launcher not found: $launcher"
}
Write-Host 'This compatibility launcher delegates to the unified FastAPI server.' -ForegroundColor Cyan
& powershell.exe -NoProfile -ExecutionPolicy Bypass -File $launcher -Port $Port
exit $LASTEXITCODE
