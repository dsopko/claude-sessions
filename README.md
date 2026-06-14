# ClaudeSessions

Claude Sessions turns your scattered local Claude Code conversations into an
organized easy to read dashboard with simple resume alternatives.

- **Global Overview:** See all your sessions in one place, grouped by project
  and session last touched first.
- **Instant Resumption:** Resume a past session or start a fresh one in that
  project folder directly from the dashboard.
- **Deep AI Search:** Spin up a meta-session and let Claude search across every
  transcript on your computer.
- **One-Click Launch:** A desktop / Start-menu icon relaunches the dashboard
  freshly re-indexed and provides an alternative to the tired launching a terminal
  and using the terminal to navigate to  project folders.
- **100% Local:** Nothing leaves your machine.

Claude itself does the install — see below.

## Install

Claude is the installer. Open a terminal, `cd` to the directory where you want
ClaudeSessions to live, then paste:

```
git clone https://github.com/dsopko/claude-sessions.git ClaudeSessions
cd ClaudeSessions
claude "set up ClaudeSessions"
```
Claude will prompt you with set-up options.

The 'git clone' creates a `ClaudeSessions` folder containing the scripts and instructions
to install and run Claude Sessions.

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
