# Run locally in a private terminal. No key is written to disk or command history.
# The key exists only in this shell and child backend/probe processes.
$privateKey = Read-Host 'TokenHarbor API key (masked; do not paste into chat)' -AsSecureString
$keyPointer = [Runtime.InteropServices.Marshal]::SecureStringToBSTR($privateKey)
try {
    $env:TOKENHARBOR_API_KEY = [Runtime.InteropServices.Marshal]::PtrToStringBSTR($keyPointer)
} finally {
    [Runtime.InteropServices.Marshal]::ZeroFreeBSTR($keyPointer)
    $privateKey.Dispose()
}
Write-Host 'Key configured only in this terminal. Live execution remains disabled.'
Write-Host 'From backend, run .venv\Scripts\python.exe scripts\project1_probe_tokenharbor.py --synthetic-only to test the exact model.'
