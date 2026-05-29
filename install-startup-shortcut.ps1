param(
    [switch]$DisableLogging,
    [switch]$ShowWindow
)

$ErrorActionPreference = "Stop"

$ScriptDir = if ($PSScriptRoot) { $PSScriptRoot } else { Split-Path -Parent $MyInvocation.MyCommand.Path }
$ListenerPath = Join-Path $ScriptDir "fix-wording-listener.ps1"
$StartupFolder = [Environment]::GetFolderPath("Startup")
$ShortcutPath = Join-Path $StartupFolder "LocalWordingFixer Listener.lnk"

if (-not (Test-Path -LiteralPath $ListenerPath)) {
    throw "Listener script not found: $ListenerPath"
}

$shell = New-Object -ComObject WScript.Shell
$shortcut = $shell.CreateShortcut($ShortcutPath)
$shortcut.TargetPath = "powershell.exe"

$listenerArgs = @("-NoProfile", "-ExecutionPolicy", "Bypass", "-STA", "-WindowStyle", "Hidden", "-File", "`"$ListenerPath`"")
if ($DisableLogging) {
    $listenerArgs += "-DisableLogging"
}
if ($ShowWindow) {
    $listenerArgs += "-ShowWindow"
}

$shortcut.Arguments = $listenerArgs -join " "
$shortcut.WorkingDirectory = $ScriptDir
$shortcut.WindowStyle = 7
$shortcut.Description = "Start LocalWordingFixer global hotkey listener"
$shortcut.Save()

Write-Host "Created startup shortcut:"
Write-Host $ShortcutPath
Write-Host ""
Write-Host "Target:"
Write-Host "powershell.exe $($shortcut.Arguments)"
