@echo off
setlocal
REM DEPRECATED legacy two-server launcher (Jaspr SSR :8090 -> FastAPI :8000).
REM SiteWise now runs as ONE FastAPI application server: use .\run-sitewise.cmd.
REM Run from the FYP project root. One terminal, one browser origin.
cd /d "%~dp0"
powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%~dp0run-sitewise-unified.ps1" %*
exit /b %ERRORLEVEL%
