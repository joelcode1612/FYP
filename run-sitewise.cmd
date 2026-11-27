@echo off
setlocal
REM Unified SiteWise launcher: ONE FastAPI application server, serving both the
REM compiled Jaspr frontend and the REST API.
REM
REM The HTTP port is NOT set here. It comes from $DefaultPort in
REM run-sitewise.ps1 (see "EDIT HERE: Default FastAPI application port") and
REM can be overridden for one run with -Port, e.g.:
REM   .\run-sitewise.cmd -Port 8100
REM
REM Run from the FYP project root:
REM   .\run-sitewise.cmd
REM   .\run-sitewise.cmd -Rebuild -Mobile
cd /d "%~dp0"
powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%~dp0run-sitewise.ps1" %*
exit /b %ERRORLEVEL%
