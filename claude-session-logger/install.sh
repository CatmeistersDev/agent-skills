#!/usr/bin/env bash
# Claude Session Logger installer (Linux/macOS)
# Requires: jq
set -euo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" &>/dev/null && pwd)"
CLAUDE_DIR="$HOME/.claude"
SETTINGS_PATH="$CLAUDE_DIR/settings.json"
HOOKS_DIR="$CLAUDE_DIR/hooks"
LOG_ROOT="$CLAUDE_DIR/session-logs"

START_SCRIPT_SRC="$SCRIPT_DIR/hooks/session_log_start.sh"
TRACK_SCRIPT_SRC="$SCRIPT_DIR/hooks/session_log_track.sh"
SWITCH_SCRIPT_SRC="$SCRIPT_DIR/hooks/session_log_model_switch.sh"
START_SCRIPT_DST="$HOOKS_DIR/session_log_start.sh"
TRACK_SCRIPT_DST="$HOOKS_DIR/session_log_track.sh"
SWITCH_SCRIPT_DST="$HOOKS_DIR/session_log_model_switch.sh"

fail() { echo "FAIL: $1" >&2; exit 1; }

echo "== Claude Session Logger installer =="

command -v jq >/dev/null 2>&1 || fail "'jq' is required but not found on PATH. Install it (e.g. 'sudo pacman -S jq' / 'sudo apt install jq') and re-run."
[[ -f "$START_SCRIPT_SRC" ]] || fail "Missing $START_SCRIPT_SRC"
[[ -f "$TRACK_SCRIPT_SRC" ]] || fail "Missing $TRACK_SCRIPT_SRC"
[[ -f "$SWITCH_SCRIPT_SRC" ]] || fail "Missing $SWITCH_SCRIPT_SRC"

mkdir -p "$CLAUDE_DIR" "$HOOKS_DIR" "$LOG_ROOT"
echo "OK: directories ready ($HOOKS_DIR , $LOG_ROOT)"

cp "$START_SCRIPT_SRC" "$START_SCRIPT_DST"
cp "$TRACK_SCRIPT_SRC" "$TRACK_SCRIPT_DST"
cp "$SWITCH_SCRIPT_SRC" "$SWITCH_SCRIPT_DST"
chmod +x "$START_SCRIPT_DST" "$TRACK_SCRIPT_DST" "$SWITCH_SCRIPT_DST"
echo "OK: copied hook scripts into $HOOKS_DIR"

backup_path=""
if [[ -f "$SETTINGS_PATH" ]]; then
    stamp="$(date +%Y%m%d-%H%M%S)"
    backup_path="$SETTINGS_PATH.bak-$stamp"
    cp "$SETTINGS_PATH" "$backup_path"
    echo "OK: backed up settings.json to $backup_path"
    if [[ -s "$SETTINGS_PATH" ]]; then
        jq -e '.' "$SETTINGS_PATH" >/dev/null 2>&1 || fail "Existing settings.json is not valid JSON - aborting without changes."
    else
        echo '{}' >"$SETTINGS_PATH"
    fi
else
    echo "NOTE: no existing settings.json, a new one will be created"
    echo '{}' >"$SETTINGS_PATH"
fi

merge_hook_rule() {
    local evt="$1" matcher="$2" script_path="$3" cmd="$4"
    local tmp before_count after_count

    before_count="$(jq --arg evt "$evt" '(.hooks[$evt] // []) | length' "$SETTINGS_PATH")"

    tmp="$(mktemp)"
    jq --arg evt "$evt" --arg matcher "$matcher" --arg script "$script_path" --arg cmd "$cmd" '
        .hooks = (.hooks // {}) |
        .hooks[$evt] = (.hooks[$evt] // []) |
        (.hooks[$evt] | any(.matcher == $matcher and ((.hooks // []) | any((.command // "") | contains($script))))) as $dup |
        if $dup then . else
            .hooks[$evt] += [{matcher: $matcher, hooks: [{type: "command", command: $cmd}]}]
        end
    ' "$SETTINGS_PATH" >"$tmp"
    mv "$tmp" "$SETTINGS_PATH"

    after_count="$(jq --arg evt "$evt" '(.hooks[$evt] // []) | length' "$SETTINGS_PATH")"
    if [[ "$after_count" -gt "$before_count" ]]; then
        echo "OK: added $evt hook (matcher: $matcher)"
    else
        echo "SKIP: $evt / '$matcher' already present"
    fi
}

merge_hook_rule "SessionStart" "*" "$START_SCRIPT_DST" "bash \"$START_SCRIPT_DST\""
merge_hook_rule "PostToolUse" "Edit|Write|NotebookEdit|Bash" "$TRACK_SCRIPT_DST" "bash \"$TRACK_SCRIPT_DST\""
merge_hook_rule "PostToolUse" '^mcp__.*__(start|stop|create|delete|restart|clone|restore|update|set|execute).*' "$TRACK_SCRIPT_DST" "bash \"$TRACK_SCRIPT_DST\""
# PreModelSwitch/PostModelSwitch need Claude Code 2.1.251+. On older builds the
# events simply never fire, so these entries sit inert rather than break anything.
# For these two events the matcher is tested against to_model, not a tool name.
merge_hook_rule "PreModelSwitch" "*" "$SWITCH_SCRIPT_DST" "bash \"$SWITCH_SCRIPT_DST\""
merge_hook_rule "PostModelSwitch" "*" "$SWITCH_SCRIPT_DST" "bash \"$SWITCH_SCRIPT_DST\""

jq -e '.' "$SETTINGS_PATH" >/dev/null 2>&1 || fail "Final settings.json failed validation - this should not happen, restore from $backup_path"
echo "OK: wrote $SETTINGS_PATH"

echo
echo "== Smoke test =="
test_session_id="install-selftest-$(date +%Y%m%d%H%M%S)"
test_project_slug="install-selftest-project"
test_transcript="$CLAUDE_DIR/projects/$test_project_slug/$test_session_id.jsonl"

start_payload="$(jq -n --arg sid "$test_session_id" --arg tp "$test_transcript" '{session_id: $sid, source: "resume", transcript_path: $tp, cwd: "/selftest", seconds_since_last_response: 9683, context_tokens: 184220, prompt_cache_likely_expired: true, estimated_cache_write_usd: 0.6912}')"
track_payload="$(jq -n --arg sid "$test_session_id" --arg tp "$test_transcript" '{session_id: $sid, tool_name: "Bash", tool_input: {command: "echo selftest"}, transcript_path: $tp, cwd: "/selftest"}')"
# Deliberately laced with an IP, a host and a secret: the log must contain none of them.
redact_payload="$(jq -n --arg sid "$test_session_id" --arg tp "$test_transcript" '{session_id: $sid, tool_name: "Bash", tool_input: {command: "ssh svc@10.1.2.3 --password hunter2trustno1"}, transcript_path: $tp, cwd: "/selftest"}')"
switch_payload="$(jq -n --arg sid "$test_session_id" --arg tp "$test_transcript" '{session_id: $sid, hook_event_name: "PostModelSwitch", transcript_path: $tp, cwd: "/selftest", from_model: "claude-opus-5", to_model: "claude-sonnet-5", requested_model: "sonnet", source: "picker", context_tokens: 184220, prompt_cache_warm: true, cache_ttl: "1h", estimated_cache_write_usd: 0.6912, pricing: "catalog"}')"

printf '%s' "$start_payload"  | bash "$START_SCRIPT_DST"
printf '%s' "$track_payload"  | bash "$TRACK_SCRIPT_DST"
printf '%s' "$redact_payload" | bash "$TRACK_SCRIPT_DST"
printf '%s' "$switch_payload" | bash "$SWITCH_SCRIPT_DST"

test_log_file="$LOG_ROOT/$test_project_slug/$test_session_id.md"
if [[ -f "$test_log_file" ]]; then
    echo "OK: smoke test log created: $test_log_file"
    echo "--- contents ---"
    cat "$test_log_file"
    echo "--- end contents ---"

    leaks=""
    grep -q '10\.1\.2\.3'     "$test_log_file" && leaks="$leaks IP-address"
    grep -q 'hunter2trustno1' "$test_log_file" && leaks="$leaks password"
    grep -q 'svc@'            "$test_log_file" && leaks="$leaks user@host"
    if [[ -n "$leaks" ]]; then
        fail "Redaction check FAILED - these reached the log:$leaks. Do not treat session-logs as safe to share."
    fi
    echo "OK: redaction check passed (no IP, host or secret in log)"

    grep -q 'ModelSwitch' "$test_log_file" \
        || echo "NOTE: model-switch line absent - expected on Claude Code older than 2.1.251"

    rm -rf "${LOG_ROOT:?}/$test_project_slug"
    echo "OK: cleaned up smoke-test artifacts"
else
    fail "Smoke test log NOT found at $test_log_file - hooks are not writing correctly."
fi

echo
echo "== Install complete =="
echo "Settings file : $SETTINGS_PATH"
[[ -n "$backup_path" ]] && echo "Backup        : $backup_path"
echo "Hook scripts  : $HOOKS_DIR"
echo "Session logs  : $LOG_ROOT/<project-slug>/<session_id>.md"
