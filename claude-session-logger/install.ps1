#Requires -Version 5.1
$ErrorActionPreference = 'Stop'

$ScriptRoot   = $PSScriptRoot
$ClaudeDir    = Join-Path $env:USERPROFILE '.claude'
$SettingsPath = Join-Path $ClaudeDir 'settings.json'
$HooksDir     = Join-Path $ClaudeDir 'hooks'
$LogRoot      = Join-Path $ClaudeDir 'session-logs'

$StartScriptSrc = Join-Path $ScriptRoot 'hooks\session_log_start.ps1'
$TrackScriptSrc = Join-Path $ScriptRoot 'hooks\session_log_track.ps1'
$StartScriptDst = Join-Path $HooksDir 'session_log_start.ps1'
$TrackScriptDst = Join-Path $HooksDir 'session_log_track.ps1'

function Fail($msg) {
    Write-Host "FAIL: $msg" -ForegroundColor Red
    exit 1
}

Write-Host "== Claude Session Logger installer ==" -ForegroundColor Cyan

if (-not (Test-Path $StartScriptSrc)) { Fail "Missing $StartScriptSrc" }
if (-not (Test-Path $TrackScriptSrc)) { Fail "Missing $TrackScriptSrc" }

New-Item -ItemType Directory -Force -Path $ClaudeDir | Out-Null
New-Item -ItemType Directory -Force -Path $HooksDir  | Out-Null
New-Item -ItemType Directory -Force -Path $LogRoot   | Out-Null
Write-Host "OK: directories ready ($HooksDir , $LogRoot)"

Copy-Item -Path $StartScriptSrc -Destination $StartScriptDst -Force
Copy-Item -Path $TrackScriptSrc -Destination $TrackScriptDst -Force
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
foreach ($evt in @('SessionStart','PostToolUse')) {
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
    @{ Event = 'PostToolUse';  Matcher = '^mcp__.*__(start|stop|create|delete|restart|clone|restore|update|set|execute).*'; Script = $TrackScriptDst }
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

$startPayload = (@{ session_id = $testSessionId; source = 'selftest'; transcript_path = $testTranscript; cwd = 'C:\selftest' } | ConvertTo-Json -Compress)
$trackPayload = (@{ session_id = $testSessionId; tool_name = 'Bash'; tool_input = @{ command = 'echo selftest' }; transcript_path = $testTranscript; cwd = 'C:\selftest' } | ConvertTo-Json -Compress -Depth 5)

$startPayload | & powershell.exe -NoProfile -ExecutionPolicy Bypass -File $StartScriptDst
$trackPayload | & powershell.exe -NoProfile -ExecutionPolicy Bypass -File $TrackScriptDst

$testLogFile = Join-Path $LogRoot "$testProjectSlug\$testSessionId.md"
if (Test-Path $testLogFile) {
    Write-Host "OK: smoke test log created: $testLogFile"
    Write-Host "--- contents ---"
    Get-Content $testLogFile
    Write-Host "--- end contents ---"
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
