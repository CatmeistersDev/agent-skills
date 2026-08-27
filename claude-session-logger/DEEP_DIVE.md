# Claude Session Logger - Deep Dive

## Overview
This is a pair of Claude Code hooks that write a running Markdown activity log
for every Claude Code session, across every project, without needing any
per-project configuration. It replaces an earlier version that was Python-based
and configured per-project (originally only in `X:\Project Folder`).

## Architecture
Claude Code reads hook configuration from `settings.json` files at multiple
scopes (user-level `~/.claude/settings.json`, project-level `.claude/settings.json`,
and `.claude/settings.local.json`). Hooks from different scopes for the same
event **merge together (union) rather than override** - if the same hook is
also defined at a project level, it will fire twice for that project. This
system is installed at the **user level only**, so it applies uniformly.

Two events are used:
- `SessionStart` - fires once when a Claude Code session begins. Runs
  `session_log_start.ps1`, which writes a `## Session start` header line.
- `PostToolUse` - fires after each tool call matching the configured matcher.
  Runs `session_log_track.ps1`, which appends one log line per call.

Per the official Claude Code hooks docs, a `"type": "command"` hook's
`command` string is executed **via a shell** (not exec'd directly), and the
JSON event payload is delivered on **stdin** - so a plain shell command
string that pipes stdin into a script works on both platforms; only the
interpreter differs.

- **Linux/macOS**: `command: bash "<path>/session_log_*.sh"` - spawns bash
  directly with the hook script as its argument. No Python dependency (the
  original version required Python on PATH); `jq` is the only runtime
  dependency, used for all JSON parsing in the hook scripts.
- **Windows**: `command: powershell.exe`, `args: [...]` (exec form) - spawns
  PowerShell directly without going through a shell (bash/cmd), so no
  dependency on Git Bash being installed either.

### The exact hooks JSON block each installer adds

Linux/macOS (`install.sh`):
```json
"hooks": {
  "SessionStart": [
    {
      "matcher": "*",
      "hooks": [
        { "type": "command", "command": "bash \"<path>/session_log_start.sh\"" }
      ]
    }
  ],
  "PostToolUse": [
    {
      "matcher": "Edit|Write|NotebookEdit|Bash",
      "hooks": [
        { "type": "command", "command": "bash \"<path>/session_log_track.sh\"" }
      ]
    },
    {
      "matcher": "^mcp__.*__(start|stop|create|delete|restart|clone|restore|update|set|execute).*",
      "hooks": [
        { "type": "command", "command": "bash \"<path>/session_log_track.sh\"" }
      ]
    }
  ]
}
```

Windows (`install.ps1`):
```json
"hooks": {
  "SessionStart": [
    {
      "matcher": "*",
      "hooks": [
        { "type": "command", "command": "powershell.exe", "args": ["-NoProfile", "-ExecutionPolicy", "Bypass", "-File", "<path>\\session_log_start.ps1"] }
      ]
    }
  ],
  "PostToolUse": [
    {
      "matcher": "Edit|Write|NotebookEdit|Bash",
      "hooks": [
        { "type": "command", "command": "powershell.exe", "args": ["-NoProfile", "-ExecutionPolicy", "Bypass", "-File", "<path>\\session_log_track.ps1"] }
      ]
    },
    {
      "matcher": "^mcp__.*__(start|stop|create|delete|restart|clone|restore|update|set|execute).*",
      "hooks": [
        { "type": "command", "command": "powershell.exe", "args": ["-NoProfile", "-ExecutionPolicy", "Bypass", "-File", "<path>\\session_log_track.ps1"] }
      ]
    }
  ]
}
```
The third matcher (both platforms) generalizes the original's hardcoded
proxmox/unraid-only MCP matcher to catch any MCP tool call across any server
whose name ends in a mutating verb
(start/stop/create/delete/restart/clone/restore/update/set/execute).

## What gets logged, and how
`session_log_track.sh` (`session_log_track.ps1` on Windows) decides what to
record per tool via `get_target`:
| tool_name | logged value |
|---|---|
| `Edit`, `Write` | `tool_input.file_path` |
| `NotebookEdit` | `tool_input.notebook_path` (or `file_path` if absent) |
| `Bash` | first 80 characters of `tool_input.command`, newlines flattened to spaces |
| `mcp__*` | first present of `vmid`/`node`/`name`/`container_id`/`id` from `tool_input`, as `key=value` |
| anything else | empty string |

## Log location and project-slug derivation
Logs land at:
```
~/.claude/session-logs/<project-slug>/<session-id>.md
```
(`%USERPROFILE%\.claude\session-logs\<project-slug>\<session-id>.md` on Windows.)
`<project-slug>` is derived from the hook payload's `transcript_path` field
(the parent folder name of the session's `.jsonl` transcript under
`~/.claude/projects/`) - this exactly matches Claude Code's own project-folder
naming convention, so log folders line up 1:1 with `~/.claude/projects/*`. If
`transcript_path` is ever absent, it falls back to sanitizing `cwd` by
replacing `:`, `\`, `/`, `.`, and spaces with `-`.

Note: `cwd` follows Claude Code into a git worktree, but `transcript_path`
(and therefore the project-slug used here) stays tied to the *original*
project - so worktree sessions log under their parent project's folder, not a
separate one. This is intentional (keeps a project's history in one place).

## File inventory
| Installed file (Linux/macOS) | Installed file (Windows) | Purpose |
|---|---|---|
| `~/.claude/hooks/session_log_start.sh` | `%USERPROFILE%\.claude\hooks\session_log_start.ps1` | SessionStart handler |
| `~/.claude/hooks/session_log_track.sh` | `%USERPROFILE%\.claude\hooks\session_log_track.ps1` | PostToolUse handler |
| `~/.claude/settings.json` | `%USERPROFILE%\.claude\settings.json` | merged hook config (backed up before edit) |
| `~/.claude/settings.json.bak-<timestamp>` | `%USERPROFILE%\.claude\settings.json.bak-<timestamp>` | pre-install backup, created every install run |
| `~/.claude/session-logs/<project-slug>/<session-id>.md` | `%USERPROFILE%\.claude\session-logs\<project-slug>\<session-id>.md` | per-session log |
| `~/.claude/session-logs/errors.log` | `%USERPROFILE%\.claude\session-logs\errors.log` | hook-internal errors, if any (should normally be empty) |

## Install/uninstall internals
- Both installers always back up the existing `settings.json` before touching it, with a timestamped filename.
- Both parse the existing file as JSON first (`jq -e '.'` on Linux/macOS, `ConvertFrom-Json` on Windows); if that fails, they abort with no changes made (never overwrite a file they can't understand).
- After merging in the hook blocks, both re-validate the resulting JSON before/after writing - if that ever fails, they abort rather than leave a broken file.
- `install.sh` writes through `jq`, which is UTF-8 and BOM-free by construction. (`install.ps1` writes UTF-8 **without a BOM** deliberately - `Set-Content -Encoding UTF8` in Windows PowerShell 5.1 adds a BOM by default, avoided there via `[System.IO.File]::WriteAllText`.)
- Both are idempotent: re-running detects hook blocks that already reference the installed script paths (by array-length comparison in `install.sh`, by a `Block-HasScript` regex match in `install.ps1`) and skips re-adding them.
- Both end with a self-test: synthesize fake SessionStart/PostToolUse JSON payloads, pipe them into the just-installed scripts, and verify a real log file was written with the expected content - then delete that test artifact.
- Both uninstallers mirror this: back up settings.json, remove only the hook blocks that reference `session_log_start.*`/`session_log_track.*` (leaving any unrelated hooks alone - `uninstall.sh` matches via a `jq` regex `test()`, `uninstall.ps1` via a PowerShell regex match), and delete the two script files. Neither touches existing session-logs data.

## Known issues & troubleshooting
- **`jq` not on PATH (Linux/macOS)**: `install.sh` hard-fails with an install hint (`pacman`/`apt`/`brew`) rather than silently degrading, since every hook script and both installer scripts depend on it for JSON parsing.
- **Execution policy / Group Policy locks (Windows only)**: `-ExecutionPolicy Bypass` on the invocation covers the default case, but a machine locked down via Group Policy (`AllSigned`/`Restricted` enforced machine-wide) can still block script execution. If hooks silently produce no logs, run a hook script manually (`echo '{}' | powershell.exe -File <path>`) and check for a policy error.
- **Antivirus/EDR flagging (Windows only)**: some corporate endpoint security tools flag PowerShell scripts run with `-ExecutionPolicy Bypass`. If logs aren't appearing, check the AV/EDR quarantine or alert log for the hook script paths.
- **Hook script not executable (Linux/macOS)**: `install.sh` `chmod +x`s both scripts, but if you copy them manually afterward the executable bit won't carry over automatically on every filesystem/tool - `bash "<path>"` in the hook command works regardless since it's invoked via the interpreter explicitly, but running the script directly (`./session_log_track.sh`) needs the bit set.
- **Sensitive data in logs**: `Bash` tool calls are logged with the first 80 characters of the raw command. If a command embeds a secret early (e.g. `curl -H "x-api-key: ..."`), that secret will land in plaintext in the log file. Treat `session-logs/` as sensitive - don't sync it to cloud storage or shared drives without review.
- **No log rotation**: logs grow unbounded, one file per session, forever. There's no automatic cleanup; periodically prune `session-logs/` manually if disk space matters.
- **Duplicate logging risk**: if a project still has its own project-level hook pointing at an old logging mechanism, every tool call in that project will log twice once this global hook is active too, because Claude Code merges hooks from different scopes rather than overriding. Remove any old project-level hook block once this global one is confirmed working.
- **Malformed settings.json from manual edits**: if you hand-edit `settings.json` after installing, a JSON syntax error can silently break Claude Code startup. Always validate with `jq -e '.' ~/.claude/settings.json` (or `Get-Content settings.json -Raw | ConvertFrom-Json` on Windows) before saving a manual edit, and keep the `.bak-*` file as a rollback point.
- **`powershell.exe` vs `pwsh.exe`**: the Windows scripts target Windows PowerShell 5.1 syntax specifically (no `??`, no ternary), since `powershell.exe` ships on every Windows install by default. If you port that variant to PowerShell 7 (`pwsh.exe`), update the `command` field in the hooks JSON accordingly. Not applicable to the Linux/macOS bash port.

## Rollback
Run `uninstall.sh` (or `uninstall.ps1` on Windows), or manually restore the
most recent `settings.json.bak-*` file over `settings.json` if something goes
wrong and the uninstaller itself can't run.

## Changes from the original per-project Python version
| Aspect | Original | Windows version | Linux/macOS version |
|---|---|---|---|
| Scope | Project-level (`X:\Project Folder\.claude\settings.json` only) | User-level (`~/.claude/settings.json`, all projects) | User-level (`~/.claude/settings.json`, all projects) |
| Language/runtime | Python (external dependency) | PowerShell (built into Windows) | bash + jq |
| Log location | `.claude\projects\X--Project Folder\session-logs\` | `.claude\session-logs\<project-slug>\` | `.claude/session-logs/<project-slug>/` |
| MCP matcher | Hardcoded to proxmox-*/unraid-mcp tool names | Generalized to any `mcp__*__<mutating-verb>*` | Generalized to any `mcp__*__<mutating-verb>*` |

## Linux port notes
`session_log_start.sh`/`session_log_track.sh` are a line-for-line behavioral
port of the `.ps1` originals, verified via `claude-code-guide` against the
official hooks docs before writing:
- Hook `command` strings run through a **shell** (not exec'd directly), and
  the event JSON arrives on **stdin** - both true on Windows and Linux/macOS,
  which is what makes a straight `bash "<script>"` command line work the same
  way `powershell.exe -File <script>` does.
- `get_target` (bash) mirrors `Get-Target` (PowerShell) tool-for-tool: same
  field precedence for `NotebookEdit` (`notebook_path` then `file_path`), same
  80-char truncation + newline-flattening for `Bash` commands, same
  first-present-key lookup (`vmid`/`node`/`name`/`container_id`/`id`) for
  `mcp__*` tools.
- Project-slug derivation is identical: `basename(dirname(transcript_path))`
  when `transcript_path` is present, else `cwd` with `:`, `/`, `\`, `.`, and
  whitespace replaced by `-` (a `sed -E 's|[:/\\. \t]|-|g'` equivalent of the
  PowerShell regex).
- Error handling mirrors the PowerShell `try/catch` shape: every hook script
  wraps its body in a function, logs any failure to `session-logs/errors.log`,
  and always exits `0` so a hook failure never blocks the tool call it's
  attached to.
