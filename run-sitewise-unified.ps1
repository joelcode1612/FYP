<#[
.SYNOPSIS
    Starts SiteWise FastAPI and Jaspr in one Windows PowerShell console.
.DESCRIPTION
    One public browser origin: http://localhost:8090
    Jaspr SSR remains the sole browser-facing HTTP entry point, forwarding
    /api/* and /health requests to FastAPI on 127.0.0.1:8000.
    These are TWO isolated runtimes managed by ONE launcher, not one process.

    If an API already responds on the configured port, use it and do not stop it.
    Only terminate an API process that this launcher itself created.

    Existing fyp_jaspr_web/serve.impl.ps1 remains unchanged, including its
    auth bundle rebuild, development port cleanup, and same-origin proxy.
.EXAMPLE
    powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\run-sitewise-unified.ps1
.EXAMPLE
    powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\run-sitewise-unified.ps1 -WebPort 8091
#>
[CmdletBinding()]
param(
    [ValidateRange(1,65535)] [int]$WebPort = 8090,
    [ValidateRange(1,65535)] [int]$BackendPort = 8000
)

$ErrorActionPreference = 'Stop'

Write-Host 'DEPRECATED: this launcher starts the legacy TWO-server flow' -ForegroundColor Yellow
Write-Host '(Jaspr SSR :8090 proxying to FastAPI :8000). SiteWise now runs as a' -ForegroundColor Yellow
Write-Host 'single FastAPI application server — use .\run-sitewise.cmd instead.' -ForegroundColor Yellow
Write-Host ''

$root = Split-Path -Parent $MyInvocation.MyCommand.Path
$backendDir = Join-Path $root 'backend'
$webDir = Join-Path $root 'fyp_jaspr_web'
$pythonExe = Join-Path $backendDir '.venv\Scripts\python.exe'
$envFile = Join-Path $backendDir '.env'
$serveImpl = Join-Path $webDir 'serve.impl.ps1'

if ($WebPort -eq $BackendPort) {
    throw 'WebPort and BackendPort must differ: Jaspr and FastAPI are separate internal HTTP servers.'
}
if (-not (Test-Path -LiteralPath $serveImpl)) {
    throw "Missing existing Jaspr launcher: $serveImpl"
}

# Only change the environment inherited by these child processes.
# Use one browser-facing origin; never expose the backend directly to browsers.
$env:NO_PROXY = 'localhost,127.0.0.1,::1'
$env:no_proxy = $env:NO_PROXY
$env:SITEWISE_API_PORT = [string]$BackendPort
$env:SITEWISE_API_BASE = "http://127.0.0.1:$BackendPort"
$env:SITEWISE_PUBLIC_API_BASE = ''
$env:PYTHONPATH = Join-Path $backendDir 'src'

function Test-LocalApi {
    param([string]$Address)
    try {
        $request = [System.Net.HttpWebRequest]::Create($Address)
        $request.Method = 'GET'
        $request.Timeout = 2000
        $request.ReadWriteTimeout = 2000
        $request.Proxy = $null
        $response = $request.GetResponse()
        try { return $response.StatusCode -eq [System.Net.HttpStatusCode]::OK }
        finally { $response.Close() }
    } catch {
        return $false
    }
}

$health = "http://127.0.0.1:$BackendPort/health"
$ownedBackend = $null
$webExitCode = 1

Write-Host 'SiteWise unified developer launcher' -ForegroundColor Cyan
Write-Host "  Browser: http://localhost:$WebPort"
Write-Host "  FastAPI: http://127.0.0.1:$BackendPort (internal, loopback only)"
Write-Host '  Terminal: one PowerShell window'
Write-Host ''

try {
    if (Test-LocalApi $health) {
        Write-Host "Using an already-running FastAPI backend at $health" -ForegroundColor Yellow
        Write-Host 'This launcher will not stop that pre-existing process on exit.'
    } else {
        # Fail before starting a duplicate or colliding with another service.
        $listener = Get-NetTCPConnection -LocalPort $BackendPort -State Listen -ErrorAction SilentlyContinue
        if ($listener) {
            throw "Port $BackendPort is occupied but SiteWise /health is not healthy. Inspect the port owner; refusing to replace it."
        }
        if (-not (Test-Path -LiteralPath $pythonExe)) {
            throw "Missing backend virtual environment: $pythonExe"
        }
        if (-not (Test-Path -LiteralPath $envFile)) {
            throw "Missing backend environment file: $envFile"
        }

        Write-Host 'Starting FastAPI in this terminal (no second window)...' -ForegroundColor Cyan
        # Start uvicorn directly rather than invoking start-api.ps1, which opens
        # an additional console in the legacy launcher.
        $ownedBackend = Start-Process -FilePath $pythonExe `
            -ArgumentList @('-m', 'uvicorn', 'sitewise.main:app', '--host', '127.0.0.1', '--port', [string]$BackendPort) `
            -WorkingDirectory $backendDir -NoNewWindow -PassThru

        $healthy = $false
        for ($attempt = 0; $attempt -lt 30; $attempt++) {
            if (Test-LocalApi $health) {
                $healthy = $true
                break
            }
            if ($ownedBackend.HasExited) {
                throw "FastAPI exited during startup (exit code $($ownedBackend.ExitCode))."
            }
            Start-Sleep -Milliseconds 600
        }
        if (-not $healthy) {
            throw "FastAPI did not become healthy at $health. Check its startup output above."
        }
        Write-Host 'FastAPI healthy.' -ForegroundColor Green
    }

    Write-Host ''
    Write-Host 'Starting Jaspr SSR (existing serve.impl.ps1)...' -ForegroundColor Cyan
    # Invoke the existing PowerShell launcher directly, not serve.cmd.
    # That preserves the build/proxy logic without opening another window.
    & powershell.exe -NoProfile -ExecutionPolicy Bypass -File $serveImpl -Port $WebPort
    $webExitCode = $LASTEXITCODE
} finally {
    if ($null -ne $ownedBackend) {
        # Stop ONLY the backend process started by this launcher.
        try {
            $ownedBackend.Refresh()
            if (-not $ownedBackend.HasExited) {
                Write-Host ''
                Write-Host "Stopping managed FastAPI PID $($ownedBackend.Id)..." -ForegroundColor Yellow
                Stop-Process -Id $ownedBackend.Id -Force -ErrorAction Stop
            }
        } catch {
            Write-Warning "Could not stop managed FastAPI cleanly: $_"
        } finally {
            $ownedBackend.Dispose()
        }
    }
}

exit $webExitCode
