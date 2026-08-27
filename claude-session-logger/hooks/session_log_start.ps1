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
    "`n## Session start - $now (source: $source)`n" | Add-Content -Path $logFile -Encoding UTF8
} catch {
    Write-ErrLog $_.Exception.ToString()
}
exit 0
