@echo off
REM ---------------------------------------------------------------------------
REM Jaspr SSR dev server launcher - this is what `.\serve` resolves to.
REM
REM Use this rather than `dart run jaspr_cli:jaspr serve` directly.
REM
REM Why a .cmd wrapper and why the PowerShell implementation is named
REM `serve.impl.ps1` (not `serve.ps1`):
REM   This machine's LocalMachine execution policy is `AllSigned`, so PowerShell
REM   refuses to load an unsigned local .ps1. PowerShell ALSO resolves a bare
REM   `.\serve` to `serve.ps1` *before* consulting PATHEXT for `serve.cmd`, so
REM   leaving a file called `serve.ps1` next to this wrapper makes the documented
REM   command `.\serve` fail with "not digitally signed". Renaming the
REM   implementation makes `.\serve` resolve to this .cmd, which invokes it with
REM   -ExecutionPolicy Bypass (process-scoped, never a machine-wide change).
REM
REM What it does: serve.impl.ps1 frees ports 8090/5567 (killing only stale Dart
REM `jaspr serve` processes), health-checks the intended FastAPI backend on port
REM 8000 (FYP/backend) and starts it only when needed, regenerates the public
REM auth config/bundle when stale, then starts the SSR server on 8090.
REM It never starts anything from FYP/test.
REM
REM Usage:
REM   .\serve              start (clears the port first)
REM   .\serve -CheckOnly   clear the port and exit without starting
REM   .\serve -NoKill      report what holds the port, change nothing
REM   .\serve -Port 8091   use a different port for this run
REM ---------------------------------------------------------------------------

setlocal
powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0serve.impl.ps1" %*
exit /b %ERRORLEVEL%
