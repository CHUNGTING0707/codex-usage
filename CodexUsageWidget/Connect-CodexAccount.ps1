$ErrorActionPreference = 'Stop'
$desktopBin = Join-Path $env:LOCALAPPDATA 'OpenAI\Codex\bin'
$cli = @(Get-ChildItem -Path $desktopBin -Directory -ErrorAction SilentlyContinue |
    ForEach-Object {
        $candidate = Join-Path $_.FullName 'codex.exe'
        if (Test-Path $candidate) { Get-Item $candidate }
    } |
    Sort-Object LastWriteTime -Descending |
    Select-Object -First 1)

if ($cli.Count -eq 0) {
    $command = Get-Command codex -ErrorAction Stop
    $exe = $command.Source
} else {
    $exe = $cli[0].FullName
}

Write-Host 'This opens the official Codex device sign-in flow in your browser.'
Write-Host ("Using: {0}" -f (& $exe --version))
Write-Host 'No API key is required.'
& $exe login --device-auth
Read-Host 'Press Enter to close'
