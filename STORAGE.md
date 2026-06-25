# How it works — storage & indexing

ClaudeSessions never stores a database of its own. It reads what Claude Code
already writes to disk and distills it into a single generated file, `data.js`,
that the viewer (`sessions.html`) renders. This doc explains where the source
data lives and the head/tail trick that keeps indexing fast no matter how large
your transcripts grow.

## Where Claude Code stores sessions

Claude Code keeps one **append-only file per conversation**, grouped into one
folder per working directory, all under `~/.claude/projects`:

```
C:\Users\<you>\.claude\
└── projects\                              ← one folder per cwd you've used Claude in
    ├── c--Projects-penncustprod\          ← folder name = cwd with \ and : flattened to -
    │   ├── 15abf79f-…-6f0da6d300.jsonl       2 KB   ← one file per session,
    │   ├── 29f54dd0-…-aa2b836b32f.jsonl     123 KB     named by its sessionId (UUID)
    │   ├── 358b101c-…-3c662a098bca.jsonl    962 KB
    │   └── … more sessions
    ├── c--Projects-penncustquote\
    │   ├── agent-7c2a…-….jsonl                       ← sub-agent transcript → EXCLUDED
    │   └── … more sessions
    └── … one folder per project
```

- **Folder name** is the working directory with separators flattened to `-`
  (`C:\Projects\penncustprod` → `c--Projects-penncustprod`). That encoding is
  lossy — a `-` in a real folder name is indistinguishable from a path
  separator — so the indexer prefers the real `cwd` recorded *inside* the file
  and only decodes the folder name as a fallback (`Get-ProjectLabel`).
- **File name** is the session's UUID (`<sessionId>.jsonl`).
- **`agent-*.jsonl`** are sub-agent side-conversations. They share the project
  folder with their parent session but are skipped — only top-level sessions
  are indexed.

## The file format: JSON Lines, append-only, time-ordered

Each `*.jsonl` is **JSON Lines**: one JSON object per line, one line per event,
**appended** as the conversation happens and never rewritten. Because it is
append-only, the file is strictly time-ordered top→bottom — the oldest event is
the first line, the newest event is the last line.

That single property is what the whole indexing strategy rests on: the
information the dashboard needs lives at the two *ends* of the file. The start
of the session (branch, version, first prompt, start time) is in the first few
lines; the most recent activity is in the last few. The enormous middle — the
actual back-and-forth of the conversation — is never indexed.

## The head/tail technique

Instead of reading whole files, the indexer reads two small, bounded windows
per session and ignores everything between them:

```
358b101c-…-3c662a098bca.jsonl              (962 KB — thousands of lines)
┌──────────────────────────────────────────────────────────── byte 0
│  HEAD   read first ≤120 lines OR ≤256 KB, whichever comes first
│  ┌─────────────────────────────────────────────────────────
│  │ {"type":"file-history-snapshot", …}        ← leads file; no timestamp/branch
│  │ {"type":"summary", …}                       ← if present ⇒ resumed / fork
│  │ {"type":"user","sessionId":"358b…",          ← first line WITH git context:
│  │    "timestamp":"2026-…","gitBranch":"master",   startTime, cwd, version
│  │    "cwd":"C:\\Projects\\penncustprod","version":"1.2.47",  (branch ← tail)
│  │    "message":{"content":"Using the database LLXCustCatlg…"}}  ← firstPrompt
│  │ {"type":"assistant", …}
│  └─────────────────────────────────────────────────────────
├──────────────────────────────────────────────────────────── 
│  MIDDLE   ✗ NEVER READ
│           thousands of user / assistant / tool-result lines
│           (this is where the 962 KB — or a 15 MB file — actually lives)
├──────────────────────────────────────────────────────────── (EOF − 64 KB)
│  TAIL   seek here, read last ≤64 KB, discard the 1 partial first line
│  ┌─────────────────────────────────────────────────────────
│  │ …                                           (split on newlines)
│  │ {"type":"assistant","timestamp":"2026-…",    ← last timestamp ⇒ lastActivity
│  │    "gitBranch":"main"}                          last gitBranch ⇒ branch (end)
│  └─────────────────────────────────────────────────────────
└──────────────────────────────────────────────────────────── EOF
```

What each window produces (see `Update-SessionIndex.ps1`):

| Source | Fields |
|---|---|
| **Head** (`Read-HeadLines`, ≤120 lines / 256 KB) | `startTime`, `cwd`, `version`, `firstPrompt`, `title`, `isFork`, `sessionId` |
| **Tail** (`Read-TailLines`, last 64 KB) | `lastActivity` (last timestamp; falls back to file mtime), `gitBranch` (last value — the branch the session **ended** on; falls back to the head value) |
| **Filesystem** (no content read) | `sizeBytes` (file length), `filePath`, `projectDir` (folder name) |
| **Derived** | `durationMin = lastActivity − startTime` |

Two mechanics worth knowing:

- **First non-null wins.** Within the head, each field is taken from the first
  line that actually carries it — *not* from one designated line. The first line
  that has a `sessionId` (the "meta" line) frequently lacks `timestamp`,
  `gitBranch`, `cwd`, and `version`, because `summary`, `file-history-snapshot`,
  and `queue-operation` lines lead the file. Binding those fields to the meta
  line left `started` and `version` blank for most sessions; scanning the head
  for the first real value fixes that. (`branch` is read from the tail instead,
  so it shows where the session ended — see the tradeoff below.)
- **Tail seek lands mid-line.** Jumping to `EOF − 64 KB` almost always lands in
  the middle of a line, so the first fragment read is garbage — the reader drops
  it and parses only the complete lines after it.

## Why bother

Take a 15 MB transcript. Head (256 KB) + tail (64 KB) ≈ 320 KB read — about
**2%** of the file. Reading every file in full, on every reindex, is what makes
a naive scanner crawl as your history grows. Head/tail makes a full rebuild
near-instant and, crucially, makes cost **independent of transcript size**: a
50 MB session indexes as fast as a 50 KB one.

## The tradeoff

`branch` is read from the tail, so it reflects where the session **ended** — a
session that began on a feature branch and merged to `main` shows `main`.
`started` and `version`, read from the head, reflect the **start** of the
session, so a Claude Code upgrade partway through won't show. A branch switch
that happened *and reverted* entirely within the unread middle is invisible
either way. The dashboard only ever reads the two ends, never the middle —
which is exactly what keeps a giant session as cheap to index as a tiny one.

A blank `branch` (`—`) means the folder simply wasn't a git repository during
the session (or `git` wasn't on PATH) — not that indexing failed.

## Related

- `CLAUDE.md` — index schema (the per-session fields and top-level keys).
- `GOTCHAS.md` — JSONL schema drift, the `file://` constraint, and other edges.
- `SECURITY.md` — why transcript bodies are never embedded in the index.
