$ErrorActionPreference = 'SilentlyContinue'
$LogRoot = Join-Path $env:USERPROFILE '.claude\session-logs'
$ErrLog  = Join-Path $LogRoot 'errors.log'

function Write-ErrLog($msg) {
    try {
        New-Item -ItemType Directory -Force -Path $LogRoot | Out-Null
        "$([DateTime]::Now.ToString('o')) [session_log_track] $msg" | Add-Content -Path $ErrLog -Encoding UTF8
    } catch {}
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
        foreach ($key in @('vmid', 'node', 'name', 'container_id', 'id')) {
            $val = $toolInput.$key
            if ($val) { return "$key=$val" }
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

    $target = Get-Target $toolName $toolInput
    $now = [DateTime]::Now.ToString('yyyy-MM-ddTHH:mm:ss')
    "- $now | $toolName | $target" | Add-Content -Path $logFile -Encoding UTF8
} catch {
    Write-ErrLog $_.Exception.ToString()
}
exit 0
