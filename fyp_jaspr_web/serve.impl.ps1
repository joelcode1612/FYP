<#
.SYNOPSIS
    Starts the Jaspr SSR dev server against the intended FastAPI backend,
    clearing stale instances and the proxy trap.

.DESCRIPTION
    Service ports for a normal local run:
      8090  Jaspr SSR frontend (this script) - HTML, CSS, JS, /api/* proxy
      8000  FYP/backend FastAPI API  - GET /health, /api/v1/*
      5567  Jaspr's internal dev/build proxy (framework-managed)
      8181  Dart VM service (dev only; unrelated to API authentication)

    The backend is FYP/backend (Python/FastAPI), NOT FYP/test (the old Express
    research server on 3001). The frontend never needs to know port 8000: the
    SSR process proxies same-origin /api/* to it.

    Two separate failure modes used to stop `jaspr serve` on this machine. Both
    are handled here so the command just works.

    ## 1. Stale instance holding the port
    `jaspr serve` fails with `errno 10048 (EADDRINUSE)` when a previous run is
    still alive. On Windows that happens routinely, because closing a terminal
    window does NOT terminate the processes it started — unlike POSIX, where the
    shell sends SIGHUP to the whole process group.

    The observed failure mode: a server started hours earlier is still listening
    on the configured port, so every new `jaspr serve` fails to bind while the
    OLD server keeps serving the OLD built assets. That looks exactly like "my
    code changes had no effect", which is what makes it expensive to diagnose.

    ## 2. HTTP_PROXY set with no NO_PROXY
    This machine has `HTTP_PROXY` set but `NO_PROXY` unset (your own
    `flutter doctor` reports this as `[!] Proxy Configuration`). Every
    `localhost` request is therefore routed through a proxy that cannot reach
    it, which produces:
      * the build daemon's WebSocket to `localhost:<random>` returning **502**,
        which aborts the build with
        `WebSocketException: ... was not upgraded to websocket, HTTP status 502`
      * a running server that answers **500/502 on every path**, including
        static files like `/styles.css`
      * the Dart VM service failing to bind on 8181

    Setting `NO_PROXY` to cover localhost fixes all three at once. The script
    sets it for the child process only — your machine-wide environment is not
    modified.

    This script removes that failure mode. It reads the port from pubspec.yaml
    (the same source jaspr itself uses, so the two cannot drift), finds whatever
    is listening on it, and terminates that Dart process tree before starting.

    It only ever kills processes that (a) own the port and (b) are part of the
    Dart/Jaspr process family, so an unrelated service on the same port is
    reported rather than killed.

.EXAMPLE
    .\serve              (serve.cmd invokes this script with Bypass)

.EXAMPLE
    # Use a different port for this run
    .\serve -Port 8091

.EXAMPLE
    # Report what would be killed, then exit without starting the server
    .\serve -CheckOnly
#>

[CmdletBinding()]
param(
    # Override the port. Defaults to `jaspr.port` in pubspec.yaml.
    [int]$Port = 0,

    # Detect and clean up, but do not start the server.
    [switch]$CheckOnly,

    # Do not kill anything; only report what is holding the port.
    [switch]$NoKill
)

$ErrorActionPreference = 'Stop'

function Write-Step  { param([string]$m) Write-Host $m }
function Write-Ok    { param([string]$m) Write-Host "  OK    $m" -ForegroundColor Green }
function Write-Warn2 { param([string]$m) Write-Host "  WARN  $m" -ForegroundColor Yellow }
function Write-Err2  { param([string]$m) Write-Host "  ERROR $m" -ForegroundColor Red }

# --- Resolve the port from pubspec.yaml -------------------------------------
function Get-JasprPort {
    $pubspec = Join-Path $PSScriptRoot 'pubspec.yaml'
    if (-not (Test-Path $pubspec)) { return 8090 }

    $inJasprBlock = $false
    foreach ($line in (Get-Content -LiteralPath $pubspec)) {
        if ($line -match '^jaspr:\s*$') { $inJasprBlock = $true; continue }
        # Any new top-level key ends the jaspr block.
        if ($inJasprBlock -and $line -match '^[A-Za-z]') { break }
        if ($inJasprBlock -and $line -match '^\s+port:\s*(\d+)') {
            return [int]$Matches[1]
        }
    }
    return 8090
}

# Returns the process and its ancestors, stopping at the first non-Dart parent.
#
# Uses `Get-CimInstance Win32_Process` rather than `Process.Parent`, because
# **`Process.Parent` does not exist on Windows PowerShell 5.1** — it is a .NET
# Core addition. On 5.1 it evaluates to `$null`, so a loop written against it
# silently never ascends and only the port holder is killed, leaving the
# `dart.exe` CLI that spawned it still running. CIM's `ParentProcessId` works on
# both 5.1 and 7+.
function Get-DartProcessChain {
    param([int]$StartPid)

    $chain = New-Object System.Collections.Generic.List[int]
    $chain.Add($StartPid)

    $current = $StartPid
    # Depth guard: the Dart/Jaspr tree is 2-3 deep, so 8 is generous while still
    # bounding the loop if the parent chain is ever malformed.
    for ($depth = 0; $depth -lt 8; $depth++) {
        $proc = Get-CimInstance Win32_Process -Filter "ProcessId = $current" -ErrorAction SilentlyContinue
        if (-not $proc) { break }

        $parentId = [int]$proc.ParentProcessId
        if ($parentId -le 0) { break }

        $parent = Get-CimInstance Win32_Process -Filter "ProcessId = $parentId" -ErrorAction SilentlyContinue
        if (-not $parent) { break }

        # Stop as soon as the ancestry leaves the Dart family, so this can never
        # climb into the shell, the IDE, or an unrelated process.
        if ($parent.Name -notmatch '^dart') { break }
        if ($chain.Contains($parentId)) { break }

        $chain.Add($parentId)
        $current = $parentId
    }

    return $chain
}

if ($Port -le 0) { $Port = Get-JasprPort }

# Jaspr's dev proxy binds a **fixed** internal port before the user-facing one.
# `jaspr serve` (the global CLI binary) takes the `ProxyHelper.startProxy` path;
# `dart run jaspr_cli:jaspr serve` does not. Either way, a previous instance
# holds it, and the resulting error names 5567 rather than the port you passed —
# which is why it is easy to misread as a problem with `-p`.
$ProxyPort = 5567

Write-Step "Jaspr dev server"
Write-Step "  project : $PSScriptRoot"
Write-Step "  port    : $Port"
Write-Step "  proxy   : $ProxyPort (Jaspr's internal dev-proxy port)"
Write-Step ""

# --- Find whatever is using either port -------------------------------------
# Both ports are checked: the user-facing one and the internal proxy port.
#
# Do not filter to State=Listen here. On Windows, an orphaned Dart/Jaspr proxy
# can retain CLOSE_WAIT sockets after its listener has gone away. It is absent
# from a Listen-only query but still prevents shelf from binding 0.0.0.0 to
# the same port (WSAEADDRINUSE / errno 10048).
#
# EXCEPT TimeWait: those are protocol-mandated remnants of already-closed
# connections (they linger ~2-4 minutes after the last packet). They have no
# owning process — Get-NetTCPConnection reports OwningProcess 0 ("Idle") —
# and they are not held by anything killable. Filtering them out lets the
# start proceed normally; if a bind conflict genuinely remains, jaspr itself
# fails loudly, which is a better outcome than blocking on a phantom PID.
Write-Step "Checking ports $Port and $ProxyPort ..."

$listeners = @()
try {
    $listeners = @(
        Get-NetTCPConnection -ErrorAction SilentlyContinue |
            Where-Object {
                $_.LocalPort -in $Port, $ProxyPort -and
                $_.State -ne 'TimeWait' -and
                $_.OwningProcess -ne 0
            }
    )
} catch {
    Write-Warn2 "Get-NetTCPConnection unavailable; falling back to netstat."
}

if ($listeners.Count -eq 0) {
    Write-Ok "ports $Port and $ProxyPort are free"
} else {
    $pids = $listeners | Select-Object -ExpandProperty OwningProcess -Unique

    foreach ($ownerPid in $pids) {
        $proc = Get-Process -Id $ownerPid -ErrorAction SilentlyContinue
        if (-not $proc) {
            Write-Warn2 "PID $ownerPid owns a port but has already exited"
            continue
        }

        # Report which of the two ports this process holds. Include socket
        # states because CLOSE_WAIT is the important non-listening case above.
        $heldPorts = ($listeners |
            Where-Object { $_.OwningProcess -eq $ownerPid } |
            ForEach-Object { "$($_.LocalPort) [$($_.State)]" } |
            Select-Object -Unique) -join ', '
        Write-Warn2 "PID $ownerPid ($($proc.ProcessName)) owns socket(s) $heldPorts"

        # Only touch the Dart/Jaspr family. An unrelated service on this port is
        # reported and left alone, because killing it could break something else.
        if ($proc.ProcessName -notmatch '^(dart|dartvm|dartaotruntime)$') {
            Write-Err2 "'$($proc.ProcessName)' is not a Dart process. Refusing to kill it."
            Write-Err2 "Stop it yourself, or run this script with -Port <other>."
            exit 1
        }

        # Walk up the ancestry while the parents are also Dart processes, so the
        # CLI that spawned the server is killed too and cannot respawn it.
        $chain = Get-DartProcessChain -StartPid $ownerPid

        $names = ($chain | ForEach-Object {
            $p = Get-Process -Id $_ -ErrorAction SilentlyContinue
            if ($p) { "$($p.ProcessName)#$_" } else { "#$_" }
        }) -join ' <- '

        Write-Step "        chain: $names"

        if ($NoKill) {
            Write-Warn2 "-NoKill specified; leaving it running."
            continue
        }

        # Kill children first, then the parent, so nothing is respawned.
        foreach ($id in $chain) {
            $target = Get-Process -Id $id -ErrorAction SilentlyContinue
            if ($target) {
                Stop-Process -Id $id -Force -ErrorAction SilentlyContinue
                Write-Ok "killed PID $id ($($target.ProcessName))"
            }
        }
    }

    Start-Sleep -Milliseconds 800

    $stillHeld = @()
    try {
        $stillHeld = @(
            Get-NetTCPConnection -ErrorAction SilentlyContinue |
                Where-Object {
                    $_.LocalPort -in $Port, $ProxyPort -and
                    $_.State -ne 'TimeWait' -and
                    $_.OwningProcess -ne 0
                }
        )
    } catch { }

    if ($stillHeld.Count -gt 0) {
        $ports = ($stillHeld | Select-Object -ExpandProperty LocalPort -Unique) -join ', '
        Write-Err2 "port(s) $ports are STILL held. Investigate before continuing:"
        Write-Err2 "  netstat -ano | findstr :$Port"
        Write-Err2 "  netstat -ano | findstr :$ProxyPort"
        exit 1
    }
    Write-Ok "ports $Port and $ProxyPort are now free"
}

if ($CheckOnly) {
    Write-Step ""
    Write-Step "-CheckOnly specified. Not starting the server."
    exit 0
}

# --- Ensure the intended FastAPI backend is reachable ----------------------
# FYP/backend (uvicorn on 8000) owns token verification, profiles and the
# property catalogue. The legacy Express research API in FYP/test (port 3001)
# is NEVER started here. A health check avoids spawning duplicate processes.
$apiPort = if ($env:SITEWISE_API_PORT) { [int]$env:SITEWISE_API_PORT } else { 8000 }
if (-not $env:SITEWISE_API_BASE) { $env:SITEWISE_API_BASE = "http://127.0.0.1:$apiPort" }
# Empty = the browser uses same-origin /api/* and the SSR server proxies it.
if ($null -eq $env:SITEWISE_PUBLIC_API_BASE) { $env:SITEWISE_PUBLIC_API_BASE = '' }

function Test-BackendHealth([string]$url) {
    try {
        $req = [System.Net.HttpWebRequest]::Create($url)
        $req.Method = 'GET'
        $req.Timeout = 2500
        $req.ReadWriteTimeout = 2500
        $req.Proxy = $null
        $resp = $req.GetResponse()
        try { return ($resp.StatusCode -eq [System.Net.HttpStatusCode]::OK) }
        finally { $resp.Close() }
    } catch { return $false }
}

$backendHealth = "http://127.0.0.1:$apiPort/health"
if (Test-BackendHealth $backendHealth) {
    Write-Ok "FastAPI backend healthy at $backendHealth (FYP/backend)"
} else {
    $occupied = $false
    try { $occupied = [bool](Get-NetTCPConnection -LocalPort $apiPort -State Listen -ErrorAction SilentlyContinue) } catch { }
    if ($occupied) {
        Write-Err2 "Port $apiPort is occupied but /health did not answer. Not starting a duplicate process."
        Write-Err2 'Expected FYP/backend (uvicorn sitewise.main:app). Inspect that window or run:'
        Write-Err2 '  netstat -ano | findstr :8000'
    } else {
        $backendDir = Join-Path (Split-Path -Parent $PSScriptRoot) 'backend'
        $starter = Join-Path $backendDir 'start-api.ps1'
        if (-not (Test-Path $starter)) {
            Write-Err2 "Backend starter missing: $starter"
            Write-Err2 'Start it manually: cd FYP\backend; .\start-api.ps1'
        } else {
            Write-Step "FastAPI backend not running. Starting FYP/backend in its own window (port $apiPort)..."
            Start-Process -FilePath 'powershell.exe' -ArgumentList @(
                '-NoExit', '-ExecutionPolicy', 'Bypass',
                '-File', ('"{0}"' -f $starter), '-Port', $apiPort
            ) -WorkingDirectory $backendDir | Out-Null
            $healthy = $false
            for ($i = 0; $i -lt 30; $i++) {
                Start-Sleep -Milliseconds 600
                if (Test-BackendHealth $backendHealth) { $healthy = $true; break }
            }
            if ($healthy) {
                Write-Ok "FastAPI backend is up at $backendHealth"
            } else {
                Write-Err2 'Backend did not become healthy within 18 seconds.'
                Write-Err2 'Check the backend window. Common causes:'
                Write-Err2 '  - missing FYP/backend/.env (copy .env.example)'
                Write-Err2 '  - PostgreSQL not running on localhost:5432'
                Write-Err2 '  - missing venv: cd FYP\backend; .\.venv\Scripts\pip install -e .'
                Write-Err2 'The web server will still start; API-backed pages will report errors.'
            }
        }
    }
}

# --- Generated public config + auth bundle ----------------------------------
# auth-config.json is generated from FYP/backend/.env and contains ONLY the
# public Supabase URL + publishable key. auth_bundle.js is built from the
# source tool/auth_client.js (never patch the minified output by hand).
$toolDir = Join-Path $PSScriptRoot 'tool'
$configFile = Join-Path $PSScriptRoot 'web\auth-config.json'
$bundleFile = Join-Path $PSScriptRoot 'web\auth_bundle.js'
Push-Location $toolDir
try {
    $genScript = Join-Path $toolDir 'gen_auth_config.js'
    $needConfig = $true
    if (Test-Path $configFile) {
        $needConfig = (Get-Item $genScript).LastWriteTime -gt (Get-Item $configFile).LastWriteTime
    }
    if ($needConfig) {
        Write-Step '  BUILD  generating web/auth-config.json from FYP/backend/.env'
        & npm.cmd run gen-auth-config
        if ($LASTEXITCODE -ne 0) { Write-Err2 'gen-auth-config failed; sign-in will not be configured.' }
    }
    $authSource = Join-Path $toolDir 'auth_client.js'
    $needBundle = $true
    if (Test-Path $bundleFile) {
        $needBundle = (Get-Item $authSource).LastWriteTime -gt (Get-Item $bundleFile).LastWriteTime
    }
    if ($needBundle) {
        Write-Step '  BUILD  regenerating web/auth_bundle.js from tool/auth_client.js'
        & npm.cmd run build-auth
        if ($LASTEXITCODE -ne 0) { Write-Err2 'build-auth failed; the existing bundle will be used.' }
    }
} finally { Pop-Location }

Write-Step "  API    : $env:SITEWISE_API_BASE (browser uses same-origin /api/*)"

# --- Start ------------------------------------------------------------------

# The proxy fix. `HTTP_PROXY` is set on this machine with `NO_PROXY` unset, so
# localhost traffic is routed through a proxy that cannot reach it — which makes
# the build daemon's WebSocket return 502 and the server answer 500 on every
# path. Scope these to this process only; the machine environment is untouched.
$env:NO_PROXY = "localhost,127.0.0.1,::1"
$env:no_proxy = $env:NO_PROXY
Write-Step "NO_PROXY set for this process: $env:NO_PROXY"

Write-Step ""
Write-Step "Starting: dart run jaspr_cli:jaspr serve -p $Port"
Write-Step "(Ctrl+C stops it. Closing this window does NOT - the process survives"
Write-Step " on Windows. Re-run this script next time and it will clean up.)"
Write-Step ""

Push-Location $PSScriptRoot
try {
    & dart run jaspr_cli:jaspr serve -p $Port
    $exitCode = $LASTEXITCODE
} finally {
    Pop-Location
}

exit $exitCode
