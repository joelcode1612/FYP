@echo off
setlocal
REM Unified SiteWise launcher: ONE FastAPI application server on port 8090,
REM serving both the compiled Jaspr frontend and the REST API.
REM Run from the FYP project root:
REM   .\run-sitewise.cmd
cd /d "%~dp0"
powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%~dp0run-sitewise.ps1" %*
exit /b %ERRORLEVEL%
