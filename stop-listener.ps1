$ErrorActionPreference = "Stop"

$needle = "fix-wording-listener.ps1"
$matches = Get-CimInstance Win32_Process |
    Where-Object {
        $_.Name -match "powershell" -and
        $_.CommandLine -and
        $_.CommandLine -like "*$needle*"
    }

if (-not $matches) {
    Write-Host "No LocalWordingFixer listener process found."
    exit 0
}

foreach ($process in $matches) {
    Write-Host "Stopping listener PID $($process.ProcessId)"
    Stop-Process -Id $process.ProcessId -Force
}
