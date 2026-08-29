# Claude Session Logger - Quick Install

## What this is
A Claude Code hook set that automatically logs every session start, every model
switch, and every file-editing / Bash / infrastructure-mutating tool call to a
Markdown file per session, organized by project. Runs globally - once installed,
it logs activity in *every* project you open Claude Code in. No per-project setup.

IP addresses, hostnames, `user@host` targets and common secret shapes are
redacted before anything is written to disk. See `readme.md` -> "Redaction" for
the rule table and its limits.

## Prerequisites

### Linux / macOS
- `jq` on PATH (e.g. `sudo pacman -S jq` / `sudo apt install jq` / `brew install jq`)
- Claude Code already installed and run at least once (so `~/.claude` exists)

### Windows
- Windows with PowerShell 5.1+ (built in, nothing to install)
- Claude Code already installed and run at least once (so `%USERPROFILE%\.claude` exists)

### Both
- Claude Code **2.1.251+** for the model-switch log lines. Everything else works
  on older builds; the `PreModelSwitch`/`PostModelSwitch` entries just sit inert
  because the events never fire.

## Install

### Linux / macOS
1. Copy this whole `claude-session-logger` folder anywhere on the target machine.
2. Run:
   ```bash
   cd path/to/claude-session-logger
   ./install.sh
   ```
3. The installer will:
   - Copy the three hook scripts (bash, using `jq` for JSON) to `~/.claude/hooks/`
   - Back up your existing `~/.claude/settings.json`
   - Merge the hook config into it (existing settings are preserved untouched)
   - Run a self-test and print the actual file it wrote
   - Assert a planted IP, hostname and password were redacted, and **fail the
     install** if any of them survived

### Windows
1. Copy this whole `claude-session-logger` folder anywhere on the target machine.
2. Open PowerShell and run:
   ```powershell
   cd "path\to\claude-session-logger"
   .\install.ps1
   ```
3. Same steps as above, but deploys to `%USERPROFILE%\.claude\hooks\` and uses
   PowerShell hook scripts.

Re-running either installer is safe - it detects existing entries and won't duplicate them.

## Verify it worked
Open Claude Code, do anything (edit a file, run a Bash command), then check:
```
~/.claude/session-logs/<project-name>/<session-id>.md
```
(`%USERPROFILE%\.claude\session-logs\...` on Windows.) A new line should
appear for each tool call, and a `ModelSwitch` line whenever you change model
with `/model` or the picker.

## Uninstall
```bash
./uninstall.sh        # Linux/macOS
```
```powershell
.\uninstall.ps1        # Windows
```
Removes the hook entries from settings.json (backed up first) and deletes the
hook script files. Existing logs are left in place.

## Something wrong?
See `DEEP_DIVE.md` -> "Known issues & troubleshooting".
