<#
.SYNOPSIS
    Starts the Jaspr dev server, clearing stale instances and the proxy trap.

.DESCRIPTION
    Two separate failure modes stop `jaspr serve` on this machine. Both are
    handled here so the command just works.

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
    powershell -ExecutionPolicy Bypass -File .\serve.ps1

.EXAMPLE
    # Use a different port for this run
    .\serve.ps1 -Port 8091

.EXAMPLE
    # Report what would be killed, then exit without starting the server
    .\serve.ps1 -CheckOnly
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

# --- Find whatever is listening ---------------------------------------------
# Both ports are checked: the user-facing one and the internal proxy port.
Write-Step "Checking ports $Port and $ProxyPort ..."

$listeners = @()
try {
    $listeners = @(
        Get-NetTCPConnection -State Listen -ErrorAction SilentlyContinue |
            Where-Object { $_.LocalPort -in $Port, $ProxyPort }
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

        # Report which of the two ports this process holds — they are different
        # failure modes and the message should say which one was cleared.
        $heldPorts = ($listeners |
            Where-Object { $_.OwningProcess -eq $ownerPid } |
            Select-Object -ExpandProperty LocalPort -Unique) -join ', '
        Write-Warn2 "PID $ownerPid ($($proc.ProcessName)) is listening on port(s) $heldPorts"

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
            Get-NetTCPConnection -State Listen -ErrorAction SilentlyContinue |
                Where-Object { $_.LocalPort -in $Port, $ProxyPort }
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
