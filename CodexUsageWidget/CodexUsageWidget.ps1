<#
  Codex Usage Widget
  A local, always-on-top WPF display for the authenticated Codex rate limits.
  It uses `codex app-server` and only calls account/rateLimits/read.

  It also shows Claude Code usage, computed from the local session logs in
  %USERPROFILE%\.claude\projects (*.jsonl). No network call and no credentials
  are used for the Claude section; optional token limits come from
  ClaudeUsageConfig.json next to this script.
#>

[CmdletBinding()]
param(
    [ValidateRange(30, 3600)]
    [int]$RefreshSeconds = 120
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

Add-Type -AssemblyName PresentationFramework, PresentationCore, WindowsBase, Microsoft.VisualBasic

$script:AppDir = $PSScriptRoot
$script:AppServer = $null
$script:RequestId = 0

function Get-CodexCommand {
    $desktopBin = Join-Path $env:LOCALAPPDATA 'OpenAI\Codex\bin'
    $desktopCli = @(Get-ChildItem -Path $desktopBin -Directory -ErrorAction SilentlyContinue |
        ForEach-Object {
            $candidate = Join-Path $_.FullName 'codex.exe'
            if (Test-Path $candidate) { Get-Item $candidate }
        } |
        Sort-Object LastWriteTime -Descending |
        Select-Object -First 1)
    if ($desktopCli.Count -gt 0) { return $desktopCli[0].FullName }

    $command = Get-Command codex -ErrorAction SilentlyContinue
    if (-not $command) {
        throw 'Codex command line tool was not found. Start or install Codex Desktop first.'
    }
    return $command.Source
}

function Send-RpcMessage([hashtable]$Message) {
    $json = $Message | ConvertTo-Json -Depth 12 -Compress
    $script:AppServer.StandardInput.WriteLine($json)
    $script:AppServer.StandardInput.Flush()
}

function Read-RpcResponse([int]$ExpectedId, [int]$TimeoutMs = 10000) {
    $deadline = [DateTime]::UtcNow.AddMilliseconds($TimeoutMs)
    while ([DateTime]::UtcNow -lt $deadline) {
        $remaining = [Math]::Max(1, [int]($deadline - [DateTime]::UtcNow).TotalMilliseconds)
        $task = $script:AppServer.StandardOutput.ReadLineAsync()
        if (-not $task.Wait($remaining)) { break }
        $line = $task.Result
        if ([string]::IsNullOrWhiteSpace($line)) { continue }
        try { $message = $line | ConvertFrom-Json } catch { continue }
        # Notifications such as account/rateLimits/updated have no JSON-RPC id.
        # Ignore them here; this function waits only for the matching response.
        $responseId = $message.PSObject.Properties['id']
        if ($null -ne $responseId -and [int]$responseId.Value -eq $ExpectedId) {
            $responseError = $message.PSObject.Properties['error']
            if ($null -ne $responseError) {
                throw ("Codex App Server error: {0}" -f ($responseError.Value | ConvertTo-Json -Compress))
            }
            $responseResult = $message.PSObject.Properties['result']
            if ($null -eq $responseResult) { throw 'Codex App Server returned a response with no result.' }
            return $responseResult.Value
        }
    }
    throw 'Timed out waiting for Codex App Server. Confirm that Codex Desktop is signed in.'
}

function Start-AppServer {
    if ($script:AppServer -and -not $script:AppServer.HasExited) { return }

    $psi = [System.Diagnostics.ProcessStartInfo]::new()
    $psi.FileName = Get-CodexCommand
    $psi.Arguments = 'app-server --stdio'
    $psi.UseShellExecute = $false
    $psi.RedirectStandardInput = $true
    $psi.RedirectStandardOutput = $true
    $psi.RedirectStandardError = $true
    $psi.CreateNoWindow = $true

    $script:AppServer = [System.Diagnostics.Process]::new()
    $script:AppServer.StartInfo = $psi
    if (-not $script:AppServer.Start()) { throw 'Could not start Codex App Server.' }

    $script:RequestId = 1
    Send-RpcMessage @{ method = 'initialize'; id = $script:RequestId; params = @{ clientInfo = @{ name = 'codex_usage_widget'; title = 'Codex Usage Widget'; version = '1.0.0' } } }
    [void](Read-RpcResponse -ExpectedId $script:RequestId)
    Send-RpcMessage @{ method = 'initialized'; params = @{} }
}

function Get-UsageLimits {
    Start-AppServer
    $script:RequestId++
    Send-RpcMessage @{ method = 'account/rateLimits/read'; id = $script:RequestId; params = @{} }
    return Read-RpcResponse -ExpectedId $script:RequestId
}

function Get-RemainingText($Window) {
    if ($null -eq $Window) { return '-' }
    $left = [Math]::Max(0, 100 - [double]$Window.usedPercent)
    return ('{0:0}%' -f $left)
}

function Get-ResetText($Window) {
    if ($null -eq $Window -or $null -eq $Window.resetsAt) { return 'Reset time unavailable' }
    $reset = [DateTimeOffset]::FromUnixTimeSeconds([int64]$Window.resetsAt).ToLocalTime()
    return Format-ResetSpan ($reset - [DateTimeOffset]::Now)
}

function Format-ResetSpan([TimeSpan]$Span) {
    if ($Span.TotalSeconds -le 0) { return 'Resetting now' }
    if ($Span.TotalDays -ge 1) { return ('Resets in {0}d {1}h' -f [Math]::Floor($Span.TotalDays), $Span.Hours) }
    return ('Resets in {0}h {1}m' -f $Span.Hours, $Span.Minutes)
}

# ---------------------------------------------------------------------------
# Claude official usage (the numbers on Claude's Settings > Usage page)
# Uses the Claude Code CLI login in %USERPROFILE%\.claude\.credentials.json.
# This endpoint is not publicly documented, so any failure falls back to the
# local log estimate below.
# ---------------------------------------------------------------------------

$script:ClaudeCredentialsPath = Join-Path $env:USERPROFILE '.claude\.credentials.json'
[Net.ServicePointManager]::SecurityProtocol = [Net.ServicePointManager]::SecurityProtocol -bor [Net.SecurityProtocolType]::Tls12

# Appends one line per state change to ClaudeUsage.log next to the script (repeats of
# the same message are skipped), so failures can be diagnosed without the tooltip.
# Messages never include token values.
$script:ClaudeLastLogMessage = $null
function Write-ClaudeLog([string]$Message) {
    # Logging must never break a refresh, so everything (including the lookups
    # below, which fail under StrictMode when loaded outside the widget) is guarded.
    try {
        if ($Message -eq $script:ClaudeLastLogMessage) { return }
        $script:ClaudeLastLogMessage = $Message
        $path = Join-Path $script:AppDir 'ClaudeUsage.log'
        if ((Test-Path $path) -and (Get-Item $path).Length -gt 512KB) { Remove-Item $path -Force }
        Add-Content -Path $path -Encoding UTF8 -Value ('{0:yyyy-MM-dd HH:mm:ss}  {1}' -f [DateTime]::Now, $Message)
    }
    catch { }
}

function Read-ClaudeCredentials {
    if (-not (Test-Path $script:ClaudeCredentialsPath)) { throw 'Claude login not found. Run claude once to sign in.' }
    $json = [IO.File]::ReadAllText($script:ClaudeCredentialsPath, [Text.Encoding]::UTF8) | ConvertFrom-Json
    $oauth = $json.PSObject.Properties['claudeAiOauth']
    if ($null -eq $oauth -or $null -eq $oauth.Value.PSObject.Properties['accessToken']) { throw 'Claude login has no OAuth token. Run claude once to sign in.' }
    return $json
}

# When the access token expires (about every 8 hours), let the official Claude Code
# CLI renew it: it refreshes the login before sending a request and saves it to
# .credentials.json. Refreshing directly from the widget is rejected with HTTP 429.
# The request is a one-word Haiku reply, so it uses a negligible amount of usage.
$script:ClaudeRefreshBlockedUntil = [DateTime]::MinValue
$script:ClaudeRefreshBackoffMinutes = 15

function Get-ClaudeCliPath {
    $local = Join-Path $env:USERPROFILE '.local\bin\claude.exe'
    if (Test-Path $local) { return $local }
    $command = Get-Command claude -ErrorAction SilentlyContinue
    if ($command) { return $command.Source }
    return $null
}

function Update-ClaudeToken($Credentials) {
    # After a failed renewal, wait before trying again (15 min, doubling up to 4 h).
    if ([DateTime]::Now -lt $script:ClaudeRefreshBlockedUntil) {
        throw ('Claude login expired. Next automatic retry at {0:HH:mm}; running claude once fixes it sooner.' -f $script:ClaudeRefreshBlockedUntil)
    }
    $cli = Get-ClaudeCliPath
    if (-not $cli) { throw 'Claude login expired and the claude command line tool was not found. Run claude once.' }

    $detail = ''
    try {
        $psi = [System.Diagnostics.ProcessStartInfo]::new()
        $psi.FileName = $cli
        $psi.Arguments = '-p "Reply with just: ok" --model haiku'
        $psi.WorkingDirectory = $script:AppDir
        $psi.UseShellExecute = $false
        $psi.CreateNoWindow = $true
        $psi.RedirectStandardOutput = $true
        $psi.RedirectStandardError = $true
        $process = [System.Diagnostics.Process]::Start($psi)
        $stdout = $process.StandardOutput.ReadToEndAsync()
        $stderr = $process.StandardError.ReadToEndAsync()
        if (-not $process.WaitForExit(90000)) { $process.Kill(); $detail = 'claude CLI timed out' }
        else {
            $errorText = $stderr.Result.Trim()
            $detail = "claude CLI exit $($process.ExitCode)" + $(if ($errorText) { ': ' + ($errorText -split "`n")[0] } else { '' })
        }
    }
    catch { $detail = 'claude CLI failed to start: ' + $_.Exception.Message }

    # The CLI can exit non-zero (e.g. its own request was throttled) after it has
    # already saved the renewed login, and the save can land a moment after exit,
    # so judge success by the token expiry and re-check a few times.
    $validAfter = [DateTimeOffset]::UtcNow.AddMinutes(2).ToUnixTimeMilliseconds()
    $expiresAt = [long]0
    for ($check = 0; $check -lt 5; $check++) {
        if ($check -gt 0) { Start-Sleep -Seconds 2 }
        $renewed = Read-ClaudeCredentials
        if ($renewed.claudeAiOauth.PSObject.Properties['expiresAt']) { $expiresAt = [long]$renewed.claudeAiOauth.expiresAt }
        if ($expiresAt -gt $validAfter) { break }
    }
    if ($expiresAt -le $validAfter) {
        $script:ClaudeRefreshBlockedUntil = [DateTime]::Now.AddMinutes($script:ClaudeRefreshBackoffMinutes)
        $script:ClaudeRefreshBackoffMinutes = [Math]::Min(240, $script:ClaudeRefreshBackoffMinutes * 2)
        throw "Claude login expired and renewal via the claude CLI failed ($detail). Run claude once, or /login if that fails."
    }
    $script:ClaudeRefreshBackoffMinutes = 15
    Write-ClaudeLog 'Token renewed via claude CLI'
    $Credentials.claudeAiOauth.accessToken = $renewed.claudeAiOauth.accessToken
    $Credentials.claudeAiOauth.expiresAt = $expiresAt
}

function Get-ClaudeOfficialUsage {
    $credentials = Read-ClaudeCredentials
    $expiresAt = [long]0
    if ($credentials.claudeAiOauth.PSObject.Properties['expiresAt']) { $expiresAt = [long]$credentials.claudeAiOauth.expiresAt }
    if ($expiresAt -gt 0 -and $expiresAt -lt [DateTimeOffset]::UtcNow.AddMinutes(2).ToUnixTimeMilliseconds()) {
        Update-ClaudeToken $credentials
    }

    for ($attempt = 0; $attempt -lt 2; $attempt++) {
        try {
            return Invoke-RestMethod -Uri 'https://api.anthropic.com/api/oauth/usage' -TimeoutSec 15 -Headers @{
                Authorization    = "Bearer $($credentials.claudeAiOauth.accessToken)"
                'anthropic-beta' = 'oauth-2025-04-20'
            }
        }
        catch {
            $status = 0
            if ($_.Exception.PSObject.Properties['Response'] -and $_.Exception.Response) { $status = [int]$_.Exception.Response.StatusCode }
            if ($status -ne 401 -or $attempt -gt 0) { throw ('Claude usage request failed: ' + $_.Exception.Message) }
            Update-ClaudeToken $credentials
        }
    }
}

function Get-OfficialWindow($Usage, [string]$Name) {
    $property = $Usage.PSObject.Properties[$Name]
    if ($null -eq $property -or $null -eq $property.Value) { return $null }
    $used = $property.Value.PSObject.Properties['utilization']
    if ($null -eq $used -or $null -eq $used.Value) { return $null }
    $resetsAt = $null
    $reset = $property.Value.PSObject.Properties['resets_at']
    if ($null -ne $reset -and $reset.Value) {
        $resetsAt = [DateTimeOffset]::Parse([string]$property.Value.resets_at, [Globalization.CultureInfo]::InvariantCulture)
    }
    return @{ Used = [double]$used.Value; ResetsAt = $resetsAt }
}

function Set-OfficialRow($TextBlock, $Bar, $Window, [string]$Label) {
    if ($null -eq $Window) {
        $TextBlock.Text = '-'; $TextBlock.ToolTip = $null; $Bar.Value = 0; $Bar.Visibility = 'Visible'
        return
    }
    $left = [Math]::Max(0, 100 - $Window.Used)
    $TextBlock.Text = ('{0:0}%' -f $left)
    $TextBlock.ToolTip = if ($null -ne $Window.ResetsAt) { "$Label " + (Format-ResetSpan ($Window.ResetsAt - [DateTimeOffset]::Now)) } else { $null }
    $Bar.Value = $left
    $Bar.Visibility = 'Visible'
}

# ---------------------------------------------------------------------------
# Claude Code usage (local session logs) - fallback estimate
# ---------------------------------------------------------------------------

$script:ClaudeLogRoot = Join-Path $env:USERPROFILE '.claude\projects'
$script:ClaudeFileOffsets = @{}   # log file path -> bytes already parsed
$script:ClaudeEntries = @{}       # "messageId:requestId" -> @{ Time; Tokens }

function Get-ClaudeConfig {
    # weeklyResetDayOfWeek (0 = Sunday ... 6 = Saturday) and weeklyResetHour (local time)
    # match the weekly reset shown on Claude's usage page; -1 means a rolling 7 days.
    $config = @{ fiveHourTokenLimit = [long]0; weeklyTokenLimit = [long]0; weeklyResetDayOfWeek = [long]-1; weeklyResetHour = [long]0 }
    $path = Join-Path $script:AppDir 'ClaudeUsageConfig.json'
    if (Test-Path $path) {
        $json = Get-Content -Path $path -Raw -Encoding UTF8 | ConvertFrom-Json
        foreach ($name in @('fiveHourTokenLimit', 'weeklyTokenLimit', 'weeklyResetDayOfWeek', 'weeklyResetHour')) {
            $property = $json.PSObject.Properties[$name]
            if ($null -ne $property -and $null -ne $property.Value) { $config[$name] = [long]$property.Value }
        }
    }
    return $config
}

function Get-JsonNumber([string]$Text, [string]$Name) {
    $match = [regex]::Match($Text, '"' + $Name + '":(\d+)')
    if ($match.Success) { return [long]$match.Groups[1].Value }
    return [long]0
}

function Add-ClaudeLogLines([string]$Text) {
    foreach ($line in $Text.Split("`n")) {
        if ($line.IndexOf('"type":"assistant"') -lt 0) { continue }
        # Escaped JSON inside message text never matches '"usage":{', so this
        # locates the real usage object of the assistant message.
        $usageIndex = $line.IndexOf('"usage":{')
        if ($usageIndex -lt 0) { continue }
        $usage = $line.Substring($usageIndex)

        $timeMatch = [regex]::Match($line, '"timestamp":"([^"]+)"')
        if (-not $timeMatch.Success) { continue }
        $time = [DateTime]::Parse($timeMatch.Groups[1].Value, [Globalization.CultureInfo]::InvariantCulture,
            [Globalization.DateTimeStyles]::AdjustToUniversal)

        # One API response is written as several lines (one per content block);
        # message id + request id de-duplicates them.
        $messageId = [regex]::Match($line, '"id":"(msg_[^"]+)"').Groups[1].Value
        $requestId = [regex]::Match($line, '"requestId":"([^"]+)"').Groups[1].Value
        $key = if ($messageId -or $requestId) { "${messageId}:${requestId}" } else { [guid]::NewGuid().ToString() }

        # Cache reads are excluded: they are re-sent context, not new work.
        $tokens = (Get-JsonNumber $usage 'input_tokens') +
                  (Get-JsonNumber $usage 'cache_creation_input_tokens') +
                  (Get-JsonNumber $usage 'output_tokens')
        $script:ClaudeEntries[$key] = @{ Time = $time; Tokens = $tokens }
    }
}

function Update-ClaudeEntries {
    if (-not (Test-Path $script:ClaudeLogRoot)) { throw 'Claude Code logs were not found in %USERPROFILE%\.claude\projects.' }
    $cutoff = [DateTime]::UtcNow.AddDays(-8)
    $files = Get-ChildItem -Path $script:ClaudeLogRoot -Recurse -Filter '*.jsonl' -File -ErrorAction SilentlyContinue
    foreach ($file in $files) {
        if ($file.LastWriteTimeUtc -lt $cutoff) { continue }
        $offset = [long]0
        if ($script:ClaudeFileOffsets.ContainsKey($file.FullName)) { $offset = [long]$script:ClaudeFileOffsets[$file.FullName] }
        if ($file.Length -lt $offset) { $offset = 0 }
        if ($file.Length -eq $offset) { continue }

        # Read only the bytes appended since the last refresh. Claude Code keeps
        # the file open, so share read/write access.
        $stream = [System.IO.File]::Open($file.FullName, 'Open', 'Read', 'ReadWrite')
        try {
            [void]$stream.Seek($offset, 'Begin')
            $count = [int]($stream.Length - $offset)
            $buffer = New-Object byte[] $count
            $read = 0
            while ($read -lt $count) {
                $n = $stream.Read($buffer, $read, $count - $read)
                if ($n -le 0) { break }
                $read += $n
            }
        }
        finally { $stream.Dispose() }
        if ($read -le 0) { continue }

        # Parse complete lines only; a half-written last line waits for the next refresh.
        $lastNewline = [Array]::LastIndexOf($buffer, [byte]10, $read - 1)
        if ($lastNewline -lt 0) { continue }
        Add-ClaudeLogLines ([System.Text.Encoding]::UTF8.GetString($buffer, 0, $lastNewline + 1))
        $script:ClaudeFileOffsets[$file.FullName] = $offset + $lastNewline + 1
    }

    foreach ($key in @($script:ClaudeEntries.Keys)) {
        if ($script:ClaudeEntries[$key].Time -lt $cutoff) { $script:ClaudeEntries.Remove($key) }
    }
}

function Get-WeekStartUtc($Config) {
    $day = [int]$Config.weeklyResetDayOfWeek
    $hour = [int]$Config.weeklyResetHour
    if ($day -lt 0 -or $day -gt 6 -or $hour -lt 0 -or $hour -gt 23) { return [DateTime]::UtcNow.AddDays(-7) }
    # Most recent occurrence of the configured local reset time.
    $nowLocal = [DateTime]::Now
    $start = $nowLocal.Date.AddHours($hour).AddDays(-((([int]$nowLocal.DayOfWeek) - $day + 7) % 7))
    if ($start -gt $nowLocal) { $start = $start.AddDays(-7) }
    return $start.ToUniversalTime()
}

function Get-ClaudeUsage {
    Update-ClaudeEntries
    $now = [DateTime]::UtcNow
    $weekStart = Get-WeekStartUtc (Get-ClaudeConfig)
    # All kept entries (8 days) feed the 5-hour window chain; only those since the
    # weekly reset count toward the weekly total.
    $entries = @($script:ClaudeEntries.Values | Sort-Object { $_.Time })

    $weekly = [long]0
    $blockStart = $null
    $blockTokens = [long]0
    foreach ($entry in $entries) {
        if ($entry.Time -ge $weekStart) { $weekly += $entry.Tokens }
        # Claude's 5-hour window starts at the first message after the previous
        # window ended (rounded down to the hour), like ccusage's session blocks.
        if ($null -eq $blockStart -or $entry.Time -ge $blockStart.AddHours(5)) {
            $blockStart = [DateTime]::new($entry.Time.Year, $entry.Time.Month, $entry.Time.Day, $entry.Time.Hour, 0, 0, [DateTimeKind]::Utc)
            $blockTokens = 0
        }
        $blockTokens += $entry.Tokens
    }

    $fiveHour = [long]0
    $resetsAt = $null
    if ($null -ne $blockStart -and $now -lt $blockStart.AddHours(5)) {
        $fiveHour = $blockTokens
        $resetsAt = $blockStart.AddHours(5)
    }
    return @{ FiveHourTokens = $fiveHour; WeeklyTokens = $weekly; FiveHourResetsAt = $resetsAt }
}

function Format-Tokens([long]$Tokens) {
    if ($Tokens -ge 1000000) { return ('{0:0.0}M' -f ($Tokens / 1000000)) }
    if ($Tokens -ge 1000) { return ('{0:0.0}K' -f ($Tokens / 1000)) }
    return [string]$Tokens
}

function Set-ClaudeRow($TextBlock, $Bar, [long]$Used, [long]$Limit) {
    if ($Limit -gt 0) {
        $left = [Math]::Max(0, 100 - (100.0 * $Used / $Limit))
        $TextBlock.Text = ('{0:0}%' -f $left)
        $TextBlock.ToolTip = ('{0} / {1} tokens' -f (Format-Tokens $Used), (Format-Tokens $Limit))
        $Bar.Value = $left
        $Bar.Visibility = 'Visible'
    }
    else {
        # No limit configured: show tokens used instead of a remaining percentage.
        $TextBlock.Text = ('{0} used' -f (Format-Tokens $Used))
        $TextBlock.ToolTip = '按「校準」輸入 Claude 設定頁顯示的 %，就會改用剩餘 % 顯示'
        $Bar.Visibility = 'Collapsed'
    }
}

function Read-UsedPercent([string]$Prompt) {
    $answer = [Microsoft.VisualBasic.Interaction]::InputBox($Prompt, 'Claude 用量校準', '')
    if ([string]::IsNullOrWhiteSpace($answer)) { return $null }
    $value = 0.0
    if (-not [double]::TryParse($answer.Trim().TrimEnd('%'), [ref]$value) -or $value -le 0 -or $value -gt 100) {
        throw "「$answer」不是 1 到 100 之間的數字。"
    }
    return $value
}

function Save-ClaudeConfig($Config) {
    $path = Join-Path $script:AppDir 'ClaudeUsageConfig.json'
    ([ordered]@{
        fiveHourTokenLimit   = $Config.fiveHourTokenLimit
        weeklyTokenLimit     = $Config.weeklyTokenLimit
        weeklyResetDayOfWeek = $Config.weeklyResetDayOfWeek
        weeklyResetHour      = $Config.weeklyResetHour
    } | ConvertTo-Json) | Set-Content -Path $path -Encoding ASCII
}

# Calibration: the user types the "% used" that Claude's Settings > Usage page
# shows; limit = tokens used locally / that percentage.
function Invoke-ClaudeCalibration {
    $claude = Get-ClaudeUsage
    $config = Get-ClaudeConfig
    $changed = $false

    $percent = Read-UsedPercent ("請打開 Claude 的「設定 → 用量」頁面，`n" +
        "輸入「目前工作階段（5 小時）」已使用的百分比，例如 23。`n`n不想校準這一項就留空。")
    if ($null -ne $percent) {
        if ($claude.FiveHourTokens -le 0) { throw '這台電腦目前的 5 小時區段還沒有 Claude 使用紀錄，請用過 Claude 之後再校準。' }
        $config.fiveHourTokenLimit = [long][Math]::Round($claude.FiveHourTokens * 100 / $percent)
        $changed = $true
    }

    $percent = Read-UsedPercent ("輸入「每週」已使用的百分比，例如 8。`n`n不想校準這一項就留空。")
    if ($null -ne $percent) {
        if ($claude.WeeklyTokens -le 0) { throw '這台電腦最近 7 天還沒有 Claude 使用紀錄，請用過 Claude 之後再校準。' }
        $config.weeklyTokenLimit = [long][Math]::Round($claude.WeeklyTokens * 100 / $percent)
        $changed = $true
    }

    if ($changed) { Save-ClaudeConfig $config }
    return $changed
}

[xml]$xaml = @'
<Window xmlns="http://schemas.microsoft.com/winfx/2006/xaml/presentation"
        xmlns:x="http://schemas.microsoft.com/winfx/2006/xaml"
        Title="Codex Usage" Width="360" SizeToContent="Height" WindowStartupLocation="Manual"
        Left="1200" Top="500" Topmost="True" ResizeMode="NoResize" ShowInTaskbar="True"
        Background="Transparent" AllowsTransparency="True" WindowStyle="None">
  <Border Name="Card" CornerRadius="20" BorderThickness="1" BorderBrush="#5E78A0"
          Background="#EB111A2A" Padding="22">
    <StackPanel>
      <Grid>
        <TextBlock Text="&#21097;&#39192;&#29992;&#37327;" Foreground="White" FontSize="24" FontWeight="SemiBold"/>
        <Button Name="CloseButton" Content="X" FontSize="16" FontWeight="Light"
                Foreground="#D7E6FF" Background="Transparent" BorderThickness="0" Cursor="Hand"
                HorizontalAlignment="Right" VerticalAlignment="Top" Width="28" Height="28" Padding="0"/>
      </Grid>

      <TextBlock Text="Codex" Foreground="#46DBCA" FontSize="17" FontWeight="Bold" Margin="0,16,0,8"/>
      <Grid>
        <TextBlock Text="5&#23567;&#26178;&#29992;&#37327;" Foreground="#D7E6FF" FontSize="14"/>
        <TextBlock Name="PrimaryText" Text="Loading..." Foreground="White" FontSize="14" HorizontalAlignment="Right"/>
      </Grid>
      <ProgressBar Name="PrimaryBar" Height="8" Margin="0,6,0,0" Minimum="0" Maximum="100" Value="0"
                   Foreground="#46DBCA" Background="#344155" BorderThickness="0"/>
      <Grid Margin="0,12,0,0">
        <TextBlock Text="1&#36913;&#29992;&#37327;" Foreground="#D7E6FF" FontSize="14"/>
        <TextBlock Name="SecondaryText" Text="Loading..." Foreground="White" FontSize="14" HorizontalAlignment="Right"/>
      </Grid>
      <ProgressBar Name="SecondaryBar" Height="8" Margin="0,6,0,0" Minimum="0" Maximum="100" Value="0"
                   Foreground="#6F91FF" Background="#344155" BorderThickness="0"/>
      <TextBlock Name="StatusText" Text="Connecting to Codex..." Foreground="#9FB1CC" FontSize="12" Margin="0,8,0,0"
                 TextTrimming="CharacterEllipsis"/>

      <Border Height="1" Background="#344155" Margin="0,14,0,0"/>

      <TextBlock Text="Claude" Foreground="#E8A27C" FontSize="17" FontWeight="Bold" Margin="0,12,0,8"/>
      <Grid>
        <TextBlock Text="5&#23567;&#26178;&#29992;&#37327;" Foreground="#D7E6FF" FontSize="14"/>
        <TextBlock Name="ClaudePrimaryText" Text="Loading..." Foreground="White" FontSize="14" HorizontalAlignment="Right"/>
      </Grid>
      <ProgressBar Name="ClaudePrimaryBar" Height="8" Margin="0,6,0,0" Minimum="0" Maximum="100" Value="0"
                   Foreground="#E8A27C" Background="#344155" BorderThickness="0"/>
      <Grid Margin="0,12,0,0">
        <TextBlock Text="1&#36913;&#29992;&#37327;" Foreground="#D7E6FF" FontSize="14"/>
        <TextBlock Name="ClaudeSecondaryText" Text="Loading..." Foreground="White" FontSize="14" HorizontalAlignment="Right"/>
      </Grid>
      <ProgressBar Name="ClaudeSecondaryBar" Height="8" Margin="0,6,0,0" Minimum="0" Maximum="100" Value="0"
                   Foreground="#C77DFF" Background="#344155" BorderThickness="0"/>

      <Grid Margin="0,8,0,0">
        <Grid.ColumnDefinitions><ColumnDefinition/><ColumnDefinition Width="52"/><ColumnDefinition Width="62"/></Grid.ColumnDefinitions>
        <TextBlock Name="ClaudeStatusText" Text="Reading Claude logs..." Foreground="#9FB1CC" FontSize="12"
                   VerticalAlignment="Center" TextTrimming="CharacterEllipsis"/>
        <Button Name="CalibrateButton" Grid.Column="1" Content="&#26657;&#28310;" Foreground="#F3C9B2" Background="Transparent" BorderBrush="#8A6450"
                BorderThickness="1" Height="20" FontSize="10" Padding="0" Cursor="Hand" HorizontalAlignment="Right" Width="46"/>
        <Button Name="RefreshButton" Grid.Column="2" Content="Refresh" Foreground="#CFE5FF" Background="Transparent" BorderBrush="#58739A"
                BorderThickness="1" Height="20" FontSize="10" Padding="0" Cursor="Hand" HorizontalAlignment="Right" Width="58"/>
      </Grid>
    </StackPanel>
  </Border>
</Window>
'@

$reader = [System.Xml.XmlNodeReader]::new($xaml)
$window = [Windows.Markup.XamlReader]::Load($reader)
$iconPath = Join-Path $PSScriptRoot 'CodexUsageWidget.ico'
if (Test-Path $iconPath) {
    $window.Icon = [System.Windows.Media.Imaging.BitmapFrame]::Create([Uri]$iconPath)
}
$card = $window.FindName('Card')
$primaryText = $window.FindName('PrimaryText')
$secondaryText = $window.FindName('SecondaryText')
$primaryBar = $window.FindName('PrimaryBar')
$secondaryBar = $window.FindName('SecondaryBar')
$statusText = $window.FindName('StatusText')
$claudePrimaryText = $window.FindName('ClaudePrimaryText')
$claudeSecondaryText = $window.FindName('ClaudeSecondaryText')
$claudePrimaryBar = $window.FindName('ClaudePrimaryBar')
$claudeSecondaryBar = $window.FindName('ClaudeSecondaryBar')
$claudeStatusText = $window.FindName('ClaudeStatusText')
$refreshButton = $window.FindName('RefreshButton')
$calibrateButton = $window.FindName('CalibrateButton')
$closeButton = $window.FindName('CloseButton')

$script:UserMoved = $false
$card.Add_MouseLeftButtonDown({
    if ($_.ButtonState -eq 'Pressed') { $window.DragMove(); $script:UserMoved = $true }
})
$closeButton.Add_Click({ $window.Close() })

# The card is taller now and its height follows its content, so keep it anchored
# to the bottom-right corner of the work area until the user drags it elsewhere.
$window.Add_SizeChanged({
    if ($script:UserMoved) { return }
    $area = [System.Windows.SystemParameters]::WorkArea
    $window.Left = $area.Right - $window.ActualWidth - 16
    $window.Top = $area.Bottom - $window.ActualHeight - 16
})

$refreshCodex = {
    try {
        $statusText.Text = 'Updating...'
        $usage = Get-UsageLimits
        $limitGroups = $usage.PSObject.Properties['rateLimitsByLimitId']
        $limits = if ($null -ne $limitGroups -and $null -ne $limitGroups.Value.PSObject.Properties['codex']) {
            $limitGroups.Value.PSObject.Properties['codex'].Value
        } else {
            $usage.PSObject.Properties['rateLimits'].Value
        }
        $primary = $limits.PSObject.Properties['primary'].Value
        $secondaryProperty = $limits.PSObject.Properties['secondary']
        $secondary = if ($null -eq $secondaryProperty) { $null } else { $secondaryProperty.Value }
        $primaryText.Text = Get-RemainingText $primary
        $secondaryText.Text = Get-RemainingText $secondary
        $primaryBar.Value = [Math]::Max(0, 100 - [double]$primary.usedPercent)
        $secondaryBar.Value = if ($null -eq $secondary) { 0 } else { [Math]::Max(0, 100 - [double]$secondary.usedPercent) }
        $statusText.Text = Get-ResetText $primary
        $statusText.ToolTip = $null
    }
    catch {
        $statusText.Text = $_.Exception.Message
        $statusText.ToolTip = $_.Exception.Message
        $statusText.TextWrapping = 'Wrap'
        $primaryText.Text = 'Unavailable'
        $secondaryText.Text = 'Unavailable'
    }
}

# The usage endpoint answers HTTP 429 when polled too often, so query it at most every
# 5 minutes, back off after a 429 (10 min doubling to 60), and in between keep showing
# the last official numbers instead of dropping to the local estimate.
$script:ClaudeOfficialCache = $null   # @{ FiveHour; Weekly; At }
$script:ClaudeOfficialNextQuery = [DateTime]::MinValue
$script:ClaudeOfficialBackoffMinutes = 10

$showOfficialClaude = {
    param($Data, [string]$Note)
    Set-OfficialRow $claudePrimaryText $claudePrimaryBar $Data.FiveHour '5h window'
    Set-OfficialRow $claudeSecondaryText $claudeSecondaryBar $Data.Weekly 'Weekly limit'
    $claudeStatusText.Text = if ($null -ne $Data.FiveHour -and $null -ne $Data.FiveHour.ResetsAt) { Format-ResetSpan ($Data.FiveHour.ResetsAt - [DateTimeOffset]::Now) }
        else { 'Reset time unavailable' }
    $claudeStatusText.ToolTip = ('Official usage for the whole Claude account, as of {0:HH:mm}{1}' -f $Data.At, $Note)
    # Calibration only matters for the local estimate.
    $calibrateButton.Visibility = 'Collapsed'
}

$refreshClaude = {
    $officialError = $null
    $cache = $script:ClaudeOfficialCache
    if ($null -ne $cache -and [DateTime]::Now -lt $script:ClaudeOfficialNextQuery) {
        & $showOfficialClaude $cache ''
        return
    }
    try {
        $official = Get-ClaudeOfficialUsage
        $fiveHour = Get-OfficialWindow $official 'five_hour'
        $weekly = Get-OfficialWindow $official 'seven_day'
        if ($null -eq $fiveHour -and $null -eq $weekly) { throw 'Claude usage response had no usage data.' }
        $script:ClaudeOfficialCache = @{ FiveHour = $fiveHour; Weekly = $weekly; At = [DateTime]::Now }
        $script:ClaudeOfficialNextQuery = [DateTime]::Now.AddMinutes(5)
        $script:ClaudeOfficialBackoffMinutes = 10
        & $showOfficialClaude $script:ClaudeOfficialCache ''
        Write-ClaudeLog 'Official usage OK'
        return
    }
    catch {
        $officialError = $_.Exception.Message
        Write-ClaudeLog ('Official usage FAILED: ' + $officialError)
    }

    if ($officialError -like '*(429)*') {
        $script:ClaudeOfficialNextQuery = [DateTime]::Now.AddMinutes($script:ClaudeOfficialBackoffMinutes)
        $script:ClaudeOfficialBackoffMinutes = [Math]::Min(60, $script:ClaudeOfficialBackoffMinutes * 2)
        # Throttled: keep the last official numbers for up to an hour.
        if ($null -ne $cache -and ([DateTime]::Now - $cache.At).TotalMinutes -lt 60) {
            & $showOfficialClaude $cache ('; next query {0:HH:mm} (throttled)' -f $script:ClaudeOfficialNextQuery)
            return
        }
    }

    $calibrateButton.Visibility = 'Visible'
    try {
        $config = Get-ClaudeConfig
        $claude = Get-ClaudeUsage
        Set-ClaudeRow $claudePrimaryText $claudePrimaryBar $claude.FiveHourTokens $config.fiveHourTokenLimit
        Set-ClaudeRow $claudeSecondaryText $claudeSecondaryBar $claude.WeeklyTokens $config.weeklyTokenLimit
        $claudeStatusText.Text = if ($null -eq $claude.FiveHourResetsAt) { 'Estimate - no active 5h window' }
            else { 'Estimate - ' + (Format-ResetSpan ($claude.FiveHourResetsAt - [DateTime]::UtcNow)) }
        $claudeStatusText.ToolTip = "Local estimate (official usage unavailable: $officialError)"
    }
    catch {
        $claudeStatusText.Text = $_.Exception.Message
        $claudeStatusText.ToolTip = $_.Exception.Message
        $claudePrimaryText.Text = 'Unavailable'
        $claudeSecondaryText.Text = 'Unavailable'
    }
}

$refreshUsage = {
    & $refreshCodex
    & $refreshClaude
}

$calibrateButton.Add_Click({
    # Drop always-on-top while the input boxes are open so they are not hidden behind the card.
    $window.Topmost = $false
    try {
        if (Invoke-ClaudeCalibration) { & $refreshClaude }
    }
    catch {
        [void][System.Windows.MessageBox]::Show($_.Exception.Message, 'Claude 用量校準')
    }
    finally { $window.Topmost = $true }
})

$refreshButton.Add_Click($refreshUsage)
$timer = [System.Windows.Threading.DispatcherTimer]::new()
$timer.Interval = [TimeSpan]::FromSeconds($RefreshSeconds)
$timer.Add_Tick($refreshUsage)
$timer.Start()
$window.Add_Closed({
    $timer.Stop()
    if ($script:AppServer -and -not $script:AppServer.HasExited) { $script:AppServer.Kill() }
})

$window.Show()
& $refreshUsage
[System.Windows.Threading.Dispatcher]::Run()
