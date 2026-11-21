param(
    [Parameter(Mandatory=$true)][Guid]$RunId,
    [Parameter(Mandatory=$true)][string]$OutputDirectory
)
$ErrorActionPreference='Stop'
$backendRoot=Split-Path -Parent $PSScriptRoot
& (Join-Path $backendRoot '.venv\Scripts\python.exe') (Join-Path $PSScriptRoot 'read_dss_synthetic_results.py') --run-id $RunId --output $OutputDirectory
if ($LASTEXITCODE -ne 0) { throw 'Read-only Dss verification failed. Inspect the saved result logs.' }
