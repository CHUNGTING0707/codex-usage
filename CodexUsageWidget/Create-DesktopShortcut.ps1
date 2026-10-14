$folder = $PSScriptRoot
$shortcutPath = Join-Path $folder 'Codex Usage Widget.lnk'
$launcher = Join-Path $folder 'Start-CodexUsageWidget.exe'
$icon = Join-Path $folder 'CodexUsageWidget.ico'

$shell = New-Object -ComObject WScript.Shell
$shortcut = $shell.CreateShortcut($shortcutPath)
$shortcut.TargetPath = $launcher
$shortcut.Arguments = ''
$shortcut.WorkingDirectory = $folder
$shortcut.IconLocation = $icon + ',0'
$shortcut.Description = 'Show Codex usage remaining'
$shortcut.Save()
Write-Output $shortcutPath
