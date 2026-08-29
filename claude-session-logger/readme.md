# Claude Session Logger

A global Claude Code hook set that automatically logs every session start, every
model switch, and every file-edit / Bash / infrastructure-mutating tool call to a
per-session Markdown file, organized by project. No per-project setup — once
installed, it logs activity in *every* project you open Claude Code in.

Logged values are **redacted before they hit disk**: IP addresses, hostnames,
`user@host` targets and common secret shapes are stripped. See
[Redaction](#redaction) — it is a best-effort filter, not a guarantee.

## What it logs

For each session, a Markdown file is created at:

```
~/.claude/session-logs/<project-slug>/<session-id>.md
```

It contains:

- A **Session start** header (timestamp + source: `startup`, `resume`, `clear`,
  `compact`, or `fork`). On `resume`/`fork` it also records how long the session
  sat idle, whether the prompt cache has likely expired, and the estimated cost
  of re-caching the context.
- One line per interesting tool call.
- One line per model switch, with the re-cache cost of that switch.

```markdown
## Session start - 2026-08-28T19:45:10 (source: resume) - idle 02:41:23, cache EXPIRED, re-cache 184,220 tok ~$0.6912

- 2026-08-28T19:46:01 | Edit | /home/<user>/project/main.py
- 2026-08-28T19:46:30 | Bash | git status
- 2026-08-28T19:46:44 | Bash | ssh <user>@<host> mdcmd status
- 2026-08-28T19:47:12 | mcp__proxmox__start | vmid=101
- 2026-08-28T19:48:02 | ModelSwitch | claude-opus-5 -> claude-sonnet-5 (req=sonnet via picker) | re-cache 184,220 tok ~$0.6912 [catalog]
```

Logged tools: `Edit`, `Write`, `NotebookEdit`, `Bash`, and any MCP tool whose
name matches `(start|stop|create|delete|restart|clone|restore|update|set|execute)`
(i.e. infrastructure-mutating actions). Read-only tools are not logged.

The model-switch lines require **Claude Code 2.1.251 or newer**, which is when
`PreModelSwitch` / `PostModelSwitch` were added. On older builds those events
never fire and the rest of the logger works unchanged.

## Redaction

Everything written to a log line passes through a sanitizer first
(`Protect-Sensitive` in PowerShell, `sanitize()` in bash — rule-for-rule
equivalent). It replaces:

| Input | Logged as |
|---|---|
| Your home directory | `~` |
| `/home/<name>`, `C:\Users\<name>` | `/home/<user>`, `C:\Users\<user>` |
| `root@10.0.0.5`, `admin@box.local` | `<user>@<host>` |
| `https://host/path` | `https://<host>/path` |
| IPv4 (with optional port), full-form IPv6 | `<ip>` |
| Hostnames on `.local .internal .lan .home .corp .intranet .arpa` | `<host>` |
| `--host X`, `--server X`, `--node X`, `--endpoint X`, `--target X` | `<host>` |
| `ghp_…`, `glpat-…`, `sk-…`, `AKIA…` | `<redacted>` |
| `password=X`, `token: X`, `api-key: X`, `Authorization: X` | `<redacted>` |
| MCP `node=` / `name=` (server names) | `node=<redacted>` |

MCP `vmid`, `container_id` and `id` are kept — they are opaque numeric handles,
not names. Both installers run a redaction self-test at the end and **fail the
install** if a planted IP, host or password survives into the log.

**This is a filter, not a guarantee.** It cannot catch a bare internal hostname
with no dots and no flag (`ssh buildbox`), a secret passed positionally
(`mytool AKIAsomething` is caught, `mytool s3cr3t` is not), or a credential
inside a file the command reads. Treat `session-logs/` as sensitive even so.

Set `CLAUDE_SESSION_LOG_RAW=1` to disable redaction and log verbatim.

## Files

| File | Purpose |
|---|---|
| `install.sh` / `install.ps1` | Installs hooks into `~/.claude` (Linux/macOS / Windows) |
| `uninstall.sh` / `uninstall.ps1` | Removes hooks, leaves existing logs in place |
| `hooks/session_log_start.{sh,ps1}` | `SessionStart` hook — writes the session header |
| `hooks/session_log_track.{sh,ps1}` | `PostToolUse` hook — appends one line per tool call |
| `hooks/session_log_model_switch.{sh,ps1}` | `PreModelSwitch` / `PostModelSwitch` hook — one line per model change (needs 2.1.251+) |
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
4. Run a smoke test, print the log file it wrote, and assert that a planted IP,
   hostname and password were all redacted out of it

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
