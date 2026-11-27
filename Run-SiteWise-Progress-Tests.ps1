<#
.SYNOPSIS
    Runs the LLM execution progress verification suite.

.DESCRIPTION
    One command for the whole progress-component verification, so nobody has to
    remember four commands across two directories, the FVM SDK path, the
    disposable-database flag or the backend venv.

    This is a RUNNER. The tests themselves are Dart and Python files, because
    that is the only way to express what they assert: "the rail renders exactly
    four milestone buttons and no 'Dispatched' text" needs the component tree,
    the finders and the renderer. A PowerShell script can start a test run; it
    cannot be one.

    What it runs, in order:

      1. dart analyze lib test                     static analysis
      2. dart test (3 component files)             39 cases
      3. isolated backend runner (4 test files)    50 cases
      4. migration rehearsals (2 scripts)          21 cases  [optional]

    Steps 1-3 are the component verification. Step 4 applies the three proposed
    migrations to a DISPOSABLE database it creates and drops; it never touches a
    runtime database. Skip it with -SkipMigrations when no PostgreSQL 18
    instance is listening on 5544.

.PARAMETER Component
    Run only the frontend steps (1 and 2).

.PARAMETER Backend
    Run only the backend status-projection step (3).

.PARAMETER Migrations
    Run only the migration rehearsals (4).

.PARAMETER SkipMigrations
    Run 1-3 and skip 4. Use when PostgreSQL 18 is not running on 5544.

.PARAMETER SkipAnalyze
    Skip static analysis (step 1). Useful for a fast re-run.

.PARAMETER Database
    The disposable database name the isolated backend runner may write to.
    Default: project1_disposable_app. The runner refuses anything it cannot
    verify as disposable, so this cannot silently point at real data.

    Named -Database rather than -Db because PowerShell reserves 'db' as an
    alias of -Debug, and a parameter with that name fails to bind at parse time.

.EXAMPLE
    powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\Run-SiteWise-Progress-Tests.ps1

    Everything, including the migration rehearsals.

.EXAMPLE
    powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\Run-SiteWise-Progress-Tests.ps1 -Component

    Frontend only. Fastest useful check while editing the component.

.EXAMPLE
    powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\Run-SiteWise-Progress-Tests.ps1 -SkipMigrations

    Component verification without needing PostgreSQL.

.NOTES
    Exit code 0 when every selected step passed, 1 otherwise.
    Nothing here starts the application server; use run-sitewise.ps1 for that.
#>

[CmdletBinding()]
param(
    [switch]$Component,
    [switch]$Backend,
    [switch]$Migrations,
    [switch]$SkipMigrations,
    [switch]$SkipAnalyze,
    # Not '-Db': PowerShell reserves 'db' as an alias of -Debug, and a parameter
    # declared with that name fails to bind before the script body runs.
    [string]$Database = 'project1_disposable_app'
)

$ErrorActionPreference = 'Stop'

# ============================================================
# 1. PATHS
# ============================================================

$root       = $PSScriptRoot
$webDir     = Join-Path $root 'fyp_jaspr_web'
$backendDir = Join-Path $root 'backend'
$py         = Join-Path $backendDir '.venv\Scripts\python.exe'
$isolated   = Join-Path $backendDir 'tools\p2_isolated_test_runner_20261122.py'

$componentTests = @(
    'test/ai_execution_progress_test.dart'
    'test/ai_execution_progress_harness_test.dart'
    'test/ai_execution_progress_styles_test.dart'
)

$backendTests = @(
    'tests/test_ai_execution_status_projection.py'
    'tests/test_objective_proposal_ceiling.py'
    'tests/test_prompt_governance.py'
    'tests/test_qg_objective_identity.py'
)

$rehearsals = @(
    'tools/rehearse_bdj_attempt_identity_20261126.py'
    'tools/rehearse_bdj_write_ack_and_qg_objective_20261126.py'
)

# ============================================================
# 2. OUTPUT HELPERS
# ============================================================

$script:results = @()

function Step([string]$name) {
    Write-Host ""
    Write-Host "==> $name" -ForegroundColor Cyan
}

function Record([string]$name, [string]$status, [string]$detail) {
    $script:results += [pscustomobject]@{
        Step   = $name
        Status = $status
        Detail = $detail
    }
    $colour = 'Green'
    if ($status -eq 'FAIL')    { $colour = 'Red' }
    if ($status -eq 'SKIPPED') { $colour = 'Yellow' }
    Write-Host ("    {0,-8} {1}" -f $status, $detail) -ForegroundColor $colour
}

function ShowTail([string]$text, [int]$lines = 6) {
    $split = $text -split "`r?`n" | Where-Object { $_.Trim() -ne '' }
    if ($split.Count -eq 0) { return }
    $tail = $split | Select-Object -Last $lines
    foreach ($line in $tail) { Write-Host "    | $line" -ForegroundColor DarkGray }
}

# ============================================================
# 3. TOOLCHAIN DISCOVERY
# ============================================================

# The repository pins its SDK with FVM (see .fvmrc). Use the pinned SDK first:
# a different Dart produces different analysis and different test behaviour.
$dart = $null
$fvmDart = Join-Path $root '.fvm\flutter_sdk\bin\dart.bat'
if (Test-Path $fvmDart) {
    $dart = $fvmDart
} else {
    $cmd = Get-Command dart -ErrorAction SilentlyContinue
    if ($cmd) { $dart = $cmd.Source }
}

if (-not $dart) {
    Write-Host "ERROR: no Dart SDK found." -ForegroundColor Red
    Write-Host "  Looked for .fvm\flutter_sdk\bin\dart.bat and 'dart' on PATH." -ForegroundColor Red
    Write-Host "  Run 'fvm install' at the repository root, or put Dart on PATH." -ForegroundColor Red
    exit 1
}

$pyOk = Test-Path $py
$needPy = $false
if (-not ($Component -or $Backend -or $Migrations)) { $needPy = $true }
if ($Backend -or $Migrations) { $needPy = $true }
if ($needPy -and -not $pyOk) {
    Write-Host "ERROR: backend virtualenv not found at $py" -ForegroundColor Red
    Write-Host "  Create it, or run with -Component to skip the backend steps." -ForegroundColor Red
    exit 1
}

Write-Host ""
Write-Host "SiteWise - LLM execution progress verification" -ForegroundColor White
Write-Host "  dart : $dart" -ForegroundColor DarkGray
if ($pyOk) { Write-Host "  python: $py" -ForegroundColor DarkGray }

# ============================================================
# 4. SELECTION
# ============================================================

$runComponent  = $Component  -or -not ($Component -or $Backend -or $Migrations)
$runBackend    = $Backend    -or -not ($Component -or $Backend -or $Migrations)
$runMigrations = $Migrations -or (-not ($Component -or $Backend -or $Migrations))
if ($SkipMigrations) { $runMigrations = $false }

# ============================================================
# 5. STEP 1 - STATIC ANALYSIS
# ============================================================

if ($runComponent -and -not $SkipAnalyze) {
    Step '1. Static analysis  (dart analyze lib test)'
    Push-Location $webDir
    try {
        $out = & $dart analyze lib test 2>&1 | Out-String
        $code = $LASTEXITCODE
    } finally {
        Pop-Location
    }
    if ($code -eq 0) {
        Record 'analyze' 'PASS' 'no issues found'
    } else {
        ShowTail $out 20
        Record 'analyze' 'FAIL' "exit $code"
    }
}

# ============================================================
# 6. STEP 2 - COMPONENT TESTS
# ============================================================

if ($runComponent) {
    Step '2. Component tests  (39 cases, no server, no provider)'
    Push-Location $webDir
    try {
        $out = & $dart test @componentTests 2>&1 | Out-String
        $code = $LASTEXITCODE
    } finally {
        Pop-Location
    }
    $summary = ($out -split "`r?`n" | Where-Object { $_ -match 'All tests passed|Some tests failed' } | Select-Object -Last 1)
    if ($code -eq 0) {
        Record 'component' 'PASS' ($summary -replace '^\s+', '')
    } else {
        ShowTail $out 25
        Record 'component' 'FAIL' "exit $code"
    }
}

# ============================================================
# 7. STEP 3 - BACKEND STATUS PROJECTION
# ============================================================

if ($runBackend) {
    Step '3. Status projection  (50 cases, disposable database)'
    Push-Location $backendDir
    try {
        $runnerArgs = @($isolated, '--db', $Database) + $backendTests
        $out = & $py @runnerArgs 2>&1 | Out-String
        $code = $LASTEXITCODE
    } finally {
        Pop-Location
    }
    # The runner prints a JSON report; surface the pytest line, not the JSON.
    $line = ($out -split "`r?`n" | Where-Object { $_ -match 'passed|failed|error' } | Select-Object -Last 1)
    if ($code -eq 0) {
        Record 'backend' 'PASS' ($line -replace '^\s+|\s+$', '')
    } else {
        ShowTail $out 25
        Record 'backend' 'FAIL' "exit $code"
    }
}

# ============================================================
# 8. STEP 4 - MIGRATION REHEARSALS
# ============================================================

if ($runMigrations) {
    Step '4. Migration rehearsals  (21 cases, disposable database)'

    # Each rehearsal creates and drops its own database. If PostgreSQL 18 is not
    # listening there is nothing to rehearse against, and that is a skip rather
    # than a failure: it says nothing about the migrations.
    $pgUp = $false
    try {
        $probe = New-Object System.Net.Sockets.TcpClient
        $probe.Connect('127.0.0.1', 5544)
        $pgUp = $probe.Connected
        $probe.Close()
    } catch {
        $pgUp = $false
    }

    if (-not $pgUp) {
        Record 'rehearsal' 'SKIPPED' 'no PostgreSQL on 127.0.0.1:5544'
    } else {
        foreach ($script in $rehearsals) {
            $name = Split-Path -Leaf $script
            Push-Location $backendDir
            try {
                $out = & $py $script 2>&1 | Out-String
                $code = $LASTEXITCODE
            } finally {
                Pop-Location
            }
            $line = ($out -split "`r?`n" | Where-Object { $_ -match '^\d+ cases' } | Select-Object -Last 1)
            if ($code -eq 0) {
                Record 'rehearsal' 'PASS' ("$name - " + ($line -replace '^\s+', ''))
            } else {
                ShowTail $out 20
                Record 'rehearsal' 'FAIL' "$name - exit $code"
            }
        }
    }
}

# ============================================================
# 9. SUMMARY
# ============================================================

Write-Host ""
Write-Host "----------------------------------------" -ForegroundColor DarkGray
$script:results | Format-Table -AutoSize | Out-String | Write-Host

$failed = @($script:results | Where-Object { $_.Status -eq 'FAIL' })
if ($failed.Count -gt 0) {
    Write-Host ("FAILED: {0} step(s)" -f $failed.Count) -ForegroundColor Red
    exit 1
}

Write-Host "All selected steps passed." -ForegroundColor Green
Write-Host "Note: browser paint is not verified here. The styles test checks" -ForegroundColor DarkGray
Write-Host "      markup and CSS, not what the browser draws." -ForegroundColor DarkGray
exit 0
