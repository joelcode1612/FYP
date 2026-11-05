<#
.SYNOPSIS
    Starts the intended Sitewise FastAPI backend (uvicorn, port 8000).

.DESCRIPTION
    This is FYP/backend (Python / FastAPI / SQLModel / Supabase JWKS), NOT the
    throwaway Express server in FYP/test (port 3001). The Jaspr SSR frontend
    calls it through a same-origin /api/* proxy, so CORS is not required for
    normal browser traffic.

    Endpoints: GET /health, GET /api/v1/health, GET /api/v1/auth/me,
    GET /api/v1/catalog/properties, and the rest of /api/v1/*.

    Keep this window open while using the site. `serve.ps1` runs a health
    check first and only launches this script when the backend is not already
    running, so no duplicate process is started.

.EXAMPLE
    powershell -ExecutionPolicy Bypass -File .\start-api.ps1
#>

param(
    [int]$Port = 8000
)

$ErrorActionPreference = 'Stop'

$root = $PSScriptRoot
$python = Join-Path $root '.venv\Scripts\python.exe'
$src = Join-Path $root 'src'
$envFile = Join-Path $root '.env'

if (-not (Test-Path $python)) {
    throw "Missing Python virtualenv at $python. Create it with: python -m venv .venv; .\.venv\Scripts\pip install -e ."
}
if (-not (Test-Path $envFile)) {
    throw "Missing $envFile. Copy .env.example to .env and fill in the Supabase + database values."
}

# `sitewise` is installed editable in the venv; this also makes a fresh
# checkout work before `pip install -e .` has been run.
$env:PYTHONPATH = $src
# This machine sets HTTP_PROXY but not NO_PROXY; keep loopback traffic direct.
$env:NO_PROXY = 'localhost,127.0.0.1,::1'
$env:no_proxy = $env:NO_PROXY

Write-Host 'Sitewise FastAPI backend'
Write-Host "  project : $root"
Write-Host "  port    : $Port"
Write-Host '  docs    : /docs, /openapi.json'
Write-Host ''
Write-Host "Starting: python -m uvicorn sitewise.main:app --host 127.0.0.1 --port $Port"
Write-Host ''

Set-Location $root
& $python -m uvicorn sitewise.main:app --host 127.0.0.1 --port $Port
exit $LASTEXITCODE
