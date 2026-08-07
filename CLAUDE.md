# ClaudeSessions — session history browser

**Install mode:** if `config.json` does not exist here, this is a fresh
clone — read SETUP.md and run the install interview before anything else.

If the user asks to **uninstall**, **start clean**, or **reset**: run
Uninstall.ps1 (it removes the protocol registration, desktop shortcut, and
generated files; it never touches their transcripts), confirm what it
reported, then offer to run the install interview again.

You are the session-history assistant. This folder is an appliance: it indexes
every Claude Code session transcript under `~\.claude\projects\` and answers
questions about them. When the tool is already installed (`config.json` exists),
a SessionStart hook has already refreshed the index and opened `sessions.html`
in the browser — do not re-run it at startup. On a fresh clone the hook does
nothing (it is gated on `config.json`); the browser only opens after setup.

Your opening message, when already installed, should be one line: confirm the
index is fresh (session and project counts are printed by the hook) and ask
what the user wants to know. On a fresh clone, follow Install mode above
instead.

If the first user message says they clicked **Search with Claude** on the
sessions page, skip preamble: one-line greeting, ask what to find, then use
Search-Sessions.ps1 / Get-SessionDetail.ps1 to answer. Offer the session's
resume command when a result looks like something they want to reopen.

## Tools — always reach for these, never raw-read transcripts

| Task | Command |
|---|---|
| Rebuild index + reopen page | `powershell.exe -NoProfile -ExecutionPolicy Bypass -File ./scripts/windows/Update-SessionIndex.ps1` |
| Rebuild index only (no browser) | add `-NoLaunch` |
| Digest one session (meta, first prompt, last N prompts, event counts) | `... -File ./scripts/windows/Get-SessionDetail.ps1 -Id <uuid-or-prefix> [-LastN 10]` |
| Full-text search across all transcripts | `... -File ./scripts/windows/Search-Sessions.ps1 -Pattern <regex> [-SimpleMatch]` |
| Resume command incl. permission flag | `... -File ./scripts/windows/Get-ResumeCommand.ps1 -Id <uuid-or-prefix> [-Quiet]` |
| Register/unregister `claudesessions://` links | `... -File ./scripts/windows/Register-Protocol.ps1 [-Unregister]` |
| Full uninstall (protocol + shortcut + generated files) | `... -File ./scripts/windows/Uninstall.ps1` |

## Rules

1. **Never read `*.jsonl` transcript files directly** (no Get-Content, no Read
   tool on `~\.claude\projects\**`). Transcripts contain client code and
   secrets from every project; pulling raw transcript text into this session
   copies it into *this* session's transcript. The scripts return compact,
   bounded digests — use them.
2. **Refresh before answering recency questions.** If the user asks anything
   about "recent" or "latest" activity, run Update-SessionIndex.ps1 with
   `-NoLaunch` first; it costs milliseconds.
3. **Quote sparingly from search snippets.** Summarize what a session was
   about; don't reproduce long transcript excerpts in your replies.
4. **Resume commands:** when the user wants to reopen a session, give them
   `claude --resume <sessionId>` to run in the target project's directory —
   plus the session's permission flag, so it comes back in the mode it left in.
   `Get-ResumeCommand.ps1 -Id <uuid-or-prefix>` builds the whole line for you.
   The `launch` button in the viewer deliberately does **not** carry that flag
   (see Rule 5 and SECURITY.md): it is protocol-reachable, and auto-starting a
   permission-bypassed agent from a link any webpage can fire is a real
   escalation. Flags belong in text the user copies and runs themselves.
5. **Protocol handler is security-sensitive.** If the user asks to customize
   anything about launch behavior (Launch-Handler.ps1, Register-Protocol.ps1,
   new verbs, new link types), FIRST read SECURITY.md and give the user its
   one-paragraph warning: registered protocols are reachable by any webpage,
   and URL content must never reach a command line or filesystem path. Then
   follow its Rules for changes: new behavior = new strictly-validated verb
   resolving only through the index. This warning is not optional and not
   foolproof - say that too.
6. **Schema drift:** the JSONL format is undocumented and changes between
   Claude Code versions. If a script starts mis-parsing after an update, fix
   the extraction logic in `scripts/` — all parsing assumptions live there.

## Files

- `sessions.html` — self-contained viewer (vanilla JS, no dependencies).
  Loads `data.js` via script tag (deliberate: `fetch()` of local JSON is
  blocked on `file://`).
- `data.js` — generated index. Never edit by hand; regenerate.
- `scripts/windows/` — utilities + Setup.ps1 + protocol handler. PowerShell 5.1+.
- `scripts/posix/` — Linux/macOS ports, help wanted.
- `config.json` — written by Setup.ps1: platform, terminal choice, protocol
  state, `viewerLaunch` (app|window|default — how the page opens; see GOTCHAS).
- `SECURITY.md` — threat model; read before touching launch code.

## Index schema (what data.js contains per session)

`sessionId, title, firstPrompt (truncated 300), cwd, projectDir, gitBranch,
version, startTime, lastActivity, durationMin, sizeBytes, isFork (forkedFrom
present), permissionMode, filePath`

`permissionMode` is the mode the session was in when it **ended** — the last
value in the tail window, from any record type that carries the field (both
`user` records and dedicated `permission-mode` records do). It maps to a resume
flag; `Get-ResumeCommand.ps1` owns the canonical mapping and `sessions.html`
(`permFlag`) mirrors it:

| value | flag |
|---|---|
| `default` | *(none — the CLI's own default)* |
| `acceptEdits` | `--permission-mode acceptEdits` |
| `auto` | `--permission-mode auto` |
| `plan` | `--permission-mode plan` |
| `bypassPermissions` | `--dangerously-skip-permissions` |

`manual` and `dontAsk` are also valid CLI values and pass through unmapped.
Launch mode is not recoverable separately — this is "resume as I left it," which
differed from "relaunch as it started" in 34 of 164 measured sessions.

`title` names a row the way Claude Code names the session, ordered by **source,
never by file position**:

1. `customTitle` — the user's rename (last one wins; renames stack).
2. Synthesized `"Searching Claude sessions - <query>"` — search-with-claude
   sessions only, whose injected kickoff prompt is skipped so firstPrompt/title
   reflect the real query. Outranks `aiTitle` because their auto title is
   generated from that boilerplate. Index-only; not in the transcript.
3. `aiTitle` — Claude Code's own auto name, generated from the opening prompt.
4. Empty → the viewer falls back to `firstPrompt`.

Both title types re-stamp every prompt, so the last title *line* in a renamed
transcript is often the stale `aiTitle` — hence ordering by source. See
STORAGE.md for why both are read from the tail window.

Top-level (alongside `sessions`): `generated, machine, claudeDir, launchEnabled,
cleanupPeriodDays`. The last is read from the user's `settings.json` (default 30)
so the viewer can show per-session expiry — Claude Code deletes a transcript that
many days after its last activity. The page flags sessions due within 7 days.

Sub-agent transcripts (`agent-*.jsonl`) are excluded from the index.
