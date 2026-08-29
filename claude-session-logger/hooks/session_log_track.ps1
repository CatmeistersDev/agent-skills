$ErrorActionPreference = 'SilentlyContinue'
$LogRoot = Join-Path $env:USERPROFILE '.claude\session-logs'
$ErrLog  = Join-Path $LogRoot 'errors.log'

function Write-ErrLog($msg) {
    try {
        New-Item -ItemType Directory -Force -Path $LogRoot | Out-Null
        "$([DateTime]::Now.ToString('o')) [session_log_track] $msg" | Add-Content -Path $ErrLog -Encoding UTF8
    } catch {}
}

# Strips host/network/account identifiers and obvious secrets out of a value
# before it is written to disk. Set CLAUDE_SESSION_LOG_RAW=1 to log verbatim.
# Rule-for-rule mirror of sanitize() in session_log_track.sh.
function Protect-Sensitive($text) {
    if (-not $text) { return $text }
    if ($env:CLAUDE_SESSION_LOG_RAW -eq '1') { return [string]$text }
    $s = [string]$text

    # Home directory -> ~ , then any remaining user-home path -> <user>
    if ($env:USERPROFILE) { $s = $s -replace [regex]::Escape($env:USERPROFILE), '~' }
    $s = $s -replace '(?i)([A-Z]:\\Users\\)[^\\/:*?"<>|\s]+', '$1<user>'
    $s = $s -replace '(?i)(/(?:home|Users)/)[^/\s]+', '$1<user>'

    # user@host (ssh/scp/rsync targets, email addresses)
    $s = $s -replace '(?i)[\w.+-]+@(?:\[[0-9a-f:]+\]|[\w.-]+)', '<user>@<host>'

    # URLs -> keep the scheme, drop the host
    $s = $s -replace '(?i)\b([a-z][a-z0-9+.-]*)://[^/\s"'']+', '$1://<host>'

    # IPv4 (optional port) and full-form IPv6
    $s = $s -replace '(?:\d{1,3}\.){3}\d{1,3}(?::\d+)?', '<ip>'
    $s = $s -replace '(?i)(?<![\w:])(?:[0-9a-f]{1,4}:){7}[0-9a-f]{1,4}(?![\w:])', '<ip>'

    # Hostnames on local/private TLDs
    $s = $s -replace '(?i)[\w-]+(?:\.[\w-]+)*\.(?:local|internal|lan|home|corp|intranet|arpa)\b', '<host>'

    # Explicit host-taking flags
    $s = $s -replace '(?i)(--(?:host|hostname|server|node|endpoint|target))(\s*=\s*|\s+)\S+', '$1$2<host>'

    # Well-known credential shapes
    $s = $s -replace '(?i)(gh[pousr]_[A-Za-z0-9]{10,}|gl(?:pat|dt)-[A-Za-z0-9_-]{10,}|sk-[A-Za-z0-9_-]{10,}|AKIA[0-9A-Z]{12,})', '<redacted>'

    # key=value / header-style secrets
    $s = $s -replace '(?i)(password|passwd|pwd|token|secret|api[-_]?key|apikey|authorization|bearer)(\s*[:=]\s*|\s+)[^\s"'']+', '$1$2<redacted>'

    return $s
}
function Get-Target($toolName, $toolInput) {
    if ($toolName -eq 'Edit' -or $toolName -eq 'Write') {
        return [string]$toolInput.file_path
    }
    if ($toolName -eq 'NotebookEdit') {
        if ($toolInput.notebook_path) { return [string]$toolInput.notebook_path }
        return [string]$toolInput.file_path
    }
    if ($toolName -eq 'Bash') {
        $cmd = [string]$toolInput.command
        if ($cmd.Length -gt 80) { $cmd = $cmd.Substring(0, 80) }
        return ($cmd -replace "`r`n|`n", ' ')
    }
    if ($toolName -like 'mcp__*') {
        # vmid/container_id/id are opaque numeric handles and are kept as-is.
        # node/name are host or server names, so only their presence is logged.
        foreach ($key in @('vmid', 'container_id', 'id')) {
            $val = $toolInput.$key
            if ($val) { return "$key=$val" }
        }
        foreach ($key in @('node', 'name')) {
            $val = $toolInput.$key
            if ($val) { return "$key=<redacted>" }
        }
        return ''
    }
    return ''
}

try {
    $raw  = [Console]::In.ReadToEnd()
    $data = $raw | ConvertFrom-Json -ErrorAction Stop

    $sessionId = $data.session_id
    if (-not $sessionId) { $sessionId = 'unknown' }
    $toolName = $data.tool_name
    if (-not $toolName) { $toolName = '?' }
    $toolInput = $data.tool_input
    if (-not $toolInput) { $toolInput = New-Object PSObject }

    $projectSlug = 'unknown-project'
    if ($data.transcript_path) {
        $projectSlug = Split-Path (Split-Path $data.transcript_path -Parent) -Leaf
    } elseif ($data.cwd) {
        $projectSlug = ([string]$data.cwd) -replace '[:\\/.\s]', '-'
    }

    $projDir = Join-Path $LogRoot $projectSlug
    New-Item -ItemType Directory -Force -Path $projDir | Out-Null
    $logFile = Join-Path $projDir "$sessionId.md"

    $target = Protect-Sensitive (Get-Target $toolName $toolInput)
    $now = [DateTime]::Now.ToString('yyyy-MM-ddTHH:mm:ss')
    "- $now | $toolName | $target" | Add-Content -Path $logFile -Encoding UTF8
} catch {
    Write-ErrLog $_.Exception.ToString()
}
exit 0
