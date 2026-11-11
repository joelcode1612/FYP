<#
.SYNOPSIS
    Turn the development authentication bypass ON or OFF for both apps.

.DESCRIPTION
    -Disable (default) makes the app require a normal Supabase sign-in again:
       * Mobile: sets SITEWISE_DEV_AUTH_BYPASS=false in fyp_mobile_app/config/dev.env
       * Web:    rebuilds fyp_jaspr_web WITHOUT the dart-define, so the bypass
                code is tree-shaken out of the compiled client JS entirely.
    -Enable does the opposite and rebuilds the web with the define.

    This script only changes LOCAL DEVELOPMENT artefacts. Release builds are
    always protected (mobile gates on kDebugMode; web needs an explicit define).
    The FastAPI backend is never modified - /api/v1/* stays authenticated.

    IMPORTANT: these are COMPILE-TIME defines. After running this script you
    must STOP and RE-RUN the Flutter app, and hard-refresh the browser
    (Ctrl+F5) or restart run-sitewise.cmd. Editing dev.env alone does nothing
    to an already-running app.

.EXAMPLE
    .\toggle-dev-auth.ps1 -Disable
.EXAMPLE
    .\toggle-dev-auth.ps1 -Enable
#>
[CmdletBinding()]
param(
    [switch]$Enable,
    [switch]$Disable
)

$ErrorActionPreference = 'Stop'

if ($Enable -and $Disable) { throw 'Choose either -Enable or -Disable, not both.' }
if (-not $Enable -and -not $Disable) { $Disable = $true }  # safest default

$root = Split-Path -Parent $MyInvocation.MyCommand.Path
$envFile = Join-Path $root 'fyp_mobile_app/config/dev.env'
$webDir = Join-Path $root 'fyp_jaspr_web'
# Use the real Windows executable. `C:\src\flutter\bin\dart` is a *bash*
# launcher (and `dart.bat` needs cmd.exe); neither starts reliably from
# PowerShell. This is the pinned Flutter 3.44.6 / Dart 3.12.2 SDK.
$sdkDart = 'C:\src\flutter\bin\cache\dart-sdk\bin\dart.exe'

if (-not (Test-Path -LiteralPath $envFile)) { throw "Missing $envFile" }
if (-not (Test-Path -LiteralPath $sdkDart)) { throw "Missing pinned SDK: $sdkDart" }

$value = if ($Enable) { 'true' } else { 'false' }
$verb = if ($Enable) { 'ENABLING' } else { 'DISABLING' }
Write-Host "=== $verb dev auth bypass ===" -ForegroundColor Cyan

# --- 1. Mobile: rewrite the define in dev.env (compile-time, debug only) ----
$lines = Get-Content -LiteralPath $envFile
$updated = @()
$found = $false
foreach ($line in $lines) {
    if ($line -match '^\s*SITEWISE_DEV_AUTH_BYPASS\s*=') {
        $updated += "SITEWISE_DEV_AUTH_BYPASS=$value"
        $found = $true
    } else {
        $updated += $line
    }
}
if (-not $found) { $updated += "SITEWISE_DEV_AUTH_BYPASS=$value" }
# Write UTF-8 WITHOUT a BOM: `Set-Content -Encoding utf8` on Windows
# PowerShell 5.1 emits a BOM, which breaks `--dart-define-from-file`.
$utf8NoBom = New-Object System.Text.UTF8Encoding($false)
[System.IO.File]::WriteAllLines($envFile, [string[]]$updated, $utf8NoBom)
Write-Host "  mobile dev.env -> SITEWISE_DEV_AUTH_BYPASS=$value"

# --- 2. Web: rebuild with/without the define -------------------------------
# All four proxy variables point at a local interceptor that breaks the
# build daemon / flutter_tester WebSocket. Clear them for this process only.
'HTTP_PROXY','HTTPS_PROXY','http_proxy','https_proxy' | ForEach-Object {
    Set-Item -Path "Env:$_" -Value '' -ErrorAction SilentlyContinue
    Remove-Item -Path "Env:$_" -ErrorAction SilentlyContinue
}
$env:NO_PROXY = 'localhost,127.0.0.1'
$env:no_proxy = 'localhost,127.0.0.1'

$buildArgs = @('run', 'jaspr_cli:jaspr', 'build')
if ($Enable) { $buildArgs += '--dart-define=SITEWISE_DEV_AUTH_BYPASS=true' }

Push-Location $webDir
try {
    Write-Host "  rebuilding web (this takes 1-2 min)..."
    & $sdkDart @buildArgs
    if ($LASTEXITCODE -ne 0) { throw "jaspr build failed with exit $LASTEXITCODE" }
} finally {
    Pop-Location
}

$js = Join-Path $webDir 'build/jaspr/main.client.dart.js'
$marker = Select-String -LiteralPath $js -Pattern 'dev@localhost' -Quiet -ErrorAction SilentlyContinue
if ($Enable -and -not $marker) { throw 'Build finished but bypass marker missing - define did not reach the client.' }
if ($Disable -and $marker) { throw 'Build finished but bypass marker still present - check the define.' }
Write-Host "  web client JS bypass present: $marker"

Write-Host ""
Write-Host "DONE. Bypass is now $(if ($Enable) { 'ON' } else { 'OFF' })." -ForegroundColor Green
Write-Host "Next: STOP + RE-RUN the Flutter app, and hard-refresh the browser / restart run-sitewise.cmd." -ForegroundColor Yellow
