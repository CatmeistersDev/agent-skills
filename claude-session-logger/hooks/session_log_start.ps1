$ErrorActionPreference = 'SilentlyContinue'
$LogRoot = Join-Path $env:USERPROFILE '.claude\session-logs'
$ErrLog  = Join-Path $LogRoot 'errors.log'

function Write-ErrLog($msg) {
    try {
        New-Item -ItemType Directory -Force -Path $LogRoot | Out-Null
        "$([DateTime]::Now.ToString('o')) [session_log_start] $msg" | Add-Content -Path $ErrLog -Encoding UTF8
    } catch {}
}

try {
    $raw  = [Console]::In.ReadToEnd()
    $data = $raw | ConvertFrom-Json -ErrorAction Stop

    $sessionId = $data.session_id
    if (-not $sessionId) { $sessionId = 'unknown' }
    $source = $data.source
    if (-not $source) { $source = 'unknown' }

    $projectSlug = 'unknown-project'
    if ($data.transcript_path) {
        $projectSlug = Split-Path (Split-Path $data.transcript_path -Parent) -Leaf
    } elseif ($data.cwd) {
        $projectSlug = ([string]$data.cwd) -replace '[:\\/.\s]', '-'
    }

    $projDir = Join-Path $LogRoot $projectSlug
    New-Item -ItemType Directory -Force -Path $projDir | Out-Null
    $logFile = Join-Path $projDir "$sessionId.md"

    $now = [DateTime]::Now.ToString('yyyy-MM-ddTHH:mm:ss')
    # On resume/fork, Claude Code 2.1.251+ also reports prompt-cache staleness.
    # These fields are absent on a plain startup, so the line degrades cleanly.
    $extra = ''
    if ($null -ne $data.seconds_since_last_response) {
        $secs = [int]$data.seconds_since_last_response
        $idle = [TimeSpan]::FromSeconds($secs).ToString('c')
        $tok  = 0
        if ($null -ne $data.context_tokens) { $tok = [int]$data.context_tokens }
        $usd  = 0.0
        if ($null -ne $data.estimated_cache_write_usd) { $usd = [double]$data.estimated_cache_write_usd }
        if ($data.prompt_cache_likely_expired) { $cache = 'cache EXPIRED' } else { $cache = 'cache likely warm' }
        $extra = " - idle $idle, $cache, re-cache $('{0:N0}' -f $tok) tok ~`$$('{0:N4}' -f $usd)"
    }

    "`n## Session start - $now (source: $source)$extra`n" | Add-Content -Path $logFile -Encoding UTF8
} catch {
    Write-ErrLog $_.Exception.ToString()
}
exit 0
