<#
  Diagnoses the widget's official Claude usage lookup. It loads the widget's own
  functions and runs the same steps (including the automatic token refresh), then
  prints what happened. The token itself is never printed.
#>

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest
# Source layout keeps the widget next to development\; the release package keeps it in app\.
$packageRoot = Split-Path $PSScriptRoot -Parent
$widget = Join-Path $packageRoot 'CodexUsageWidget.ps1'
if (-not (Test-Path $widget)) { $widget = Join-Path $packageRoot 'app\CodexUsageWidget.ps1' }
$ast = [System.Management.Automation.Language.Parser]::ParseFile($widget, [ref]$null, [ref]$null)
$ast.FindAll({ $args[0] -is [System.Management.Automation.Language.FunctionDefinitionAst] }, $false) |
    ForEach-Object { . ([scriptblock]::Create($_.Extent.Text)) }
$script:ClaudeCredentialsPath = Join-Path $env:USERPROFILE '.claude\.credentials.json'
$script:ClaudeRefreshBlockedUntil = [DateTime]::MinValue
$script:ClaudeRefreshBackoffMinutes = 15
$script:ClaudeOAuthClientId = '9d1c250a-e61b-44d9-88ed-5944d1962f5e'
$script:ClaudeTokenUrls = @('https://platform.claude.com/v1/oauth/token', 'https://console.anthropic.com/v1/oauth/token')
[Net.ServicePointManager]::SecurityProtocol = [Net.ServicePointManager]::SecurityProtocol -bor [Net.SecurityProtocolType]::Tls12

function Show-Expiry {
    $oauth = (Read-ClaudeCredentials).claudeAiOauth
    foreach ($name in @('expiresAt', 'refreshTokenExpiresAt')) {
        $property = $oauth.PSObject.Properties[$name]
        if ($null -ne $property -and $property.Value) {
            Write-Host ("{0}: {1}" -f $name, [DateTimeOffset]::FromUnixTimeMilliseconds([int64]$property.Value).ToLocalTime())
        }
        else { Write-Host "${name}: (none)" }
    }
}

Write-Host "Now: $([DateTimeOffset]::Now)"
Write-Host '--- Before ---'
Show-Expiry
Write-Host '--- Official usage lookup (same as the widget) ---'
try {
    $usage = Get-ClaudeOfficialUsage
    foreach ($name in @('five_hour', 'seven_day')) {
        $window = Get-OfficialWindow $usage $name
        if ($null -eq $window) { Write-Host "${name}: (none)" }
        else { Write-Host ("{0}: used {1}%  resets {2}" -f $name, $window.Used, $window.ResetsAt.ToLocalTime()) }
    }
    Write-Host 'Result: OK'
}
catch { Write-Host ("Result: FAILED - {0}" -f $_.Exception.Message) }
Write-Host '--- After ---'
Show-Expiry
