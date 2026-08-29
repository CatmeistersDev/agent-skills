#!/usr/bin/env bash
# PostToolUse hook: appends one log line per tool call to the per-session
# Markdown log. Linux/macOS port of session_log_track.ps1.
LOG_ROOT="$HOME/.claude/session-logs"
ERR_LOG="$LOG_ROOT/errors.log"

write_err() {
    mkdir -p "$LOG_ROOT" 2>/dev/null
    printf '%s [session_log_track] %s\n' "$(date -Is)" "$1" >>"$ERR_LOG" 2>/dev/null
}

# Strips host/network/account identifiers and obvious secrets out of a value
# before it is written to disk. Set CLAUDE_SESSION_LOG_RAW=1 to log verbatim.
# Strips host/network/account identifiers and obvious secrets out of a value
# before it is written to disk. Set CLAUDE_SESSION_LOG_RAW=1 to log verbatim.
# Deliberately avoids \b and backslash-in-bracket so it behaves the same under
# GNU sed and BSD/macOS sed.
sanitize() {
    local s="$1"
    if [[ "${CLAUDE_SESSION_LOG_RAW:-0}" == "1" ]]; then
        printf '%s' "$s"
        return
    fi
    s="${s//$HOME/\~}"
    printf '%s' "$s" | sed -E \
        -e 's#(/(home|Users)/)[^/[:space:]]+#\1<user>#g' \
        -e 's#[[:alnum:]._+-]+@(\[[0-9A-Fa-f:]+\]|[[:alnum:].-]+)#<user>@<host>#g' \
        -e 's#([a-zA-Z][a-zA-Z0-9+.-]*)://[^/[:space:]"'"'"']+#\1://<host>#g' \
        -e 's#([0-9]{1,3}\.){3}[0-9]{1,3}(:[0-9]+)?#<ip>#g' \
        -e 's#([0-9A-Fa-f]{1,4}:){7}[0-9A-Fa-f]{1,4}#<ip>#g' \
        -e 's#[[:alnum:]_-]+(\.[[:alnum:]_-]+)*\.(local|internal|lan|home|corp|intranet|arpa)#<host>#g' \
        -e 's#(--(host|hostname|server|node|endpoint|target))([[:space:]]*=[[:space:]]*|[[:space:]]+)[^[:space:]]+#\1\3<host>#g' \
        -e 's#(gh[pousr]_[A-Za-z0-9]{10,}|gl(pat|dt)-[A-Za-z0-9_-]{10,}|sk-[A-Za-z0-9_-]{10,}|AKIA[0-9A-Z]{12,})#<redacted>#g' \
        -e 's#([Pp]assword|[Pp]asswd|[Pp]wd|[Tt]oken|[Ss]ecret|[Aa]pi[-_]?[Kk]ey|[Aa]pikey|[Aa]uthorization|[Bb]earer)([[:space:]]*[:=][[:space:]]*|[[:space:]]+)[^[:space:]"'"'"']+#\1\2<redacted>#g'
}

# Prints the logged "target" value for a tool call on stdout.
get_target() {
    local tool_name="$1" tool_input="$2"
    local cmd notebook_path key val

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
            # vmid/container_id/id are opaque numeric handles and are kept as-is.
            # node/name are host or server names, so only their presence is logged.
            for key in vmid container_id id; do
                val="$(printf '%s' "$tool_input" | jq -r --arg k "$key" '.[$k] // empty')"
                if [[ -n "$val" ]]; then
                    printf '%s=%s' "$key" "$val"
                    return
                fi
            done
            for key in node name; do
                val="$(printf '%s' "$tool_input" | jq -r --arg k "$key" '.[$k] // empty')"
                if [[ -n "$val" ]]; then
                    printf '%s=<redacted>' "$key"
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
        project_slug="$(printf '%s' "$cwd" | sed -E 's|[:/\. \t]|-|g')"
    else
        project_slug="unknown-project"
    fi

    proj_dir="$LOG_ROOT/$project_slug"
    mkdir -p "$proj_dir" 2>/dev/null || { write_err "failed to create $proj_dir"; return; }
    log_file="$proj_dir/$session_id.md"

    target="$(sanitize "$(get_target "$tool_name" "$tool_input")")"
    now="$(date '+%Y-%m-%dT%H:%M:%S')"
    printf -- '- %s | %s | %s\n' "$now" "$tool_name" "$target" >>"$log_file" 2>/dev/null \
        || write_err "failed to write $log_file"
}

main
exit 0
