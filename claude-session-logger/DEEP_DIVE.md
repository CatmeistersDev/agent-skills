# Claude Session Logger - Deep Dive

## Overview
This is a set of Claude Code hooks that write a running Markdown activity log
for every Claude Code session, across every project, without needing any
per-project configuration. It replaces an earlier version that was Python-based
and configured per-project (originally only in `X:\Project Folder`).

Everything written to a log line is passed through a redaction filter first, so
IP addresses, hostnames, `user@host` targets and common secret shapes do not
reach disk. See "Redaction" below for the rules and their limits.

## Architecture
Claude Code reads hook configuration from `settings.json` files at multiple
scopes (user-level `~/.claude/settings.json`, project-level `.claude/settings.json`,
and `.claude/settings.local.json`). Hooks from different scopes for the same
event **merge together (union) rather than override** - if the same hook is
also defined at a project level, it will fire twice for that project. This
system is installed at the **user level only**, so it applies uniformly.

Four events are used:
- `SessionStart` - fires once when a Claude Code session begins. Runs
  `session_log_start.ps1`, which writes a `## Session start` header line.
- `PostToolUse` - fires after each tool call matching the configured matcher.
  Runs `session_log_track.ps1`, which appends one log line per call.
- `PreModelSwitch` / `PostModelSwitch` - fire before and after the session model
  changes. Both run `session_log_model_switch.ps1`, which branches on
  `hook_event_name` and appends one line per switch. **Added in Claude Code
  2.1.251**; on older builds these events never fire, so the installed entries
  are inert rather than broken.

For `PreModelSwitch` and `PostModelSwitch` the `matcher` is tested against
**`to_model`**, not a tool name (with any `[1m]` / `[2m]` context-window suffix
stripped first). `"*"` therefore catches every switch; a matcher like
`claude-opus-5` would log only switches *into* that model.

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
  ],
  "PreModelSwitch": [
    {
      "matcher": "*",
      "hooks": [
        { "type": "command", "command": "bash \"<path>/session_log_model_switch.sh\"" }
      ]
    }
  ],
  "PostModelSwitch": [
    {
      "matcher": "*",
      "hooks": [
        { "type": "command", "command": "bash \"<path>/session_log_model_switch.sh\"" }
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
  ],
  "PreModelSwitch": [
    {
      "matcher": "*",
      "hooks": [
        { "type": "command", "command": "powershell.exe", "args": ["-NoProfile", "-ExecutionPolicy", "Bypass", "-File", "<path>\\session_log_model_switch.ps1"] }
      ]
    }
  ],
  "PostModelSwitch": [
    {
      "matcher": "*",
      "hooks": [
        { "type": "command", "command": "powershell.exe", "args": ["-NoProfile", "-ExecutionPolicy", "Bypass", "-File", "<path>\\session_log_model_switch.ps1"] }
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
| `mcp__*` | first present of `vmid`/`container_id`/`id` from `tool_input`, as `key=value`; failing that, `node=<redacted>` or `name=<redacted>` |
| anything else | empty string |

`vmid`, `container_id` and `id` are opaque numeric handles and are kept
verbatim. `node` and `name` are host or server names, so only their *presence*
is recorded - the value never reaches the log.

The result is then passed through the redaction filter (below) before it is
written, so even the kept fields cannot smuggle a hostname through.

## Model-switch events

`PreModelSwitch` and `PostModelSwitch` were added in Claude Code 2.1.251 and are
not yet in the published hooks reference. The payload each receives:

| Field | Meaning |
|---|---|
| `from_model` | Resolved model id the session was running before the switch |
| `to_model` | Resolved model id the session runs after it |
| `requested_model` | What was asked for - an alias like `opus`, a full id, or `null` for "default" |
| `source` | `command`, `picker`, `sdk`; `PostModelSwitch` adds `auto` and `resume` |
| `context_tokens` | Prompt tokens the next request re-sends |
| `prompt_cache_warm` | Whether the current model's cache is likely still warm (so a switch forfeits it) |
| `cache_ttl` | `5m` or `1h` |
| `estimated_cache_write_usd` | Cost of re-caching `context_tokens` on `to_model` |
| `pricing` | `configured` (managed `modelPricing`), `catalog` (list price), or `default` (tier assumed) |

`PreModelSwitch` can also *gate* the switch by writing a JSON object to stdout,
using the same contract as `PreToolUse`:

```json
{ "hookSpecificOutput": {
    "hookEventName": "PreModelSwitch",
    "permissionDecision": "ask",
    "permissionDecisionReason": "why" } }
```

`allow` proceeds and skips the interactive cache-miss confirmation, `deny`
cancels the switch, and `ask` forces a confirmation prompt (a headless session
refuses instead). `PostModelSwitch` instead accepts `additionalContext`, a
string that reaches the model on the next request the new model serves. Both
hook scripts ship with these blocks written out but commented off - the default
behaviour is to log and nothing else.

`SessionStart` gained matching fields in the same release, present only when
`source` is `resume` or `fork`: `seconds_since_last_response`, `context_tokens`,
`prompt_cache_likely_expired`, and `estimated_cache_write_usd`. They are absent
on a normal startup, so the header line degrades cleanly to its original form.

## Redaction

`Protect-Sensitive` (PowerShell) and `sanitize()` (bash) are rule-for-rule
equivalents applied to every logged value. Rules run in this order:

| # | Rule | Result |
|---|---|---|
| 1 | `$HOME` / `%USERPROFILE%` prefix | `~` |
| 2 | `/home/<name>`, `/Users/<name>`, `C:\Users\<name>` | `<user>` |
| 3 | `user@host` (ssh/scp/rsync targets, emails) | `<user>@<host>` |
| 4 | `scheme://host/...` | `scheme://<host>/...` |
| 5 | IPv4 with optional port; full-form IPv6 | `<ip>` |
| 6 | Hostnames on `.local .internal .lan .home .corp .intranet .arpa` | `<host>` |
| 7 | `--host` `--hostname` `--server` `--node` `--endpoint` `--target` + value | `<host>` |
| 8 | `ghp_… gho_… glpat-… gldt-… sk-… AKIA…` | `<redacted>` |
| 9 | `password` `passwd` `pwd` `token` `secret` `api-key` `apikey` `authorization` `bearer` + value | `<redacted>` |

Set `CLAUDE_SESSION_LOG_RAW=1` in the environment to bypass all of it and log
verbatim.

Design notes:
- The bash version deliberately avoids `\b` and backslash-inside-bracket
  constructs, because BSD/macOS `sed` and GNU `sed` disagree about both.
  A `[^\\/[:space:]]` bracket is a hard parse error on some `sed` builds.
- The IPv6 rule matches only the full eight-group form, so it cannot eat a
  timestamp like `19:53:36`.
- Rule 6 is restricted to a fixed list of private-use TLDs on purpose. A general
  "anything with a dot" rule would rewrite `main.py`, `settings.json` and
  `install.sh` into `<host>`, destroying the log's usefulness.

### What redaction does *not* catch
- A bare internal hostname with no dot and no flag: `ssh buildbox`, `ping nas`.
- A secret passed positionally with no recognisable prefix: `mytool s3cr3t`.
- Credentials inside a file the logged command reads rather than on its command
  line.
- Anything beyond the 80-character `Bash` truncation is never seen, which cuts
  both ways - it can hide a leak from the filter's view *and* from the log.

Both installers plant an IP, a `user@host` and a password in a synthetic tool
call during the smoke test and **fail the install** if any of them survives into
the log file. That check is the intended regression test for these rules.

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
| `~/.claude/hooks/session_log_model_switch.sh` | `%USERPROFILE%\.claude\hooks\session_log_model_switch.ps1` | PreModelSwitch + PostModelSwitch handler |
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
- Both end with a self-test: synthesize fake SessionStart/PostToolUse/PostModelSwitch JSON payloads, pipe them into the just-installed scripts, and verify a real log file was written with the expected content - then delete that test artifact. The `SessionStart` payload uses `source: "resume"` so the prompt-cache fields are exercised too.
- One of those synthetic payloads is a `Bash` call laced with an IP, a `user@host` target and a password. After the log is written the installer greps for all three and **aborts the install** if any survived, so a broken redaction rule fails loudly at install time instead of silently leaking for weeks.
- The model-switch line is checked for but not required: if it is missing the installer prints a note that this is expected below Claude Code 2.1.251, rather than failing.
- Both uninstallers mirror this: back up settings.json, remove only the hook blocks that reference `session_log_start.*`/`session_log_track.*` (leaving any unrelated hooks alone - `uninstall.sh` matches via a `jq` regex `test()`, `uninstall.ps1` via a PowerShell regex match), and delete the two script files. Neither touches existing session-logs data.

## Known issues & troubleshooting
- **`jq` not on PATH (Linux/macOS)**: `install.sh` hard-fails with an install hint (`pacman`/`apt`/`brew`) rather than silently degrading, since every hook script and both installer scripts depend on it for JSON parsing.
- **Execution policy / Group Policy locks (Windows only)**: `-ExecutionPolicy Bypass` on the invocation covers the default case, but a machine locked down via Group Policy (`AllSigned`/`Restricted` enforced machine-wide) can still block script execution. If hooks silently produce no logs, run a hook script manually (`echo '{}' | powershell.exe -File <path>`) and check for a policy error.
- **Antivirus/EDR flagging (Windows only)**: some corporate endpoint security tools flag PowerShell scripts run with `-ExecutionPolicy Bypass`. If logs aren't appearing, check the AV/EDR quarantine or alert log for the hook script paths.
- **Hook script not executable (Linux/macOS)**: `install.sh` `chmod +x`s both scripts, but if you copy them manually afterward the executable bit won't carry over automatically on every filesystem/tool - `bash "<path>"` in the hook command works regardless since it's invoked via the interpreter explicitly, but running the script directly (`./session_log_track.sh`) needs the bit set.
- **Sensitive data in logs**: `Bash` tool calls are logged with the first 80 characters of the raw command. The redaction filter (see "Redaction") strips IPs, hostnames, `user@host` targets and common secret shapes before writing, and the installers fail if a planted secret survives - but it is a pattern filter, not a guarantee. A bare hostname (`ssh buildbox`) or an unlabelled positional secret still gets through. Treat `session-logs/` as sensitive: don't sync it to cloud storage or shared drives without review, and don't commit it to a repo.
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
