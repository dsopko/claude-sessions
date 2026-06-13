# claude-sessions

A one-click browser for your Claude Code session history — and the Claude
session that maintains it. Indexes every transcript under `~/.claude/projects`
(head/tail reads only; milliseconds at any size), renders a self-contained
page with project grouping, instant filtering, and launch buttons that resume
sessions or start new ones in the right directory via a `claudesessions://`
protocol handler.

## Install

Claude is the installer.

```
git clone <repo> ClaudeSessions
cd ClaudeSessions
claude
> set me up
```

Claude detects your environment, asks three questions (which terminal window,
browser launch buttons yes/no, desktop shortcut yes/no), and runs one setup
command. Setup creates a "Claude Sessions" desktop icon that reopens the tool
in one click. Details live in SETUP.md.

Prefer the black window? That's Windows Terminal — if `wt` isn't recognized
on your machine, enable it under Settings > Apps > Advanced app settings >
App execution aliases, then choose it during setup.

**Platform status:** Windows native fully supported. WSL2: browse-only (index
works, cross-boundary launch not built yet). Linux/macOS: help wanted —
see `scripts/posix/README.md`.

## Manual use (no Claude needed)

```powershell
.\scripts\windows\Setup.ps1 -Terminal powershell -Protocol yes   # once
.\scripts\windows\Update-SessionIndex.ps1                        # rebuild + open page
.\scripts\windows\Get-SessionDetail.ps1 -Id 31f3f224             # digest one session
.\scripts\windows\Search-Sessions.ps1 -Pattern 'HasConversion'   # full-text grep
```

## The page

- `/` focuses the filter, Esc clears. Matches prompts, titles, paths,
  branches, ids.
- Sort by last activity / start date / duration / size; group by project.
- Amber left-edge tick = recency (bright under an hour, fading over 30 days).
- Row click: full first prompt, session id, **launch** (resume in its own
  directory), copy-ready resume command.
- Group headers: **+ new** and **continue** for that project. Buttons appear
  only when the protocol is registered (config.json drives it).

## Uninstall

```powershell
.\scripts\windows\Uninstall.ps1
```

Removes the protocol registration, the desktop shortcut, and the generated
`data.js`/`config.json`. Your transcripts under `~/.claude` are never touched.
Delete the folder afterward for full removal. Or just tell the resident
Claude "uninstall" / "start clean" — it knows the drill.

## Security

Registered protocols are reachable by any webpage. The handler validates
strictly and resolves everything through the local index, holding worst case
at "unwanted Claude window in a directory you already use." Read SECURITY.md
before customizing launch behavior — and the resident Claude will warn you
if you ask it to.

Transcripts contain file contents and command output from every project.
CLAUDE.md forbids the resident session from raw-reading them; it works
through bounded script digests.

## Gotchas

See GOTCHAS.md: file:// fetch restrictions (why data.js, not data.json),
the WSL2 9P tax, PowerShell 5.1 vs 7, protocol prompt quirks, JSONL schema
drift between Claude Code versions.

MIT license.
