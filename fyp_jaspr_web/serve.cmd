@echo off
REM ---------------------------------------------------------------------------
REM Jaspr dev server launcher.
REM
REM Use this rather than `dart run jaspr_cli:jaspr serve` directly.
REM
REM Why a .cmd wrapper and not just serve.ps1:
REM   This machine's LocalMachine execution policy is `AllSigned`, so PowerShell
REM   refuses to load an unsigned local .ps1 ("cannot be loaded... is not
REM   digitally signed"). A .cmd file has no such restriction, so this wrapper
REM   is what makes the cleanup reachable without weakening a security setting.
REM
REM What it does: serve.ps1 frees the configured port (killing any stale
REM `jaspr serve` left behind by a closed terminal) and then starts the server.
REM
REM Usage:
REM   .\serve              start (clears the port first)
REM   .\serve -CheckOnly   clear the port and exit without starting
REM   .\serve -NoKill      report what holds the port, change nothing
REM   .\serve -Port 8091   use a different port for this run
REM ---------------------------------------------------------------------------

setlocal
powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0serve.ps1" %*
exit /b %ERRORLEVEL%
