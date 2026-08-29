#!/usr/bin/env bash
# SessionStart hook: writes a "## Session start" header line to the
# per-session Markdown log. Linux/macOS port of session_log_start.ps1.
LOG_ROOT="$HOME/.claude/session-logs"
ERR_LOG="$LOG_ROOT/errors.log"

write_err() {
    mkdir -p "$LOG_ROOT" 2>/dev/null
    printf '%s [session_log_start] %s\n' "$(date -Is)" "$1" >>"$ERR_LOG" 2>/dev/null
}

main() {
    local raw data session_id source transcript_path cwd project_slug proj_dir log_file now

    raw="$(cat)"
    data="$(printf '%s' "$raw" | jq -e '.' 2>&1)" || { write_err "failed to parse JSON input: $data"; return; }

    session_id="$(printf '%s' "$data" | jq -r '.session_id // "unknown"')"
    source="$(printf '%s' "$data" | jq -r '.source // "unknown"')"
    transcript_path="$(printf '%s' "$data" | jq -r '.transcript_path // empty')"
    cwd="$(printf '%s' "$data" | jq -r '.cwd // empty')"

    if [[ -n "$transcript_path" ]]; then
        project_slug="$(basename "$(dirname "$transcript_path")")"
    elif [[ -n "$cwd" ]]; then
        project_slug="$(printf '%s' "$cwd" | sed -E 's|[:/\\. \t]|-|g')"
    else
        project_slug="unknown-project"
    fi

    proj_dir="$LOG_ROOT/$project_slug"
    mkdir -p "$proj_dir" 2>/dev/null || { write_err "failed to create $proj_dir"; return; }
    log_file="$proj_dir/$session_id.md"
    now="$(date '+%Y-%m-%dT%H:%M:%S')"

    # On resume/fork, Claude Code 2.1.251+ also reports prompt-cache staleness.
    # These fields are absent on a plain startup, so the line degrades cleanly.
    local secs tok usd expired cache extra idle
    extra=""
    secs="$(printf '%s' "$data" | jq -r '.seconds_since_last_response // empty')"
    if [[ -n "$secs" ]]; then
        secs="${secs%%.*}"
        tok="$(printf '%s' "$data" | jq -r '.context_tokens // 0 | floor')"
        usd="$(printf '%s' "$data" | jq -r '.estimated_cache_write_usd // 0')"
        expired="$(printf '%s' "$data" | jq -r '.prompt_cache_likely_expired // false')"
        if [[ "$expired" == "true" ]]; then cache="cache EXPIRED"; else cache="cache likely warm"; fi
        idle="$(printf '%02d:%02d:%02d' $((secs/3600)) $(((secs%3600)/60)) $((secs%60)))"
        extra="$(printf ' - idle %s, %s, re-cache %s tok ~$%.4f' "$idle" "$cache" "$tok" "$usd")"
    fi

    { printf '\n## Session start - %s (source: %s)%s\n\n' "$now" "$source" "$extra"; } >>"$log_file" 2>/dev/null \
        || write_err "failed to write $log_file"
}

main
exit 0
