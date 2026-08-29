$ErrorActionPreference = 'SilentlyContinue'
$LogRoot = Join-Path $env:USERPROFILE '.claude\session-logs'
$ErrLog  = Join-Path $LogRoot 'errors.log'

function Write-ErrLog($msg) {
    try {
        New-Item -ItemType Directory -Force -Path $LogRoot | Out-Null
        "$([DateTime]::Now.ToString('o')) [session_log_model_switch] $msg" | Add-Content -Path $ErrLog -Encoding UTF8
    } catch {}
}

try {
    $raw  = [Console]::In.ReadToEnd()
    $data = $raw | ConvertFrom-Json -ErrorAction Stop

    $sessionId = $data.session_id
    if (-not $sessionId) { $sessionId = 'unknown' }
    $event = $data.hook_event_name
    if (-not $event) { $event = 'PreModelSwitch' }

    $projectSlug = 'unknown-project'
    if ($data.transcript_path) {
        $projectSlug = Split-Path (Split-Path $data.transcript_path -Parent) -Leaf
    } elseif ($data.cwd) {
        $projectSlug = ([string]$data.cwd) -replace '[:\\/.\s]', '-'
    }

    $projDir = Join-Path $LogRoot $projectSlug
    New-Item -ItemType Directory -Force -Path $projDir | Out-Null
    $logFile = Join-Path $projDir "$sessionId.md"

    $from = $data.from_model
    if (-not $from) { $from = '?' }
    $to = $data.to_model
    if (-not $to) { $to = '?' }
    $src = $data.source
    if (-not $src) { $src = '?' }
    $req = $data.requested_model
    if (-not $req) { $req = 'default' }

    $tokens = 0
    if ($null -ne $data.context_tokens) { $tokens = [int]$data.context_tokens }
    $usd = 0.0
    if ($null -ne $data.estimated_cache_write_usd) { $usd = [double]$data.estimated_cache_write_usd }
    $ttl = $data.cache_ttl
    if (-not $ttl) { $ttl = '?' }
    $pricing = $data.pricing
    if (-not $pricing) { $pricing = '?' }
    if ($data.prompt_cache_warm) { $warm = 'warm' } else { $warm = 'cold' }

    $tokStr = '{0:N0}' -f $tokens
    $usdStr = '{0:N4}' -f $usd
    $now = [DateTime]::Now.ToString('yyyy-MM-ddTHH:mm:ss')

    if ($event -eq 'PreModelSwitch') {
        "- $now | ModelSwitch? | $from -> $to (req=$req via $src) | cache=$warm ttl=$ttl | re-cache $tokStr tok ~`$$usdStr [$pricing]" |
            Add-Content -Path $logFile -Encoding UTF8

        # To gate switches instead of only logging them, emit a decision here:
        #   allow = proceed, skipping the interactive cache-miss confirm
        #   ask   = force a confirmation prompt (a headless session refuses instead)
        #   deny  = cancel the switch
        # if ($usd -gt 0.50) {
        #     @{ hookSpecificOutput = @{
        #           hookEventName            = 'PreModelSwitch'
        #           permissionDecision       = 'ask'
        #           permissionDecisionReason = "Re-caching $tokStr tokens on $to costs about `$$usdStr."
        #       } } | ConvertTo-Json -Compress -Depth 5
        # }
    } else {
        "- $now | ModelSwitch | $from -> $to (req=$req via $src) | re-cache $tokStr tok ~`$$usdStr [$pricing]" |
            Add-Content -Path $logFile -Encoding UTF8

        # Uncomment to tell the incoming model what it inherited:
        # @{ hookSpecificOutput = @{
        #       hookEventName     = 'PostModelSwitch'
        #       additionalContext = "Model switched $from -> $to (source: $src); about $tokStr tokens of context were re-cached."
        #   } } | ConvertTo-Json -Compress -Depth 5
    }
} catch {
    Write-ErrLog $_.Exception.ToString()
}
exit 0
