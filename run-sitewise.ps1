<#
.SYNOPSIS
    Starts the unified SiteWise application: ONE FastAPI server serving both the
    Jaspr web frontend and the Flutter mobile API.

.DESCRIPTION
    FastAPI is the ONLY application server. It serves the compiled Jaspr
    frontend (static assets plus an SPA fallback) on the same origin as the REST
    API (/api/v1/*, /health, /docs). There is no Jaspr SSR process, no second
    FastAPI instance and no Node/Express server.

        Browser / Flutter Mobile
                  |
                  v
        Unified FastAPI  http://<host>:<port>
                  |
                  +-- compiled Jaspr frontend + SPA fallback
                  +-- /api/v1/*   /health   /docs
                  +-- Supabase authentication, PostgreSQL

    The application is the same in every environment; only the injected
    environment differs. A PROFILE selects that environment. The default
    profile is 'pg18', which targets the isolated PostgreSQL 18 test database
    on port 5544 with least-privilege runtime roles.

    The legacy environment (profile 'dev', which reads backend/.env and points
    at the protected Final_Location_Analysis database on PostgreSQL 16) is
    REFUSED. That database does not contain the tables the current code reads,
    so starting against it would produce a server that answers 500 on every
    research route. Use -AllowLegacyDatabase only after repointing backend/.env
    at a local database you own.

    Before a socket is bound, the launcher proves the target: it asks the
    server for current_database(), inet_server_port(), its major version and
    whether the connecting role holds superuser or BYPASSRLS, and it refuses on
    any disagreement. A connection string is a claim; the server's answer is
    evidence.

.PARAMETER Profile
    Runtime profile: pg18 (default), pg18-demo, pg18-preview, pg18-prod-rt24,
    or dev. Each profile names one environment file under
    backend/var/e2e/pg18/ and one expected PostgreSQL major version.
    Default: the value of $DefaultProfile in the EDIT HERE section.

.PARAMETER Port
    Application (HTTP) port. One authoritative value: the bind port, the
    browser URL, the health and checksum URLs, the adb reverse mapping, the
    local CORS origins and the authentication redirects are all derived from
    it. It never changes the PostgreSQL port or the database identity.
    Default: the value of $DefaultPort in the EDIT HERE section (8093).

.PARAMETER BindHost
    Interface uvicorn binds. 127.0.0.1 keeps the server on this machine (the
    phone reaches it through adb reverse). 0.0.0.0 exposes it on the LAN and
    requires a firewall rule. Default: $DefaultBindHost (127.0.0.1).

.PARAMETER Mobile
    Enable mobile CONNECTIVITY only: install `adb reverse tcp:<Port> tcp:<Port>`
    for the attached device so the phone can reach this PC at
    127.0.0.1:<Port>. Does NOT build or launch the Flutter app. The rule is
    removed when this launcher exits.

.PARAMETER RunMobile
    Implies -Mobile, then builds and launches the Flutter app on the selected
    device with `flutter run`. Use -Mobile alone when you only need the API
    reachable from a device you start yourself.

.PARAMETER DeviceId
    Android device serial for -Mobile / -RunMobile when more than one device is
    attached. List them with `adb devices -l`.

.PARAMETER AllowLan
    Shorthand for -BindHost 0.0.0.0, so a device on the same subnet can reach
    the API directly instead of through adb reverse.

.PARAMETER Rebuild
    Regenerate the browser auth assets, the optional map configuration and the
    Jaspr client bundle, then deploy the result to the profile's frontend
    directory and verify the deployment. Adds one to three minutes.

.PARAMETER VerifyFrontend
    Require the DEPLOYED bundle to be byte-identical to the freshly built one.
    Without this switch a divergence is reported as a warning; with it, a
    divergence stops startup. The socket-level checksum is always verified.

.PARAMETER OpenBrowser
    Open the application URL in the default browser after readiness passes.

.PARAMETER AllowLegacyDatabase
    Permit a profile whose target is not a PG18 test database. Protected
    database names (Final_Location_Analysis, Dss) and protected ports (5432,
    5433) are refused regardless of this switch.

.PARAMETER InstallDependencies
    Install the backend Python dependencies declared in backend/pyproject.toml
    into backend/.venv before starting. Never runs automatically.

.PARAMETER StartupTimeoutSeconds
    How long to wait for /health before declaring startup failed.
    Default: $DefaultStartupTimeoutSeconds (90).

.EXAMPLE
    .\run-sitewise.ps1
    Start the default PG18 profile on port 8093 and verify it.

.EXAMPLE
    .\run-sitewise.ps1 -Mobile
    Start, and make the API reachable from an attached Android device.

.EXAMPLE
    .\run-sitewise.ps1 -Rebuild
    Rebuild the Jaspr bundle, deploy it, then start and verify.

.EXAMPLE
    .\run-sitewise.ps1 -Port 8095
    Start on 8095. CORS, the health URL, the adb reverse rule and the auth
    redirects all follow automatically. The database port stays 5544.

.EXAMPLE
    .\run-sitewise.ps1 -VerifyFrontend -OpenBrowser
    Refuse to start if the deployed bundle differs from the build, then open
    the browser once readiness passes.

.EXAMPLE
    .\run-sitewise.ps1 -RunMobile -DeviceId R58M12ABCDE
    Start, then build and launch the Flutter app on a specific device.

.EXAMPLE
    Get-Help .\run-sitewise.ps1 -Full
    Show this documentation.

.NOTES
    PREREQUISITES
      * backend/.venv created and populated:
            python -m venv backend/.venv
            backend\.venv\Scripts\python.exe -m pip install -e backend
      * PostgreSQL 18 running on 127.0.0.1:5544 with the migrated test
        database (project1_pg18_migrated_tests).
      * For -Rebuild: a Dart SDK. The launcher prefers the pinned FVM SDK at
        .fvm/flutter_sdk, then `fvm dart`, then `dart` on PATH.
      * For -Rebuild: Node.js, used to regenerate the browser auth assets.
      * For -Mobile / -RunMobile: Android platform-tools (adb) and a device
        with USB debugging authorized.

    CONFIGURATION
      Ordinary defaults live in ONE place: the "EDIT HERE" section immediately
      below the parameter block of this script. Every value there is a plain
      variable with a comment explaining what it changes. Command-line
      parameters override them for a single run; nothing else in the repository
      needs editing to change the port, the profile or the bind host.

      The application port is "$DefaultPort" / -Port, set under
      "EDIT HERE: Default FastAPI application port". The bind, the browser URL,
      the health and checksum URLs, the adb reverse mapping, CORS and the auth
      redirects all derive from it.

      The DATABASE is not configured here. It is selected by the profile, and
      each profile names one environment file in backend/var/e2e/pg18/. To point
      at a different database, edit that env file - see
      "EDIT HERE: Database configuration" below for the exact files and the
      variables that decide the target. There is no connection string in this
      script on purpose: preflight proves the target using those same values, and
      a second copy could let the proof and the connection disagree.

      -Port changes the HTTP port only. It never changes the PostgreSQL port,
      which is part of the URLs in the profile's env file.

    DATABASE SAFETY
      * This launcher NEVER applies migrations and NEVER writes business rows.
        Preflight opens read-only connections and issues only catalog and
        identity queries.
      * It refuses a protected database name, a protected port, a superuser or
        BYPASSRLS principal, an unexpected server major version, a missing
        required table, and an internally inconsistent set of expected-database
        keys. It fails closed; it never falls back to another database.
      * Least-privilege runtime roles are preserved. Do not widen them to make
        startup pass.

    SHUTDOWN
      Press Ctrl+C in this window. The server is a child of this script, so it
      receives the interrupt and the adb reverse rule is removed on exit.
      If a server process survives, find and stop ONLY that process:
            Get-NetTCPConnection -LocalPort 8093 -State Listen |
                Select-Object -ExpandProperty OwningProcess |
                ForEach-Object { Stop-Process -Id $_ }
      This launcher never terminates a process it did not start.

    TROUBLESHOOTING
      "REFUSED: ... protected database"      The profile points at 5432 or at a
                                             protected database name. Check the
                                             DATABASE_URL lines in the profile
                                             file named in the message.
      "port is held"                         Something else owns the port.
                                             Stop it yourself, or use -Port.
      "frontend is incomplete"               Run with -Rebuild, or check
                                             SITEWISE_FRONTEND_DIST.
      "served bundle is NOT the build"       The deploy did not reach the socket
                                             the browser reads. Run -Rebuild.
      "readiness ... degraded"               The API is up but a worker is not.
                                             A missing optional module (cv2) is
                                             the usual cause; the receipt names
                                             it. Web and mobile still work.
      "adb reverse failed"                   Reconnect USB, accept the RSA
                                             prompt, re-run. Use -DeviceId when
                                             several devices are attached.
      Login redirects to the wrong port      Supabase also holds its own
                                             redirect allowlist. See
                                             SITEWISE_STARTUP_GUIDE.md.
#>

[CmdletBinding()]
param(
    [string]$Profile = '',
    [int]$Port = 0,
    [string]$BindHost = '',
    [switch]$Mobile,
    [switch]$RunMobile,
    [string]$DeviceId = '',
    [switch]$AllowLan,
    [switch]$Rebuild,
    [switch]$VerifyFrontend,
    [switch]$OpenBrowser,
    [switch]$AllowLegacyDatabase,
    [switch]$InstallDependencies,
    [int]$StartupTimeoutSeconds = 0
)

# ============================================================================
# SECTION 1 - EDIT HERE: configurable defaults
# ----------------------------------------------------------------------------
# These are the only values an owner normally changes. Each has one purpose and
# one place. A command-line parameter overrides any of them for a single run.
# ============================================================================

# EDIT HERE: Default runtime profile.
#   'pg18'            the current implementation (PostgreSQL 18, port 5544)
#   'pg18-demo'       same database, same frontend directory
#   'pg18-preview'    separate frontend directory (frontend_preview)
#   'pg18-prod-rt24'  separate frontend directory (frontend_prod_rt24)
#   'dev'             legacy backend/.env; REFUSED unless the target is safe
# Alternatively, use -Profile when invoking the launcher.
$DefaultProfile = 'pg18'

# EDIT HERE: Default FastAPI application port.
# Everything port-dependent is derived from this one value (bind, browser URL,
# health and checksum URLs, adb reverse, CORS, auth redirects). It never
# changes the PostgreSQL port.
# Alternatively, use -Port when invoking the launcher.
$DefaultPort = 8093

# EDIT HERE: Database configuration.
# ----------------------------------------------------------------------------
# This script deliberately contains NO connection string. The database is chosen
# by the profile above, and each profile names exactly one environment file:
#
#   pg18            backend\var\e2e\pg18\app_pg18.env
#   pg18-demo       backend\var\e2e\pg18\app_pg18_demo.env
#   pg18-preview    backend\var\e2e\pg18\app_pg18_preview.env
#   pg18-prod-rt24  backend\var\e2e\pg18\app_pg18_prod_rt24.env
#   dev             backend\.env              (legacy; refused unless -AllowLegacyDatabase)
#
# TO CHANGE THE DATABASE, EDIT THAT FILE - not this script. The variables in it
# that decide the target are:
#
#   DATABASE_URL                    the application's primary database
#   M2_DATABASE_URL                 the M2 principal's database
#   PROJECT1_RUNTIME_DATABASE_URL   the AI ledger principal's database
#   PROJECT1_AUDIT_DATABASE_URL     the audit principal's database
#   EE01_DATABASE_URL               the CQ respondent principal's database
#   SITEWISE_FRONTEND_DIST          the directory the server serves the SPA from
#
# Why there is no second copy here: before binding a socket, SECTION 5 proves the
# target by asking the server for current_database(), inet_server_port(), its
# major version and whether the role is superuser or BYPASSRLS - using these
# values. A copy in this file could let the proof and the connection disagree,
# which is precisely the failure the proof exists to catch.
#
# The PostgreSQL port is part of those URLs (5544 for the PG18 profiles). It is
# NOT $DefaultPort above: -Port changes the HTTP port only and never the
# database. To run against a different database, copy an env file and add a
# profile to $KnownProfiles below rather than editing a URL in two places.
#
# Below is where the script reads the directory. The profile's own env file is
# selected by name from the server's report, so the launcher and the server
# cannot disagree about which file is in force.
$DatabaseConfigRelative = 'var\e2e\pg18'

# EDIT HERE: Default bind host.
#   127.0.0.1  this machine only; a phone reaches it through adb reverse
#   0.0.0.0    all interfaces; needs a firewall rule and exposes the API on the
#              LAN. -AllowLan is a shorthand for this.
# Alternatively, use -BindHost or -AllowLan when invoking the launcher.
$DefaultBindHost = '127.0.0.1'

# EDIT HERE: Default startup timeout, in seconds.
# How long to wait for /health to answer before declaring startup failed.
# Alternatively, use -StartupTimeoutSeconds when invoking the launcher.
$DefaultStartupTimeoutSeconds = 90

# EDIT HERE: Frontend build and deployment locations.
# $WebDir is the Jaspr project. The build output is always
# <WebDir>\build\jaspr. The DEPLOYMENT directory is NOT set here: it comes from
# SITEWISE_FRONTEND_DIST in the selected profile, so that the directory the
# server reads and the directory the launcher deploys to cannot drift apart.
$WebDir = 'fyp_jaspr_web'
$BuildSubDir = 'build\jaspr'

# EDIT HERE: Flutter mobile connectivity mode.
#   'adb-reverse'  phone reaches this PC at 127.0.0.1:<Port> over USB
#                  (the launcher installs and later removes the rule)
#   'lan'          phone uses this PC's LAN address; requires -AllowLan
# The mode is written into the mobile configuration asset when -Mobile or
# -RunMobile is used, so the app and the server agree on the port.
$MobileHostMode = 'adb-reverse'

# EDIT HERE: Android device selection.
# Leave empty to use the only attached device (or fail when several are
# attached). Set a serial here to make it the default, or pass -DeviceId.
$DefaultDeviceId = ''

# --- Fixed layout. Change only if the repository layout changes. ------------
$PythonRelative       = 'backend\.venv\Scripts\python.exe'
$ServeScriptRelative  = 'backend\tools\serve_profile.py'
$DeployScriptRelative = 'backend\tools\deploy_frontend_dist.py'
$MobileAppDir         = 'fyp_mobile_app'
$MobileConfigRelative = 'fyp_mobile_app\assets\config\sitewise_dev.json'
$MobileProvisioner    = 'fyp_mobile_app\tool\ensure_sitewise_dev_config.js'
$KnownProfiles        = @('pg18', 'pg18-demo', 'pg18-preview', 'pg18-prod-rt24', 'dev')

# ============================================================================
# SECTION 2 - Shell setup
# ============================================================================
$ErrorActionPreference = 'Stop'
# pwsh 7.3+ promotes native stderr to a terminating error under 'Stop'. This
# variable is ignored by Windows PowerShell 5.1; the cmd.exe wrapping below is
# what protects this script there.
$PSNativeCommandUseErrorActionPreference = $false

$root = Split-Path -Parent $MyInvocation.MyCommand.Path
$backendDir = Join-Path $root 'backend'
$webDir = Join-Path $root $WebDir
$buildDir = Join-Path $webDir $BuildSubDir
$pythonExe = Join-Path $root $PythonRelative
$serveScript = Join-Path $root $ServeScriptRelative
$deployScript = Join-Path $root $DeployScriptRelative
$mobileConfig = Join-Path $root $MobileConfigRelative

function Step([string]$name) {
    Write-Host ''
    Write-Host "==> $name" -ForegroundColor Cyan
}

function Warn([string]$message) {
    Write-Host "    WARNING: $message" -ForegroundColor Yellow
}

function Ok([string]$message) {
    Write-Host "    $message" -ForegroundColor Green
}

function Stop-Launcher([string]$message) {
    Write-Host ''
    Write-Host "ERROR: $message" -ForegroundColor Red
    Write-Host 'Nothing was started.' -ForegroundColor DarkGray
    exit 1
}

# --- Child process helpers ---------------------------------------------------
# Start-Process is deliberately NOT used here. On Windows PowerShell 5.1 it
# rebuilds the child environment into a case-sensitive dictionary, and an
# environment block that contains both 'HTTPS_PROXY' and 'https_proxy' (Git
# Bash and several IDEs create exactly that) makes it throw
# "Item has already been added". The .NET process API inherits the block as-is,
# so it is unaffected, and it still gives us a PID we own for cleanup.
function New-PythonStartInfo {
    param(
        [string[]]$ArgumentList,
        [string]$WorkingDirectory,
        [bool]$Capture
    )
    $psi = New-Object System.Diagnostics.ProcessStartInfo
    $psi.FileName = $pythonExe
    $quoted = @()
    foreach ($a in $ArgumentList) {
        if ($a -match '\s') { $quoted += ('"' + $a + '"') } else { $quoted += $a }
    }
    $psi.Arguments = ($quoted -join ' ')
    if (-not [string]::IsNullOrWhiteSpace($WorkingDirectory)) {
        $psi.WorkingDirectory = $WorkingDirectory
    }
    $psi.UseShellExecute = $false
    $psi.CreateNoWindow = $true
    $psi.RedirectStandardOutput = $Capture
    $psi.RedirectStandardError = $Capture
    return $psi
}

function Invoke-PythonCapture {
    param([string[]]$ArgumentList, [string]$WorkingDirectory)
    $psi = New-PythonStartInfo -ArgumentList $ArgumentList -WorkingDirectory $WorkingDirectory -Capture $true
    $proc = [System.Diagnostics.Process]::Start($psi)
    $stdout = $proc.StandardOutput.ReadToEnd()
    $stderr = $proc.StandardError.ReadToEnd()
    $proc.WaitForExit()
    return @{ ExitCode = $proc.ExitCode; StdOut = $stdout; StdErr = $stderr }
}

# ============================================================================
# SECTION 3 - Resolve effective configuration (one authoritative value each)
# ============================================================================
if ([string]::IsNullOrWhiteSpace($Profile)) { $Profile = $DefaultProfile }
if ($Port -le 0) { $Port = $DefaultPort }
if ([string]::IsNullOrWhiteSpace($BindHost)) { $BindHost = $DefaultBindHost }
if ($StartupTimeoutSeconds -le 0) { $StartupTimeoutSeconds = $DefaultStartupTimeoutSeconds }
if ([string]::IsNullOrWhiteSpace($DeviceId)) { $DeviceId = $DefaultDeviceId }

if ($AllowLan -and $BindHost -eq '127.0.0.1') { $BindHost = '0.0.0.0' }
if ($RunMobile) { $Mobile = $true }

# The browser-facing host: a wildcard bind is still reached at localhost here.
if ($BindHost -eq '0.0.0.0' -or $BindHost -eq '::') { $browserHost = 'localhost' } else { $browserHost = $BindHost }
$appUrl = "http://{0}:{1}" -f $browserHost, $Port
$loopbackUrl = "http://127.0.0.1:{0}" -f $Port

Write-Host ''
Write-Host 'SiteWise Unified Launcher' -ForegroundColor Cyan
Write-Host ('-' * 58) -ForegroundColor DarkGray
Write-Host ("  Profile : {0}" -f $Profile)
Write-Host ("  Port    : {0}   Bind: {1}" -f $Port, $BindHost)

# ============================================================================
# SECTION 4 - Validate inputs before touching anything
# ============================================================================
Step 'Validate launcher inputs'

if ($KnownProfiles -notcontains $Profile) {
    Stop-Launcher ("unknown profile '{0}'. Known profiles: {1}." -f $Profile, ($KnownProfiles -join ', '))
}
Ok ("profile '{0}' is known" -f $Profile)

if (-not (Test-Path -LiteralPath $pythonExe)) {
    Stop-Launcher ("missing backend virtual environment: $pythonExe`n         Create it with:`n           python -m venv backend/.venv`n           backend\.venv\Scripts\python.exe -m pip install -e backend")
}
Ok 'backend virtual environment present'

if (-not (Test-Path -LiteralPath $serveScript)) {
    Stop-Launcher "missing $serveScript (the profile launcher)."
}

# --- Port conflict -----------------------------------------------------------
# Check every state that actually prevents a bind. A stale build daemon can hold
# a port in 'Bound' state where netstat shows nothing, which surfaces as
# WSAEACCES 10013 from uvicorn rather than a clear message.
Step ("Check that port {0} is free" -f $Port)
$blocking = @(Get-NetTCPConnection -LocalPort $Port -ErrorAction SilentlyContinue |
    Where-Object { $_.State -in 'Listen', 'Bound' })
if ($blocking.Count -gt 0) {
    $holder = $blocking[0]
    $holderName = try {
        (Get-Process -Id $holder.OwningProcess -ErrorAction Stop).ProcessName
    } catch { "PID $($holder.OwningProcess)" }
    Write-Host ''
    Write-Host ("ERROR: port {0} is held in state {1} by {2} (PID {3})." -f `
        $Port, $holder.State, $holderName, $holder.OwningProcess) -ForegroundColor Red
    Write-Host '       This launcher does not stop processes it did not start.' -ForegroundColor DarkGray
    Write-Host ("       Stop that process yourself, or start on another port: .\run-sitewise.ps1 -Port {0}" -f ($Port + 1)) -ForegroundColor DarkGray
    exit 1
}
Ok ("port {0} is free" -f $Port)

# --- Optional dependency install --------------------------------------------
if ($InstallDependencies) {
    Step 'Install backend Python dependencies'
    Push-Location $backendDir
    try {
        & $pythonExe -m pip install -e $backendDir
        if ($LASTEXITCODE -ne 0) { Stop-Launcher 'pip install failed. Read the output above.' }
    } finally { Pop-Location }
    Ok 'dependencies installed'
}

# ============================================================================
# SECTION 5 - Preflight: prove the target before binding a socket
# ============================================================================
Step 'Preflight (database identity, schema, routes, dependencies)'

$serveArgs = @(
    $serveScript,
    '--profile', $Profile,
    '--port', "$Port",
    '--host', $BindHost,
    '--check'
)
if ($AllowLegacyDatabase) { $serveArgs += '--allow-legacy-database' }
# When a rebuild is requested the frontend may legitimately be absent right
# now; it is checked again after the build.
if ($Rebuild) { $serveArgs += '--skip-frontend' }

$preflightResult = Invoke-PythonCapture -ArgumentList $serveArgs -WorkingDirectory $backendDir
$preflightJson = $preflightResult.StdOut
$preflightText = $preflightResult.StdErr

$report = $null
if (-not [string]::IsNullOrWhiteSpace($preflightJson)) {
    try { $report = $preflightJson | ConvertFrom-Json } catch { $report = $null }
}

if ($null -eq $report) {
    Write-Host ''
    Write-Host 'ERROR: the preflight did not return a readable report.' -ForegroundColor Red
    if (-not [string]::IsNullOrWhiteSpace($preflightText)) {
        Write-Host $preflightText -ForegroundColor DarkGray
    }
    Write-Host 'Nothing was started.' -ForegroundColor DarkGray
    exit 1
}

if (-not $report.ok) {
    Write-Host ''
    Write-Host 'REFUSED: the target did not pass verification. Nothing was started.' -ForegroundColor Red
    foreach ($problem in $report.errors) {
        Write-Host ("  - {0}" -f $problem) -ForegroundColor Red
    }
    Write-Host ''
    Write-Host '  The launcher fails closed on purpose: starting against a database that' -ForegroundColor DarkGray
    Write-Host '  lacks the required tables produces a server that answers 500 on every' -ForegroundColor DarkGray
    Write-Host '  research route, which is harder to diagnose than a refusal.' -ForegroundColor DarkGray
    exit 1
}

Ok ("database  : {0}@{1} (PostgreSQL {2})" -f $report.database, $report.db_port, $report.server_major)
Ok ("principal : {0} (M2: {1})" -f $report.principal, $report.m2_principal)
Ok ("routes    : {0} total, M2 {1}, workflow {2}, CQ {3}" -f `
    $report.total_route_count, $report.m2_route_count, $report.workflow_route_count, $report.cq_route_count)
foreach ($warning in $report.warnings) { Warn $warning }

# ============================================================================
# SECTION 6 - Optional frontend rebuild and deployment
# ============================================================================
function Resolve-Dart {
    $fvm = Get-Command fvm -ErrorAction SilentlyContinue
    if ($fvm -and (Test-Path -LiteralPath (Join-Path $root '.fvmrc'))) {
        return @{ Exe = $fvm.Source; Args = @('dart') }
    }
    $pinned = Join-Path $root '.fvm\flutter_sdk\bin\cache\dart-sdk\bin\dart.exe'
    if (Test-Path -LiteralPath $pinned) {
        return @{ Exe = $pinned; Args = @() }
    }
    $dart = Get-Command dart -ErrorAction SilentlyContinue
    if ($dart) {
        return @{ Exe = $dart.Source; Args = @() }
    }
    return $null
}

function Invoke-NpmStep([string]$npmArgs, [string]$label) {
    if (-not (Get-Command npm.cmd -ErrorAction SilentlyContinue)) {
        Warn "$label skipped: npm.cmd is not on PATH"
        return $false
    }
    $toolDir = Join-Path $webDir 'tool'
    # Capture npm's stdout instead of letting it flow out of the function. A
    # native command's output becomes part of the function's return value, so
    # the caller would receive @('...npm output...', $false) -- and a non-empty
    # array is TRUE in PowerShell, which silently turned a failed step into a
    # reported success. stderr is deliberately not redirected: under
    # $ErrorActionPreference='Stop' Windows PowerShell 5.1 turns redirected
    # native stderr into a terminating NativeCommandError.
    $npmOutput = & npm.cmd @($npmArgs.Split(' ') + @('--prefix', $toolDir))
    $npmExit = $LASTEXITCODE
    foreach ($line in @($npmOutput)) {
        if ("$line".Trim()) { Write-Host ("      {0}" -f $line) -ForegroundColor DarkGray }
    }
    if ($npmExit -ne 0) {
        Warn "$label failed (exit $npmExit)"
        return $false
    }
    return $true
}

if ($Rebuild) {
    Step 'Rebuild the Jaspr frontend'

    if (-not (Test-Path -LiteralPath (Join-Path $webDir 'pubspec.yaml'))) {
        Stop-Launcher "missing $webDir\pubspec.yaml"
    }

    # 1. Browser auth assets. They are generated into fyp_jaspr_web/web/ and are
    #    copied into the build by jaspr; a stale copy survives a rebuild.
    Invoke-NpmStep 'run gen-auth-config' 'gen-auth-config' | Out-Null
    Invoke-NpmStep 'run build-auth' 'build-auth' | Out-Null

    # 2. Optional licensed map tiles. The generator writes web/map-config.js and
    #    exits non-zero when no key is configured; that is not an error here.
    $mapConfigSource = Join-Path $webDir 'web\map-config.js'
    if (Invoke-NpmStep 'run gen-map-config' 'gen-map-config') {
        Ok 'map configuration regenerated'
    } else {
        Warn 'map configuration not regenerated; /map-config.js may be missing'
    }

    # 3. Compile. Proxies must be cleared: a loopback interceptor breaks the
    #    build daemon and the failure surfaces as a bare "Compilation failed".
    Step 'Compile with the pinned Dart SDK'
    $dart = Resolve-Dart
    if ($null -eq $dart) {
        Stop-Launcher 'no Dart SDK found. Install FVM (.fvmrc) or put dart on PATH.'
    }
    $savedProxy = @{}
    foreach ($name in @('HTTP_PROXY', 'HTTPS_PROXY', 'http_proxy', 'https_proxy')) {
        $savedProxy[$name] = [Environment]::GetEnvironmentVariable($name, 'Process')
        [Environment]::SetEnvironmentVariable($name, $null, 'Process')
    }
    try {
        Push-Location $webDir
        try {
            $buildArgs = @($dart.Args) + @('run', 'jaspr_cli:jaspr', 'build', '--verbose')
            & $dart.Exe @buildArgs
            if ($LASTEXITCODE -ne 0) { Stop-Launcher "jaspr build failed (exit $LASTEXITCODE). See the verbose output above." }
        } finally { Pop-Location }
    } finally {
        foreach ($name in $savedProxy.Keys) {
            [Environment]::SetEnvironmentVariable($name, $savedProxy[$name], 'Process')
        }
    }

    if (-not (Test-Path -LiteralPath (Join-Path $buildDir 'index.html'))) {
        Stop-Launcher "jaspr build produced no index.html in $buildDir"
    }
    $builtCount = @(Get-ChildItem -LiteralPath $buildDir -Recurse -File).Count
    Ok ("build produced {0} files" -f $builtCount)

    # 4. map-config.js is referenced by index.html but NOT emitted by jaspr
    #    build (it is generated into web/). Copy it across, or a clean deploy
    #    serves a page whose map configuration 404s.
    if (Test-Path -LiteralPath $mapConfigSource) {
        Copy-Item -LiteralPath $mapConfigSource -Destination (Join-Path $buildDir 'map-config.js') -Force
        Ok 'copied map-config.js into the build'
    }

    # 5. Deploy and verify. --no-http because nothing is listening yet; the
    #    socket is verified after startup below.
    Step 'Deploy the build to the profile frontend directory'
    $deployArgs = @($deployScript, '--no-http')
    if ($report.env_file -like '*.env') {
        $deployArgs += @('--env-file',
            (Join-Path $backendDir (Join-Path $DatabaseConfigRelative $report.env_file)))
    }
    & $pythonExe @deployArgs
    if ($LASTEXITCODE -ne 0) {
        Stop-Launcher 'deployment verification failed. The served bundle would not match the build.'
    }
    Ok 'deployment verified against the build'
}

# ============================================================================
# SECTION 7 - Mobile connectivity
# ============================================================================
function Get-Adb {
    $command = Get-Command adb -ErrorAction SilentlyContinue
    if ($command) { return $command.Source }
    $candidate = Join-Path $env:LOCALAPPDATA 'Android\Sdk\platform-tools\adb.exe'
    if (Test-Path -LiteralPath $candidate) { return $candidate }
    return $null
}

# adb writes notices to stderr. Under $ErrorActionPreference='Stop', Windows
# PowerShell 5.1 turns any redirected native-stderr line into a terminating
# NativeCommandError - even through 2>$null. Running adb through cmd.exe keeps
# its stderr inside cmd, so PowerShell only ever receives plain strings, while
# cmd /c still propagates adb's exit code.
function Invoke-Adb([string[]]$AdbArgs, [switch]$MergeStderr) {
    if ($MergeStderr) { $stderrTarget = '2>&1' } else { $stderrTarget = '2>nul' }
    $line = "`"$script:adbExe`" " + ($AdbArgs -join ' ') + " $stderrTarget"
    return @(& cmd.exe /c $line)
}

function Sync-MobileConfig {
    if (-not (Test-Path -LiteralPath $mobileConfig)) {
        $provisioner = Join-Path $root $MobileProvisioner
        if ((Test-Path -LiteralPath $provisioner) -and (Get-Command node -ErrorAction SilentlyContinue)) {
            & node $provisioner
        }
    }
    if (-not (Test-Path -LiteralPath $mobileConfig)) {
        Warn "mobile configuration asset is missing: $MobileConfigRelative"
        Warn 'create it first (node fyp_mobile_app/tool/ensure_sitewise_dev_config.js)'
        return
    }
    try {
        $settings = Get-Content -LiteralPath $mobileConfig -Raw | ConvertFrom-Json
    } catch {
        Warn 'mobile configuration asset is not valid JSON; not modified'
        return
    }
    $desiredBase = "http://127.0.0.1:$Port"
    $changed = $false
    if ([string]$settings.API_BASE_URL -ne $desiredBase) {
        $settings.API_BASE_URL = $desiredBase
        $changed = $true
    }
    if ([string]$settings.WEB_BASE_URL -ne $desiredBase) {
        $settings.WEB_BASE_URL = $desiredBase
        $changed = $true
    }
    if ([string]$settings.API_HOST_MODE -ne $MobileHostMode) {
        $settings.API_HOST_MODE = $MobileHostMode
        $changed = $true
    }
    if ($changed) {
        # UTF-8 without a BOM: a BOM breaks the asset reader. This file holds
        # public values only and is git-ignored.
        $json = $settings | ConvertTo-Json -Depth 6
        $utf8NoBom = New-Object System.Text.UTF8Encoding($false)
        [System.IO.File]::WriteAllText($mobileConfig, $json, $utf8NoBom)
        Ok ("mobile configuration aligned: API_BASE_URL={0}, API_HOST_MODE={1}" -f $desiredBase, $MobileHostMode)
    } else {
        Ok ("mobile configuration already aligned ({0})" -f $desiredBase)
    }
    if ([string]$settings.SITEWISE_DEV_AUTH_BYPASS -eq 'true') {
        Warn 'SITEWISE_DEV_AUTH_BYPASS is true in the mobile asset; authentication is bypassed'
    }
}

$script:adbExe = $null
$reverseInstalled = $false
$mobileState = 'Not requested'

if ($Mobile) {
    Step 'Mobile connectivity (adb reverse)'
    $script:adbExe = Get-Adb
    if (-not $script:adbExe) {
        Write-Host ''
        Write-Host 'ERROR: -Mobile needs adb (Android SDK platform-tools).' -ForegroundColor Red
        Write-Host "       expected: $env:LOCALAPPDATA\Android\Sdk\platform-tools\adb.exe" -ForegroundColor DarkGray
        Write-Host 'Nothing was started.' -ForegroundColor DarkGray
        exit 1
    }

    $deviceLines = @(Invoke-Adb @('devices'))
    $ready = @($deviceLines | Where-Object { $_ -match '^\S+\s+device\s*$' })
    if ($ready.Count -eq 0) {
        Write-Host ''
        Write-Host 'ERROR: no authorized Android device is attached.' -ForegroundColor Red
        Write-Host '       Connect the phone over USB, accept the RSA prompt, then retry.' -ForegroundColor DarkGray
        Write-Host 'Nothing was started.' -ForegroundColor DarkGray
        exit 1
    }
    if ($ready.Count -gt 1 -and [string]::IsNullOrWhiteSpace($DeviceId)) {
        Write-Host ''
        Write-Host 'ERROR: more than one Android device is attached.' -ForegroundColor Red
        foreach ($line in $ready) { Write-Host "       $line" -ForegroundColor DarkGray }
        Write-Host '       Choose one: .\run-sitewise.ps1 -Mobile -DeviceId <serial>' -ForegroundColor DarkGray
        Write-Host 'Nothing was started.' -ForegroundColor DarkGray
        exit 1
    }
    if ([string]::IsNullOrWhiteSpace($DeviceId)) {
        $DeviceId = ($ready[0] -split '\s+')[0]
    }
    Ok ("device: {0}" -f $DeviceId)

    Sync-MobileConfig

    $portArg = "tcp:$Port"
    Invoke-Adb @('-s', $DeviceId, 'reverse', $portArg, $portArg) -MergeStderr |
        ForEach-Object { Write-Host "    adb: $_" -ForegroundColor DarkGray }
    if ($LASTEXITCODE -ne 0) {
        Write-Host ''
        Write-Host ("ERROR: adb reverse {0} failed for device {1}." -f $portArg, $DeviceId) -ForegroundColor Red
        Write-Host 'Nothing was started.' -ForegroundColor DarkGray
        exit 1
    }
    $reverseInstalled = $true
    Ok ("device 127.0.0.1:{0} -> this PC (adb reverse)" -f $Port)
    $mobileState = "Connected (adb reverse, device $DeviceId)"
}

# ============================================================================
# SECTION 8 - Start the server
# ============================================================================
Step ("Start the unified FastAPI server on {0}:{1}" -f $BindHost, $Port)

# The API resolves backend/.env relative to the working directory, so keep the
# working directory at backend/. Local HTTP stays out of any configured proxy.
$env:PYTHONPATH = Join-Path $backendDir 'src'
$env:PYTHONUTF8 = '1'
$env:NO_PROXY = 'localhost,127.0.0.1,::1'
$env:no_proxy = $env:NO_PROXY

$runArgs = @(
    $serveScript,
    '--profile', $Profile,
    '--port', "$Port",
    '--host', $BindHost
)
if ($AllowLegacyDatabase) { $runArgs += '--allow-legacy-database' }

$server = $null
try {
    $serverInfo = New-PythonStartInfo -ArgumentList $runArgs -WorkingDirectory $backendDir -Capture $false
    $server = [System.Diagnostics.Process]::Start($serverInfo)

    # --- Liveness ------------------------------------------------------------
    # /health answers "the process is up". It is deliberately not the readiness
    # probe: a server that is up but cannot reach its database must not be
    # reported as ready.
    $healthUrl = "$loopbackUrl/health"
    $ready = $false
    $deadline = (Get-Date).AddSeconds($StartupTimeoutSeconds)
    while ((Get-Date) -lt $deadline) {
        if ($server.HasExited) {
            Write-Host ''
            Write-Host ("ERROR: the server exited during startup (exit code {0})." -f $server.ExitCode) -ForegroundColor Red
            Write-Host '       Read the Python output above; it names the actual cause.' -ForegroundColor DarkGray
            exit 1
        }
        try {
            $resp = Invoke-WebRequest -Uri $healthUrl -UseBasicParsing -TimeoutSec 2 -ErrorAction Stop
            if ($resp.StatusCode -ge 200 -and $resp.StatusCode -lt 300) { $ready = $true; break }
        } catch {
            # Not up yet; keep probing until the deadline.
        }
        Start-Sleep -Milliseconds 500
    }
    if (-not $ready) {
        Write-Host ''
        Write-Host ("ERROR: /health did not answer within {0}s." -f $StartupTimeoutSeconds) -ForegroundColor Red
        Write-Host '       Common causes: PostgreSQL not running, wrong profile, port taken.' -ForegroundColor DarkGray
        exit 1
    }
    Ok 'liveness: /health answered'

    # --- Readiness -----------------------------------------------------------
    # /api/v1/health touches the database and asks both background workers
    # whether they are alive. Reported as-is: a degraded worker is stated, never
    # rounded up to PASS.
    $readinessText = 'unknown'
    $readinessDetail = ''
    try {
        $readinessResp = Invoke-WebRequest -Uri "$loopbackUrl/api/v1/health" -UseBasicParsing -TimeoutSec 10 -ErrorAction Stop
        $readiness = $readinessResp.Content | ConvertFrom-Json
        if ($readiness.status -eq 'ok') {
            $readinessText = 'PASS'
        } else {
            $readinessText = 'DEGRADED'
            $readinessDetail = "database=$($readiness.database), panorama=$($readiness.panorama_worker), explanation=$($readiness.explanation_worker)"
            if ($readiness.worker_error) { $readinessDetail += ", worker_error=$($readiness.worker_error)" }
            # A worker whose queue table is absent has a live thread but does no
            # work. Naming the table turns "degraded" into something fixable.
            if ($readiness.queue_missing) {
                $missingPairs = @()
                foreach ($p in $readiness.queue_missing.PSObject.Properties) {
                    $missingPairs += ("{0}={1}" -f $p.Name, $p.Value)
                }
                if ($missingPairs.Count -gt 0) {
                    $readinessDetail += ", queue_missing[" + ($missingPairs -join '; ') + "]"
                }
            }
        }
    } catch {
        $readinessText = 'UNVERIFIED'
        $readinessDetail = 'the readiness endpoint did not answer'
    }

    # --- Route registration over HTTP ---------------------------------------
    # 401 proves the route is mounted and guarded. 404 would mean it is absent;
    # 200 would mean authentication was bypassed. Both are failures.
    if ($report.m2_routes -and $report.m2_probe_path) {
        try {
            $probe = Invoke-WebRequest -Uri ("$loopbackUrl" + $report.m2_probe_path) -UseBasicParsing -TimeoutSec 10 -ErrorAction Stop
            $m2State = 'Unexpected 200 (auth bypassed)'
        } catch {
            $status = 0
            if ($_.Exception.Response) { $status = [int]$_.Exception.Response.StatusCode }
            if ($status -eq 401 -or $status -eq 403) {
                $m2State = "Available (auth enforced, HTTP $status)"
            } elseif ($status -eq 404) {
                $m2State = 'Not registered (HTTP 404)'
            } else {
                $m2State = "Unverified (HTTP $status)"
            }
        }
    } else {
        $m2State = 'Not registered in this profile'
    }

    # --- Frontend checksum over the socket ----------------------------------
    # A byte hash of the build proves the build. Only the response body proves
    # what the browser executes, so the comparison is against the socket.
    $servedSha = 'unavailable'
    $frontendPath = [string]$report.frontend.dist
    $deployedBundle = Join-Path $frontendPath 'main.client.dart.js'
    $builtBundle = Join-Path $buildDir 'main.client.dart.js'
    try {
        $servedFile = [System.IO.Path]::GetTempFileName()
        Invoke-WebRequest -Uri "$loopbackUrl/main.client.dart.js" -OutFile $servedFile -UseBasicParsing -TimeoutSec 30 -ErrorAction Stop
        $servedSha = (Get-FileHash -LiteralPath $servedFile -Algorithm SHA256).Hash.ToLower()
        Remove-Item -LiteralPath $servedFile -ErrorAction SilentlyContinue

        if (Test-Path -LiteralPath $deployedBundle) {
            $deployedSha = (Get-FileHash -LiteralPath $deployedBundle -Algorithm SHA256).Hash.ToLower()
            if ($servedSha -ne $deployedSha) {
                Warn 'the served bundle differs from the deployed file on disk'
            }
        }
        if (Test-Path -LiteralPath $builtBundle) {
            $builtSha = (Get-FileHash -LiteralPath $builtBundle -Algorithm SHA256).Hash.ToLower()
            if ($servedSha -ne $builtSha) {
                if ($VerifyFrontend) {
                    Write-Host ''
                    Write-Host 'ERROR: -VerifyFrontend is set and the served bundle is not the current build.' -ForegroundColor Red
                    Write-Host ("       served: {0}" -f $servedSha) -ForegroundColor DarkGray
                    Write-Host ("       build : {0}" -f $builtSha) -ForegroundColor DarkGray
                    Write-Host '       Run with -Rebuild to redeploy, or drop -VerifyFrontend.' -ForegroundColor DarkGray
                    exit 1
                }
                Warn 'the served bundle differs from the current build (run -Rebuild to redeploy)'
            }
        }
    } catch {
        Warn 'the served bundle could not be fetched for verification'
    }

    # ========================================================================
    # SECTION 9 - Startup verification receipt
    # ========================================================================
    Write-Host ''
    Write-Host 'SiteWise Unified Launcher' -ForegroundColor Cyan
    Write-Host ('-' * 58) -ForegroundColor DarkGray
    Write-Host ("Profile        : {0}" -f $Profile)
    Write-Host ("Application    : {0}" -f $appUrl)
    Write-Host ("Database       : {0}" -f $report.database)
    Write-Host ("Database port  : {0}" -f $report.db_port)
    Write-Host ("DB principal   : {0}" -f $report.principal)
    Write-Host ("Frontend       : {0}" -f $frontendPath)
    Write-Host ("Frontend SHA   : {0}" -f $servedSha.Substring(0, [Math]::Min(16, $servedSha.Length)))
    Write-Host ("API readiness  : {0}" -f $readinessText)
    if ($readinessDetail) { Write-Host ("                 {0}" -f $readinessDetail) -ForegroundColor DarkGray }
    Write-Host ("M2 routes      : {0}" -f $m2State)
    if ($report.workflow_routes) {
        $workflowState = "Available ({0} routes)" -f $report.workflow_route_count
    } else {
        $workflowState = 'Not registered in this profile'
    }
    Write-Host ("Workflow routes: {0}" -f $workflowState)
    # Governed features are reported rather than assumed. The profile arms the
    # LLM provider and leaves CQ respondent runtime off; the receipt says so,
    # so nobody discovers it from a 503 or an unexpected outbound request.
    if ($report.tokenharbor_enabled) {
        $providerState = 'ARMED (a call still needs its own authorization receipt)'
    } else {
        $providerState = 'Disarmed (live LLM routes refuse)'
    }
    Write-Host ("LLM provider   : {0}" -f $providerState)
    if ($report.cq_runtime_enabled) {
        $cqRuntimeState = 'ENABLED'
    } else {
        $cqRuntimeState = 'Disabled (respondent route holds)'
    }
    Write-Host ("CQ respondent  : {0}" -f $cqRuntimeState)
    Write-Host ("Mobile         : {0}" -f $mobileState)
    Write-Host ('-' * 58) -ForegroundColor DarkGray
    if ($readinessText -ne 'PASS') {
        Write-Host 'NOTE: readiness is not PASS. Web and mobile keep working; the detail above' -ForegroundColor Yellow
        Write-Host '      names what is unavailable. See TROUBLESHOOTING in Get-Help.' -ForegroundColor Yellow
    }
    Write-Host 'Press Ctrl+C to stop.' -ForegroundColor DarkGray
    Write-Host ''

    if ($OpenBrowser) {
        Start-Process $appUrl | Out-Null
    }

    # ========================================================================
    # SECTION 10 - Optional Flutter launch, then wait
    # ========================================================================
    if ($RunMobile) {
        Step ("Build and launch the Flutter app on {0}" -f $DeviceId)
        $fvm = Get-Command fvm -ErrorAction SilentlyContinue
        Push-Location (Join-Path $root $MobileAppDir)
        try {
            if ($fvm) {
                & $fvm.Source @('flutter', 'run', '-d', $DeviceId)
            } else {
                & flutter run -d $DeviceId
            }
        } finally { Pop-Location }
    } else {
        Wait-Process -Id $server.Id
    }
} finally {
    # --- Cleanup: only what this launcher created ---------------------------
    if ($server -and -not $server.HasExited) {
        Stop-Process -Id $server.Id -Force -ErrorAction SilentlyContinue
    }
    if ($reverseInstalled -and $script:adbExe) {
        Invoke-Adb @('-s', $DeviceId, 'reverse', '--remove', "tcp:$Port") | Out-Null
        Write-Host ("adb reverse tcp:{0} removed" -f $Port) -ForegroundColor DarkGray
    }
    Write-Host 'Server stopped.' -ForegroundColor DarkGray
}
