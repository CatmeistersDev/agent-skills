#!/usr/bin/env bash
# PreModelSwitch / PostModelSwitch hook: appends one line per model switch to
# the per-session Markdown log. Linux/macOS port of session_log_model_switch.ps1.
# Requires Claude Code 2.1.251+ (the events do not exist before that).
LOG_ROOT="$HOME/.claude/session-logs"
ERR_LOG="$LOG_ROOT/errors.log"

write_err() {
    mkdir -p "$LOG_ROOT" 2>/dev/null
    printf '%s [session_log_model_switch] %s\n' "$(date -Is)" "$1" >>"$ERR_LOG" 2>/dev/null
}

# Formats an integer with thousands separators, without relying on a locale.
group_digits() {
    printf '%s' "$1" | sed -E ':a;s/([0-9])([0-9]{3})($|,)/\1,\2\3/;ta'
}

main() {
    local raw data session_id event transcript_path cwd project_slug proj_dir log_file
    local from to src req tokens usd ttl pricing warm tok_str usd_str now

    raw="$(cat)"
    data="$(printf '%s' "$raw" | jq -e '.' 2>&1)" || { write_err "failed to parse JSON input: $data"; return; }

    session_id="$(printf '%s' "$data" | jq -r '.session_id // "unknown"')"
    event="$(printf '%s' "$data" | jq -r '.hook_event_name // "PreModelSwitch"')"
    transcript_path="$(printf '%s' "$data" | jq -r '.transcript_path // empty')"
    cwd="$(printf '%s' "$data" | jq -r '.cwd // empty')"

    if [[ -n "$transcript_path" ]]; then
        project_slug="$(basename "$(dirname "$transcript_path")")"
    elif [[ -n "$cwd" ]]; then
        project_slug="$(printf '%s' "$cwd" | sed -E 's|[:/\. \t]|-|g')"
    else
        project_slug="unknown-project"
    fi

    proj_dir="$LOG_ROOT/$project_slug"
    mkdir -p "$proj_dir" 2>/dev/null || { write_err "failed to create $proj_dir"; return; }
    log_file="$proj_dir/$session_id.md"

    from="$(printf '%s' "$data" | jq -r '.from_model // "?"')"
    to="$(printf '%s' "$data" | jq -r '.to_model // "?"')"
    src="$(printf '%s' "$data" | jq -r '.source // "?"')"
    req="$(printf '%s' "$data" | jq -r '.requested_model // "default"')"
    tokens="$(printf '%s' "$data" | jq -r '.context_tokens // 0 | floor')"
    usd="$(printf '%s' "$data" | jq -r '.estimated_cache_write_usd // 0')"
    ttl="$(printf '%s' "$data" | jq -r '.cache_ttl // "?"')"
    pricing="$(printf '%s' "$data" | jq -r '.pricing // "?"')"
    if [[ "$(printf '%s' "$data" | jq -r '.prompt_cache_warm // false')" == "true" ]]; then
        warm="warm"
    else
        warm="cold"
    fi

    tok_str="$(group_digits "$tokens")"
    usd_str="$(printf '%.4f' "$usd" 2>/dev/null || printf '0.0000')"
    now="$(date '+%Y-%m-%dT%H:%M:%S')"

    if [[ "$event" == "PreModelSwitch" ]]; then
        printf -- '- %s | ModelSwitch? | %s -> %s (req=%s via %s) | cache=%s ttl=%s | re-cache %s tok ~$%s [%s]\n' \
            "$now" "$from" "$to" "$req" "$src" "$warm" "$ttl" "$tok_str" "$usd_str" "$pricing" \
            >>"$log_file" 2>/dev/null || write_err "failed to write $log_file"

        # To gate switches instead of only logging them, emit a decision here:
        #   allow = proceed, skipping the interactive cache-miss confirm
        #   ask   = force a confirmation prompt (a headless session refuses instead)
        #   deny  = cancel the switch
        # jq -nc --arg reason "Re-caching $tok_str tokens on $to costs about \$$usd_str." \
        #     '{hookSpecificOutput: {hookEventName: "PreModelSwitch", permissionDecision: "ask", permissionDecisionReason: $reason}}'
    else
        printf -- '- %s | ModelSwitch | %s -> %s (req=%s via %s) | re-cache %s tok ~$%s [%s]\n' \
            "$now" "$from" "$to" "$req" "$src" "$tok_str" "$usd_str" "$pricing" \
            >>"$log_file" 2>/dev/null || write_err "failed to write $log_file"

        # Uncomment to tell the incoming model what it inherited:
        # jq -nc --arg ctx "Model switched $from -> $to (source: $src); about $tok_str tokens of context were re-cached." \
        #     '{hookSpecificOutput: {hookEventName: "PostModelSwitch", additionalContext: $ctx}}'
    fi
}

main
exit 0
