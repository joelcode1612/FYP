$ErrorActionPreference = 'Stop'
$repo = (Resolve-Path (Join-Path $PSScriptRoot '..\..\..')).Path
$python = Join-Path $repo 'backend\.venv\Scripts\python.exe'
$backend = Join-Path $repo 'backend'
$evidence = Join-Path $repo 'artifacts\cp12_20261118'
$tag = Get-Date -Format 'yyyyMMdd_HHmmss'
$activated = $false
$stopped = $false
$failure = $null
Set-Location $repo
try {
    $targetFile = Join-Path $evidence 'live_capture_targets.json'
    if (Test-Path $targetFile) { throw 'Capture target file already exists; refusing to overwrite evidence' }
    $listener = @(Get-NetTCPConnection -LocalPort 8090 -State Listen -ErrorAction Stop)
    if ($listener.Count -ne 1 -or $listener[0].LocalAddress -ne '127.0.0.1') { throw 'Unexpected port 8090 listener' }
    $proc = Get-CimInstance Win32_Process -Filter "ProcessId = $($listener[0].OwningProcess)"
    if (-not $proc -or $proc.CommandLine -notlike "*$python*" -or $proc.CommandLine -notlike '*-m uvicorn sitewise.main:app*--port 8090*') { throw 'Unexpected FastAPI command; refusing to stop it' }
    Stop-Process -Id $proc.ProcessId -ErrorAction Stop
    $stopped = $true
    $backupOutput = & $python (Join-Path $PSScriptRoot 'write_paused_backup.py')
    if ($LASTEXITCODE -ne 0) { throw 'Write-paused backup failed' }
    $backup = ($backupOutput -join "`n") | ConvertFrom-Json
    if ($backup.status -ne 'PASS') { throw 'Write-paused backup did not pass' }
    $backupOutput | Set-Content -Encoding utf8 (Join-Path $evidence "activation_backup_$tag.log")
    & $python (Join-Path $PSScriptRoot 'activate_option_b.py') $backup.evidence
    if ($LASTEXITCODE -ne 0) { throw 'CP12 activation failed; consult the activation evidence' }
    $activated = $true
    $targets = @{property_id='MD-02521'; marketplace_ids=@('d45366fd-b360-4d49-867a-8b7858b37e5a'); m2_ids=@()}
    $json = $targets | ConvertTo-Json -Depth 4
    [System.IO.File]::WriteAllText($targetFile, $json, [System.Text.UTF8Encoding]::new($false))
}
catch { $failure = $_.Exception.Message }
finally {
    if ($stopped) {
        if ($activated -and -not $failure) {
            $arguments = @((Join-Path $PSScriptRoot 'live_capture.py'))
        } else {
            $arguments = @('-m','uvicorn','sitewise.main:app','--host','127.0.0.1','--port','8090')
        }
        $stdout = Join-Path $evidence "server_${tag}_stdout.log"
        $stderr = Join-Path $evidence "server_${tag}_stderr.log"
        Start-Process -FilePath $python -ArgumentList $arguments -WorkingDirectory $backend -WindowStyle Hidden -RedirectStandardOutput $stdout -RedirectStandardError $stderr | Out-Null
        $healthy = $false
        for ($i = 0; $i -lt 40; $i++) {
            try { $r = Invoke-WebRequest -UseBasicParsing -Uri 'http://127.0.0.1:8090/health' -TimeoutSec 2; if ($r.StatusCode -eq 200) { $healthy = $true; break } } catch {}
            Start-Sleep -Milliseconds 500
        }
        if (-not $healthy) { $failure = "Server did not become healthy; inspect $stderr" }
    }
}
if ($failure) { throw $failure }
Write-Output "Activation and server health passed. Evidence: $evidence\option_b_activation_results.json"
