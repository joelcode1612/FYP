<#
.SYNOPSIS
    Convenience launcher for both Sitewise local services.

.DESCRIPTION
    Service ports:
      8090  Jaspr SSR frontend (fyp_jaspr_web) - HTML/CSS/JS + /api/* proxy
      8000  FYP/backend FastAPI API - /health, /api/v1/*
      5567  Jaspr internal dev proxy (framework-managed)
      8181  Dart VM service (dev only; not related to API auth)

    The intended backend is FYP/backend (Python/FastAPI/Supabase JWKS). The
    old FYP/test Express server on port 3001 is NOT started by this project.

    Public Supabase config (web/auth-config.json) is generated from
    FYP/backend/.env and contains only the publishable key. The Jaspr server
    proxies same-origin /api/* to the backend, so no browser CORS setup and no
    hardcoded API host/port are needed.

    `fyp_jaspr_web\serve.ps1` performs the real health check and starts the
    backend only when it is not already healthy, so this script must not start
    a second copy.

.EXAMPLE
    .\start-sitewise.ps1
#>

$ErrorActionPreference = 'Stop'

Write-Host 'DEPRECATED: this launcher starts the legacy SSR + backend pair.' -ForegroundColor Yellow
Write-Host 'SiteWise now runs as a single FastAPI application server on :8090 —' -ForegroundColor Yellow
Write-Host 'use .\run-sitewise.cmd instead.' -ForegroundColor Yellow
Write-Host ''
$root = Split-Path -Parent $MyInvocation.MyCommand.Path
$webDir = Join-Path $root 'fyp_jaspr_web'
# `.\serve` resolves to serve.cmd (the .ps1 implementation is named
# serve.impl.ps1 deliberately: PowerShell would otherwise pick it first and
# the machine's AllSigned policy would reject it).
$serveScript = Join-Path $webDir 'serve.cmd'

if (-not (Test-Path $serveScript)) { throw "Missing $serveScript" }

Write-Host 'Sitewise - starting local services' -ForegroundColor Cyan
Write-Host "  web     : $webDir (port 8090)"
Write-Host "  backend : $(Join-Path $root 'backend') (port 8000)"
Write-Host '  NOTE    : FYP/test is not used as an application API.'
Write-Host ''

Set-ExecutionPolicy -Scope Process -ExecutionPolicy Bypass -Force
Set-Location $webDir
& $serveScript
exit $LASTEXITCODE
