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

.EXAMPLE
    .\run-sitewise.ps1
.EXAMPLE
    .\run-sitewise.ps1 -Port 8091
.EXAMPLE
    .\run-sitewise.ps1 -BindHost 0.0.0.0   # allow the Android emulator/device on the LAN
#>
[CmdletBinding()]
param(
    [ValidateRange(1, 65535)] [int]$Port = 8090,
    [string]$BindHost = '127.0.0.1'
)

$ErrorActionPreference = 'Stop'
$root = Split-Path -Parent $MyInvocation.MyCommand.Path
$backendDir = Join-Path $root 'backend'
$distDir = Join-Path $root 'fyp_jaspr_web\build\jaspr'
$pythonExe = Join-Path $backendDir '.venv\Scripts\python.exe'

Write-Host 'Unified SiteWise launcher' -ForegroundColor Cyan

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

# The API resolves backend/.env relative to the working directory; keep it at
# backend/. Local HTTP stays out of any configured proxy.
$env:PYTHONPATH = Join-Path $backendDir 'src'
$env:PYTHONUTF8 = '1'
$env:NO_PROXY = 'localhost,127.0.0.1,::1'
$env:no_proxy = $env:NO_PROXY

Write-Host "  App:      http://localhost:$Port" -ForegroundColor Green
Write-Host '  API docs: /docs   Health: /health' -ForegroundColor Green
Write-Host '  Press Ctrl+C to stop.' -ForegroundColor DarkGray
Write-Host ''

Push-Location $backendDir
try {
    & $pythonExe -m uvicorn sitewise.main:app --host $BindHost --port $Port
    exit $LASTEXITCODE
} finally {
    Pop-Location
}
