@echo off
setlocal
REM SiteWise / Jaspr dev-server launcher for Windows PowerShell.
REM
REM Why this starts a SEPARATE PowerShell window:
REM   If a long-running process is kept inside serve.cmd, Ctrl+C can cause
REM   CMD.EXE to ask "Terminate batch job (Y/N)?" even after Jaspr shuts down.
REM   Launching the server in its own PowerShell console lets this .cmd finish
REM   immediately, so the outer batch job is no longer present during shutdown.
REM
REM Usage (from the project folder):
REM   .\serve             Start the dev server in a new PowerShell window.
REM   .\serve -Port 8091  Use another port.
REM   .\serve -CheckOnly  Run the diagnostic in a new PowerShell window.
REM
REM To keep output in your CURRENT console instead, bypass CMD.EXE entirely:
REM   powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\serve.impl.ps1
REM
REM The implementation still starts FastAPI if required, generates auth assets,
REM frees stale Jaspr ports, and runs jaspr serve.

set "IMPLEMENTATION=%~dp0serve.impl.ps1"
if not exist "%IMPLEMENTATION%" (
    echo ERROR: Missing "%IMPLEMENTATION%"
    exit /b 1
)

echo Starting SiteWise in a separate PowerShell window...
echo Stop the Jaspr server with Ctrl+C INSIDE that window.
start "SiteWise Jaspr development server" powershell.exe -NoProfile -ExecutionPolicy Bypass -NoExit -File "%IMPLEMENTATION%" %*
if errorlevel 1 (
    echo ERROR: Unable to launch the SiteWise PowerShell process.
    exit /b 1
)
exit /b 0
