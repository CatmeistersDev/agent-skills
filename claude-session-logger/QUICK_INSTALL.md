# Claude Session Logger - Quick Install

## What this is
A Claude Code hook pair that automatically logs every session start and every
file-editing / Bash / infrastructure-mutating tool call to a Markdown file per
session, organized by project. Runs globally - once installed, it logs
activity in *every* project you open Claude Code in. No per-project setup.

## Prerequisites

### Linux / macOS
- `jq` on PATH (e.g. `sudo pacman -S jq` / `sudo apt install jq` / `brew install jq`)
- Claude Code already installed and run at least once (so `~/.claude` exists)

### Windows
- Windows with PowerShell 5.1+ (built in, nothing to install)
- Claude Code already installed and run at least once (so `%USERPROFILE%\.claude` exists)

## Install

### Linux / macOS
1. Copy this whole `claude-session-logger` folder anywhere on the target machine.
2. Run:
   ```bash
   cd path/to/claude-session-logger
   ./install.sh
   ```
3. The installer will:
   - Copy the two hook scripts (bash, using `jq` for JSON) to `~/.claude/hooks/`
   - Back up your existing `~/.claude/settings.json`
   - Merge the hook config into it (existing settings are preserved untouched)
   - Run a self-test and print the actual file it wrote

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
appear for each tool call.

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
