@echo off
rem Live BDJ objective-proposal diagnostic. Safe by default: without --live it
rem only prints the request and sends nothing.
rem   tools\run-bdj-objective-live.cmd            (dry run)
rem   tools\run-bdj-objective-live.cmd --live     (dispatch)
setlocal
cd /d "%~dp0.."
set PYTHONPATH=src
.venv\Scripts\python.exe tools\bdj_objective_proposal_live_20261121.py %*
exit /b %ERRORLEVEL%
