@echo off
setlocal
REM Retired Jaspr SSR launcher: forward to the unified FastAPI :8090 server.
REM This command NEVER starts a separate Jaspr server or port 8000 API.
echo SiteWise: using unified FastAPI launcher on port 8090.
call "%~dp0..\run-sitewise.cmd" %*
exit /b %ERRORLEVEL%
