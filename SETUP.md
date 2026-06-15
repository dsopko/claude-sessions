# SETUP — Claude's install runbook

> **Human, looking to install this?** You're in the wrong file. SETUP.md is the
> runbook **Claude** reads to set ClaudeSessions up on your machine — it's
> written for the assistant, not steps for you to run by hand. For the human
> install instructions (clone, then `claude "set up ClaudeSessions"`), see
> **[README.md](README.md)**.

You are in **install mode** when `config.json` does not exist in this folder.
Your job: a short interview, then **one** setup command. Keep it tight — the
user is a developer; don't over-explain.

## 1. Detect the environment (read-only, no approval friction)

- Windows native: `$env:OS` is `Windows_NT` and you are not inside WSL.
- WSL: `uname -r` contains `microsoft`, or `/proc/version` mentions WSL.
- Linux / macOS: `uname -s`.

Also check what exists: `Get-Command pwsh, wt, claude -ErrorAction SilentlyContinue`
(Windows) — one command, three answers.

## 2. Platform support matrix (be honest about it)

| Platform | Index + page | Launch buttons | Status |
|---|---|---|---|
| Windows native | yes | yes (protocol handler) | supported, v2 |
| WSL2 | yes (run indexer Linux-side) | **no** — cross-boundary launch not built yet | partial |
| Linux | not yet | not yet | help wanted (`scripts/posix/`) |
| macOS | not yet | not yet | help wanted (`scripts/posix/`) |

On WSL/Linux/macOS: say exactly what works and what doesn't, offer to proceed
with what's supported (WSL: browse-only), and point at scripts/posix/README.md
for the contribution path. Do not improvise an unsupported install.

## 3. The interview (Windows native)

**Speak plainly.** Lead with what each choice does for the user; jargon goes
in parentheses or stays in the docs. Ask, with detected defaults pre-stated:

1. **Which window should sessions open in?** Phrase it by appearance, since
   that's how people know their terminals:
   - *Windows Terminal* — "the modern black window with tabs"
   - *PowerShell 7 (pwsh)* — "newer PowerShell, black window"
   - *Windows PowerShell* — "the classic blue window"
   Only offer what `Get-Command pwsh, wt` actually found. If `wt` is
   missing, check `Get-AppxPackage Microsoft.WindowsTerminal` to tell two
   cases apart:
   - **Installed, alias off:** "You have Windows Terminal, but its `wt`
     command is switched off. To get the black window: Settings > Apps >
     Advanced app settings > App execution aliases > turn on Windows
     Terminal, then pick it here."
   - **Not installed:** offer to install it — "Want the modern black
     terminal? I can install Windows Terminal with
     `winget install Microsoft.WindowsTerminal` (needs your approval)."
     If they accept, run it, verify `Get-Command wt`, then offer wt as the
     choice. If winget itself is missing, point at the Microsoft Store and
     fall back to powershell for now.

2. **Want launch buttons on the page?** Plain version: "Should clicking a
   session on the web page open it in a terminal directly — the way a Zoom
   link opens Zoom? If yes, I'll register that link type with Windows (one
   per-user setting, no admin rights). One caution: once registered, any
   website *could* try those links; this tool validates them strictly, so
   the worst case is an unwanted Claude window opening in a folder you
   already use. Details in SECURITY.md."
   Offer two options:
   - **Yes — one-click launch.** Clicking a session (and the +new / continue
     buttons) opens it in a terminal. Also enables the page's "search with
     Claude" button.
   - **No thanks — I'll resume manually.** The page still shows everything; to
     reopen a session, open a terminal in the project folder and paste its
     resume command yourself. (This also hides the "search with Claude" button,
     which needs the protocol — see the shortcut question next.)

3. **Desktop shortcut?** "Want a 'Claude Sessions' icon on your desktop?"
   Default: page. Offer three options:
   - **Yes — open the page (recommended).** Opens the sessions page directly,
     no Claude window. (If launch links are on, the page's "search with Claude"
     button covers conversational search.)
   - **Yes — open a Claude session.** Opens Claude in this folder for
     conversational search; the page pops via the startup hook. Mainly for
     people who declined launch links above — it's how you get Claude-powered
     search without the page's search button.
   - **No thanks.** No shortcut; you'll run
     `scripts/windows/Update-SessionIndex.ps1` yourself when you want to
     rebuild the index and open the page.
   If the user declined launch links and wants conversational search, steer
   them to "open a Claude session" rather than page mode.

## 4. Execute (single approval)

```powershell
powershell.exe -NoProfile -ExecutionPolicy Bypass -File ./scripts/windows/Setup.ps1 -Terminal <choice> -Protocol <yes|no> -Shortcut <page|claude|no>
```

Setup.ps1 writes config.json, registers the protocol (if yes), builds the
first index, and opens the page. It warns if `claude` isn't on PATH.

## 5. Verify and hand off

- Confirm the index line it printed ("Indexed N sessions across M projects").
- Tell the user: the page is open; `/` filters; click a row for details; if
  protocol was registered, first launch click shows a browser prompt — allow it;
  the desktop icon ("Claude Sessions") reopens this tool anytime.
- If N is 0: confirm `~\.claude\projects` exists and has project folders;
  if their Claude data lives elsewhere, re-run with `-ClaudeDir`.

## 6. After install

You are in normal operating mode — follow CLAUDE.md. If the user later asks
to customize launch behavior, read SECURITY.md first and surface its warning
before changing code.
