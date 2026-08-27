#!/usr/bin/env bash
# PostToolUse hook: appends one log line per tool call to the per-session
# Markdown log. Linux/macOS port of session_log_track.ps1.
LOG_ROOT="$HOME/.claude/session-logs"
ERR_LOG="$LOG_ROOT/errors.log"

write_err() {
    mkdir -p "$LOG_ROOT" 2>/dev/null
    printf '%s [session_log_track] %s\n' "$(date -Is)" "$1" >>"$ERR_LOG" 2>/dev/null
}

# Prints the logged "target" value for a tool call on stdout.
get_target() {
    local tool_name="$1" tool_input="$2"
    local cmd notebook_path file_path key val

    case "$tool_name" in
        Edit | Write)
            printf '%s' "$tool_input" | jq -r '.file_path // ""'
            ;;
        NotebookEdit)
            notebook_path="$(printf '%s' "$tool_input" | jq -r '.notebook_path // ""')"
            if [[ -n "$notebook_path" ]]; then
                printf '%s' "$notebook_path"
            else
                printf '%s' "$tool_input" | jq -r '.file_path // ""'
            fi
            ;;
        Bash)
            cmd="$(printf '%s' "$tool_input" | jq -r '.command // ""')"
            cmd="${cmd:0:80}"
            cmd="${cmd//$'\n'/ }"
            cmd="${cmd//$'\r'/ }"
            printf '%s' "$cmd"
            ;;
        mcp__*)
            for key in vmid node name container_id id; do
                val="$(printf '%s' "$tool_input" | jq -r --arg k "$key" '.[$k] // empty')"
                if [[ -n "$val" ]]; then
                    printf '%s=%s' "$key" "$val"
                    return
                fi
            done
            printf ''
            ;;
        *)
            printf ''
            ;;
    esac
}

main() {
    local raw data session_id tool_name tool_input transcript_path cwd project_slug proj_dir log_file target now

    raw="$(cat)"
    data="$(printf '%s' "$raw" | jq -e '.' 2>&1)" || { write_err "failed to parse JSON input: $data"; return; }

    session_id="$(printf '%s' "$data" | jq -r '.session_id // "unknown"')"
    tool_name="$(printf '%s' "$data" | jq -r '.tool_name // "?"')"
    tool_input="$(printf '%s' "$data" | jq -c '.tool_input // {}')"
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

    target="$(get_target "$tool_name" "$tool_input")"
    now="$(date '+%Y-%m-%dT%H:%M:%S')"
    printf -- '- %s | %s | %s\n' "$now" "$tool_name" "$target" >>"$log_file" 2>/dev/null \
        || write_err "failed to write $log_file"
}

main
exit 0
