# GOTCHAS

**fetch() of local JSON fails on file://.** Every file:// resource is an
opaque origin; sibling fetches are blocked. That's why the index is `data.js`
loaded via `<script src>`, not `data.json`.

**Scan ~/.claude from the Windows side, never through /mnt/c.** WSL2 reaches
Windows files over a 9P bridge; per-file open/stat goes from microseconds to
milliseconds. A 3ms scan becomes seconds.

**PowerShell 5.1 vs 7.** Scripts avoid PS7-only syntax (`??`, ternary).
`Set-Content -Encoding UTF8` writes a BOM on 5.1; parsers here tolerate it.

**wt.exe may not exist** even on Windows 11 (App execution aliases off, or
not installed). Setup.ps1 verifies the terminal choice; the handler falls
back to powershell if a configured wt disappears.

**Quoted arguments don't survive Start-Process -> powershell -Command.**
The command line crosses multiple parsers (Start-Process's argument join,
the argv tokenizer, Windows Terminal's own layer), and the argv tokenizer
eats your double quotes - `claude "long prompt"` arrives as `claude long
prompt ...` and claude sees a one-word prompt. The handler uses
`-EncodedCommand` (base64) so nothing is reparsed in transit. Tradeoff:
base64'd PowerShell looks like malware to some AV/EDR heuristics; if your
endpoint security flags it, this is why, and the payload is one `claude ...`
line you can decode and read.

**$PSScriptRoot can be empty** under some hook/host invocation paths, and
`Split-Path ''` throws. Scripts here resolve their location with a fallback
chain ($PSScriptRoot -> $MyInvocation -> cwd).

**Launched sessions come up in the blue conhost window even when Windows
Terminal is your default.** The protocol handler runs hidden, and processes
spawned from a hidden parent bypass the default-terminal delegation — Windows
falls back to classic conhost (blue, for powershell.exe). Fix: launch WT
explicitly by setting `"terminal": "wt"` in config.json (requires the `wt`
app execution alias to be enabled: Settings > Apps > Advanced app settings >
App execution aliases).

**Reload is not reindex.** The page is a static snapshot: it loads `data.js`
once and only displays it. A browser reload (or reopening the page) just
re-reads whatever `data.js` already holds — it never scans transcripts. Only
`Update-SessionIndex.ps1` rewrites `data.js`, via the desktop icon, the
SessionStart hook, a resident Claude, or the **↻ refresh** button. The button
fires `claudesessions://reindex/now` (a no-data verb — see SECURITY.md), which
runs the indexer in the hidden handler, then the page reloads. Because a
file:// page can't observe when that out-of-process handler finishes, the
reload is a fixed ~3s delay, not a completion signal; if a future, much larger
transcript set makes indexing exceed that, the reload shows the prior data and
a second click catches up.

**Protocol permission prompts on file:// are inconsistent.** Chrome/Edge may
or may not offer "always allow" for file-origin pages. Worst case: one extra
Enter per launch.

**Browsers append trailing slashes** to protocol URLs sometimes; the handler's
shape regex accepts exactly one optional trailing slash.

**JSONL schema is undocumented and drifts.** Line types observed in the wild:
user, assistant, system, summary, custom-title, file-history-snapshot,
queue-operation, agent-name, attachment, last-prompt, permission-mode. The
parser skips unknown types and treats missing fields as null. parentUuid
chains are known to corrupt (anthropics/claude-code#22526); nothing here
depends on chain integrity.

**First line of a session file isn't always the user prompt** — hooks,
summaries, and meta lines can precede it. The indexer scans forward to the
first real user line (string content, not isMeta, not a `<command-...>` echo).

**Sub-agent transcripts** (`agent-*.jsonl`) share project directories with
main sessions and are excluded from the index.

**Two installed copies = confusing breakage.** Zip extraction loves creating
`ClaudeSessions\ClaudeSessions`. The protocol registration, the desktop
shortcut, and the hook trust each bind to ONE absolute path - with two
copies they can disagree. Keep exactly one install folder and re-run Setup
there.

**Moving the install folder breaks protocol registration** (registry points
at an absolute path). Re-run Register-Protocol.ps1.
