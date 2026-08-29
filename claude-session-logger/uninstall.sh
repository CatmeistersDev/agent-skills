#!/usr/bin/env bash
# Claude Session Logger uninstaller (Linux/macOS)
set -euo pipefail

CLAUDE_DIR="$HOME/.claude"
SETTINGS_PATH="$CLAUDE_DIR/settings.json"
HOOKS_DIR="$CLAUDE_DIR/hooks"

if [[ ! -f "$SETTINGS_PATH" ]]; then
    echo "No settings.json found at $SETTINGS_PATH - nothing to do."
    exit 0
fi

command -v jq >/dev/null 2>&1 || { echo "FAIL: 'jq' is required but not found on PATH." >&2; exit 1; }

stamp="$(date +%Y%m%d-%H%M%S)"
backup_path="$SETTINGS_PATH.bak-preuninstall-$stamp"
cp "$SETTINGS_PATH" "$backup_path"
echo "OK: backed up settings.json to $backup_path"

for evt in SessionStart PostToolUse PreModelSwitch PostModelSwitch; do
    before_count="$(jq --arg evt "$evt" '(.hooks[$evt] // []) | length' "$SETTINGS_PATH")"
    tmp="$(mktemp)"
    jq --arg evt "$evt" '
        .hooks[$evt] = ((.hooks[$evt] // []) | map(select(
            ((.hooks // []) | any((.command // "") | test("session_log_start\\.sh|session_log_track\\.sh|session_log_model_switch\\.sh"))) | not
        )))
    ' "$SETTINGS_PATH" >"$tmp"
    mv "$tmp" "$SETTINGS_PATH"
    after_count="$(jq --arg evt "$evt" '(.hooks[$evt] // []) | length' "$SETTINGS_PATH")"
    echo "Removed $((before_count - after_count)) block(s) from $evt"
done

jq -e '.' "$SETTINGS_PATH" >/dev/null 2>&1 || { echo "FAIL: settings.json failed validation after edit - restore from $backup_path" >&2; exit 1; }
echo "OK: wrote updated settings.json (hook entries removed)"

if [[ -d "$HOOKS_DIR" ]]; then
    rm -f "$HOOKS_DIR/session_log_start.sh" "$HOOKS_DIR/session_log_track.sh" "$HOOKS_DIR/session_log_model_switch.sh"
    echo "OK: removed hook script files (session-logs data left intact)"
fi

echo
echo "Uninstall complete. Backup: $backup_path"
