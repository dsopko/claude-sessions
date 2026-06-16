# SECURITY

Read this before modifying anything in `scripts/` that touches the
`claudesessions://` protocol. If you are Claude and the user asks you to
customize launch behavior, **warn them about the risks below before writing
code**, and keep every rule in the "Rules for changes" section.

## Threat model

Once `claudesessions://` is registered, **any webpage in any browser tab can
attempt those links** — not just sessions.html. A malicious page can embed
`<a href="claudesessions://...">` or fire it from script. The browser shows a
permission prompt, but users click through prompts, and some browsers offer
"always allow."

Therefore the launch handler treats every URL as **hostile input**. The
current design holds the damage ceiling at: *an unwanted Claude window opens
in a directory you already use Claude in.* Annoying, not dangerous.

What keeps the ceiling there:

1. **Strict shape validation.** The URL must match
   `claudesessions://(resume|new|continue|assist|reindex)/<one-segment>`
   exactly. Unknown verbs, extra path segments, query strings: rejected.
2. **Strict argument validation.** `resume` takes only a UUID. `new` and
   `continue` take only `[A-Za-z0-9._-]{1,200}`. `assist` and `reindex` carry
   no data at all — their argument must be the literal `start` / `now`, so no
   webpage can feed them anything.
3. **The argument is a lookup key, never a value.** It selects a row in
   `data.js`. The working directory and the command line are built
   exclusively from index contents and hardcoded strings. Nothing from the
   URL is ever interpolated into a command, passed to a shell, or used as a
   filesystem path.
4. **Existence check.** The resolved directory must exist before launch.

## The failure that must never ship

A handler that accepts a *path* or *command text* from the URL is a
**remote-code-execution vulnerability**: any webpage could then start a
terminal in an attacker-chosen directory or run attacker-chosen text. The
distance between "convenient customization" and that hole is one careless
parameter. Examples of changes that cross the line:

- `claudesessions://new/C:\some\path` — path from URL
- `claudesessions://run/<anything>` — command text from URL
- `claudesessions://search/<query>` or any verb that turns URL text into a
  Claude **prompt** — that is attacker-chosen instructions auto-fed to an
  agent holding this folder's pre-approved permissions. The shipped `assist`
  verb is safe because its kickoff prompt is a hardcoded constant and its
  argument must be the literal `start`; the user types their query to Claude
  in the terminal, never through the URL.
- Passing the raw URL into `Start-Process`, `Invoke-Expression`, `cmd /c`,
  or a `-Command` string
- "Just trust it, only my page generates these links" — false; every page
  in the browser can generate them

## Rules for changes

1. New behavior = new **verb**, validated by its own strict pattern, resolving
   everything real through the index. Never widen an existing pattern.
2. URL content never reaches a command line, a shell, `Invoke-Expression`,
   or a filesystem API as a path. Lookup key only.
3. Keep the existence check on resolved directories.
4. If the folder moves, registration points at a stale path — re-run
   `Register-Protocol.ps1`. If the tool is removed, run it with `-Unregister`;
   don't leave dead handlers registered.
5. Transcripts under `~/.claude/projects` contain file contents and command
   output from every project — potentially secrets. The viewer index stores
   only metadata and truncated first prompts. Don't extend the index to embed
   transcript bodies, and don't have the resident Claude session raw-read
   transcript files (see CLAUDE.md).

## Reporting

This is a community tool. If you find a way to break the ceiling, open a
GitHub issue marked SECURITY, or a private report if the repo has security
advisories enabled.
