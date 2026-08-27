# Claude Session Logger

A global Claude Code hook pair that automatically logs every session start and
every file-edit / Bash / infrastructure-mutating tool call to a per-session
Markdown file, organized by project. No per-project setup — once installed, it
logs activity in *every* project you open Claude Code in.

## What it logs

For each session, a Markdown file is created at:

```
~/.claude/session-logs/<project-slug>/<session-id>.md
```

It contains:

- A **Session start** header (timestamp + source: `startup`, `resume`, or `clear`)
- One line per interesting tool call:

```markdown
## Session start - 2024-08-22T22:45:10 (source: startup)

- 2024-08-22T22:46:01 | Edit | /home/user/project/main.py
- 2024-08-22T22:46:30 | Bash | git status
- 2024-08-22T22:47:12 | mcp__proxmox__start | vmid=101
```

Logged tools: `Edit`, `Write`, `NotebookEdit`, `Bash`, and any MCP tool whose
name matches `(start|stop|create|delete|restart|clone|restore|update|set|execute)`
(i.e. infrastructure-mutating actions). Read-only tools are not logged.

## Files

| File | Purpose |
|---|---|
| `install.sh` / `install.ps1` | Installs hooks into `~/.claude` (Linux/macOS / Windows) |
| `uninstall.sh` / `uninstall.ps1` | Removes hooks, leaves existing logs in place |
| `hooks/session_log_start.{sh,ps1}` | `SessionStart` hook — writes the session header |
| `hooks/session_log_track.{sh,ps1}` | `PostToolUse` hook — appends one line per tool call |
| `QUICK_INSTALL.md` | Step-by-step install instructions |
| `DEEP_DIVE.md` | Architecture details, known issues & troubleshooting |

## Quick start

### Linux / macOS
```bash
./install.sh
```
Requires `jq` on PATH (`sudo apt install jq` / `brew install jq`).

### Windows
```powershell
.\install.ps1
```
Requires PowerShell 5.1+ (built-in).

Both installers:

1. Copy the hook scripts to `~/.claude/hooks/`
2. Back up your existing `settings.json`
3. Merge the hook config in (existing settings are preserved; re-running won't duplicate entries)
4. Run a smoke test and print the log file it wrote

## Verify

Open Claude Code, edit a file or run a Bash command, then check
`~/.claude/session-logs/<project-name>/<session-id>.md` — a new line should
appear for each tool call.

## Uninstall

```bash
./uninstall.sh        # Linux/macOS
.\uninstall.ps1       # Windows
```

Removes the hook entries from `settings.json` (backed up first) and deletes
the hook scripts. Existing logs are left in place.

## Troubleshooting

- Hook errors are written to `~/.claude/session-logs/errors.log`
- See `DEEP_DIVE.md` → "Known issues & troubleshooting" for details
