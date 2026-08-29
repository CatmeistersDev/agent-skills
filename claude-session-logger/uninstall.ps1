#Requires -Version 5.1
$ErrorActionPreference = 'Stop'

$ClaudeDir    = Join-Path $env:USERPROFILE '.claude'
$SettingsPath = Join-Path $ClaudeDir 'settings.json'
$HooksDir     = Join-Path $ClaudeDir 'hooks'

if (-not (Test-Path $SettingsPath)) {
    Write-Host "No settings.json found at $SettingsPath - nothing to do."
    exit 0
}

$stamp = Get-Date -Format 'yyyyMMdd-HHmmss'
$backupPath = "$SettingsPath.bak-preuninstall-$stamp"
Copy-Item -Path $SettingsPath -Destination $backupPath -Force
Write-Host "OK: backed up settings.json to $backupPath"

$settings = (Get-Content -Path $SettingsPath -Raw -Encoding UTF8) | ConvertFrom-Json

$scriptNames = @('session_log_start.ps1', 'session_log_track.ps1', 'session_log_model_switch.ps1')

function Block-ReferencesOurScripts($block) {
    foreach ($h in $block.hooks) {
        if ($h.args) {
            $argStr = $h.args -join ' '
            foreach ($name in $scriptNames) {
                if ($argStr -match [regex]::Escape($name)) { return $true }
            }
        }
    }
    return $false
}

if (Get-Member -InputObject $settings -Name 'hooks' -MemberType NoteProperty) {
    foreach ($evt in @('SessionStart','PostToolUse','PreModelSwitch','PostModelSwitch')) {
        if (Get-Member -InputObject $settings.hooks -Name $evt -MemberType NoteProperty) {
            $before = @($settings.hooks.$evt)
            $after  = @($before | Where-Object { -not (Block-ReferencesOurScripts $_) })
            Write-Host "Removed $($before.Count - $after.Count) block(s) from $evt"
            $settings.hooks.$evt = $after
        }
    }
}

$jsonOut = ConvertTo-Json -InputObject $settings -Depth 25
$null = $jsonOut | ConvertFrom-Json -ErrorAction Stop

$utf8NoBom = New-Object System.Text.UTF8Encoding $false
[System.IO.File]::WriteAllText($SettingsPath, $jsonOut, $utf8NoBom)
Write-Host "OK: wrote updated settings.json (hook entries removed)"

if (Test-Path $HooksDir) {
    foreach ($name in $scriptNames) {
        Remove-Item -Path (Join-Path $HooksDir $name) -Force -ErrorAction SilentlyContinue
    }
    Write-Host "OK: removed hook script files (session-logs data left intact)"
}

Write-Host "`nUninstall complete. Backup: $backupPath"
