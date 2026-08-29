#Requires -Version 5.1
$ErrorActionPreference = 'Stop'

$ScriptRoot   = $PSScriptRoot
$ClaudeDir    = Join-Path $env:USERPROFILE '.claude'
$SettingsPath = Join-Path $ClaudeDir 'settings.json'
$HooksDir     = Join-Path $ClaudeDir 'hooks'
$LogRoot      = Join-Path $ClaudeDir 'session-logs'

$StartScriptSrc  = Join-Path $ScriptRoot 'hooks\session_log_start.ps1'
$TrackScriptSrc  = Join-Path $ScriptRoot 'hooks\session_log_track.ps1'
$SwitchScriptSrc = Join-Path $ScriptRoot 'hooks\session_log_model_switch.ps1'
$StartScriptDst  = Join-Path $HooksDir 'session_log_start.ps1'
$TrackScriptDst  = Join-Path $HooksDir 'session_log_track.ps1'
$SwitchScriptDst = Join-Path $HooksDir 'session_log_model_switch.ps1'

function Fail($msg) {
    Write-Host "FAIL: $msg" -ForegroundColor Red
    exit 1
}

Write-Host "== Claude Session Logger installer ==" -ForegroundColor Cyan

if (-not (Test-Path $StartScriptSrc))  { Fail "Missing $StartScriptSrc" }
if (-not (Test-Path $TrackScriptSrc))  { Fail "Missing $TrackScriptSrc" }
if (-not (Test-Path $SwitchScriptSrc)) { Fail "Missing $SwitchScriptSrc" }

New-Item -ItemType Directory -Force -Path $ClaudeDir | Out-Null
New-Item -ItemType Directory -Force -Path $HooksDir  | Out-Null
New-Item -ItemType Directory -Force -Path $LogRoot   | Out-Null
Write-Host "OK: directories ready ($HooksDir , $LogRoot)"

Copy-Item -Path $StartScriptSrc  -Destination $StartScriptDst  -Force
Copy-Item -Path $TrackScriptSrc  -Destination $TrackScriptDst  -Force
Copy-Item -Path $SwitchScriptSrc -Destination $SwitchScriptDst -Force
Write-Host "OK: copied hook scripts into $HooksDir"

$backupPath = $null
if (Test-Path $SettingsPath) {
    $stamp = Get-Date -Format 'yyyyMMdd-HHmmss'
    $backupPath = "$SettingsPath.bak-$stamp"
    Copy-Item -Path $SettingsPath -Destination $backupPath -Force
    Write-Host "OK: backed up settings.json to $backupPath"
} else {
    Write-Host "NOTE: no existing settings.json, a new one will be created"
}

if (Test-Path $SettingsPath) {
    $rawExisting = Get-Content -Path $SettingsPath -Raw -Encoding UTF8
    if ([string]::IsNullOrWhiteSpace($rawExisting)) {
        $settings = New-Object PSObject
    } else {
        try {
            $settings = $rawExisting | ConvertFrom-Json -ErrorAction Stop
        } catch {
            Fail "Existing settings.json is not valid JSON - aborting without changes. $($_.Exception.Message)"
        }
    }
} else {
    $settings = New-Object PSObject
}

if (-not (Get-Member -InputObject $settings -Name 'hooks' -MemberType NoteProperty)) {
    $settings | Add-Member -MemberType NoteProperty -Name 'hooks' -Value (New-Object PSObject)
}
foreach ($evt in @('SessionStart','PostToolUse','PreModelSwitch','PostModelSwitch')) {
    if (-not (Get-Member -InputObject $settings.hooks -Name $evt -MemberType NoteProperty)) {
        $settings.hooks | Add-Member -MemberType NoteProperty -Name $evt -Value @()
    }
}

function New-HookHandler($scriptPath) {
    [PSCustomObject]@{
        type    = 'command'
        command = 'powershell.exe'
        args    = @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', $scriptPath)
    }
}
function New-MatcherBlock($matcher, $scriptPath) {
    [PSCustomObject]@{
        matcher = $matcher
        hooks   = @( (New-HookHandler $scriptPath) )
    }
}
function Block-HasScript($block, $scriptPath) {
    foreach ($h in $block.hooks) {
        if ($h.args -and (($h.args -join ' ') -match [regex]::Escape($scriptPath))) { return $true }
    }
    return $false
}

$toInstall = @(
    @{ Event = 'SessionStart'; Matcher = '*'; Script = $StartScriptDst },
    @{ Event = 'PostToolUse';  Matcher = 'Edit|Write|NotebookEdit|Bash'; Script = $TrackScriptDst },
    @{ Event = 'PostToolUse';  Matcher = '^mcp__.*__(start|stop|create|delete|restart|clone|restore|update|set|execute).*'; Script = $TrackScriptDst },
    # PreModelSwitch/PostModelSwitch need Claude Code 2.1.251+. On older builds
    # the events simply never fire, so these entries sit inert rather than break.
    # For these two events the matcher is tested against to_model, not a tool name.
    @{ Event = 'PreModelSwitch';  Matcher = '*'; Script = $SwitchScriptDst },
    @{ Event = 'PostModelSwitch'; Matcher = '*'; Script = $SwitchScriptDst }
)

foreach ($item in $toInstall) {
    $evt = $item.Event
    $arr = @($settings.hooks.$evt)
    $dup = $arr | Where-Object { $_.matcher -eq $item.Matcher -and (Block-HasScript $_ $item.Script) }
    if ($dup) {
        Write-Host "SKIP: $evt / '$($item.Matcher)' already present"
    } else {
        $settings.hooks.$evt = @($arr + (New-MatcherBlock $item.Matcher $item.Script))
        Write-Host "OK: added $evt hook (matcher: $($item.Matcher))"
    }
}

$jsonOut = ConvertTo-Json -InputObject $settings -Depth 25
try {
    $null = $jsonOut | ConvertFrom-Json -ErrorAction Stop
} catch {
    Fail "Generated JSON failed round-trip validation - aborting without writing. $($_.Exception.Message)"
}

$utf8NoBom = New-Object System.Text.UTF8Encoding $false
[System.IO.File]::WriteAllText($SettingsPath, $jsonOut, $utf8NoBom)
Write-Host "OK: wrote $SettingsPath"

Write-Host "`n== Smoke test ==" -ForegroundColor Cyan
$testSessionId   = "install-selftest-$(Get-Date -Format 'yyyyMMddHHmmss')"
$testProjectSlug = 'install-selftest-project'
$testTranscript  = Join-Path $ClaudeDir "projects\$testProjectSlug\$testSessionId.jsonl"

$startPayload = (@{ session_id = $testSessionId; source = 'resume'; transcript_path = $testTranscript; cwd = 'C:\selftest'; seconds_since_last_response = 9683; context_tokens = 184220; prompt_cache_likely_expired = $true; estimated_cache_write_usd = 0.6912 } | ConvertTo-Json -Compress)
$trackPayload = (@{ session_id = $testSessionId; tool_name = 'Bash'; tool_input = @{ command = 'echo selftest' }; transcript_path = $testTranscript; cwd = 'C:\selftest' } | ConvertTo-Json -Compress -Depth 5)
# Deliberately laced with an IP, a host and a secret: the log must contain none of them.
$redactPayload = (@{ session_id = $testSessionId; tool_name = 'Bash'; tool_input = @{ command = 'ssh svc@10.1.2.3 --password hunter2trustno1' }; transcript_path = $testTranscript; cwd = 'C:\selftest' } | ConvertTo-Json -Compress -Depth 5)
$switchPayload = (@{ session_id = $testSessionId; hook_event_name = 'PostModelSwitch'; transcript_path = $testTranscript; cwd = 'C:\selftest'; from_model = 'claude-opus-5'; to_model = 'claude-sonnet-5'; requested_model = 'sonnet'; source = 'picker'; context_tokens = 184220; prompt_cache_warm = $true; cache_ttl = '1h'; estimated_cache_write_usd = 0.6912; pricing = 'catalog' } | ConvertTo-Json -Compress)

$startPayload  | & powershell.exe -NoProfile -ExecutionPolicy Bypass -File $StartScriptDst
$trackPayload  | & powershell.exe -NoProfile -ExecutionPolicy Bypass -File $TrackScriptDst
$redactPayload | & powershell.exe -NoProfile -ExecutionPolicy Bypass -File $TrackScriptDst
$switchPayload | & powershell.exe -NoProfile -ExecutionPolicy Bypass -File $SwitchScriptDst

$testLogFile = Join-Path $LogRoot "$testProjectSlug\$testSessionId.md"
if (Test-Path $testLogFile) {
    Write-Host "OK: smoke test log created: $testLogFile"
    Write-Host "--- contents ---"
    Get-Content $testLogFile
    Write-Host "--- end contents ---"

    $logText = Get-Content $testLogFile -Raw
    $leaks = @()
    if ($logText -match '10\.1\.2\.3')        { $leaks += 'IP address' }
    if ($logText -match 'hunter2trustno1')    { $leaks += 'password' }
    if ($logText -match 'svc@')               { $leaks += 'user@host' }
    if ($leaks.Count -gt 0) {
        Fail "Redaction check FAILED - these reached the log: $($leaks -join ', '). Do not treat session-logs as safe to share."
    }
    Write-Host "OK: redaction check passed (no IP, host or secret in log)"

    if ($logText -notmatch 'ModelSwitch') {
        Write-Host "NOTE: model-switch line absent - expected on Claude Code older than 2.1.251" -ForegroundColor Yellow
    }

    Remove-Item -Recurse -Force (Join-Path $LogRoot $testProjectSlug)
    Write-Host "OK: cleaned up smoke-test artifacts"
} else {
    Fail "Smoke test log NOT found at $testLogFile - hooks are not writing correctly."
}

Write-Host "`n== Install complete ==" -ForegroundColor Green
Write-Host "Settings file : $SettingsPath"
if ($backupPath) { Write-Host "Backup        : $backupPath" }
Write-Host "Hook scripts  : $HooksDir"
Write-Host "Session logs  : $LogRoot\<project-slug>\<session_id>.md"
