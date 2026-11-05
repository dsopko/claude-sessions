<#
.SYNOPSIS
    Full-text search across all session transcripts. Returns compact JSON
    grouped by session: which sessions mention the pattern, how often, short
    context snippets, and (when the index knows the session) its title, last
    activity, directory and resume command. For Claude to consume; keeps
    token cost low.

.DESCRIPTION
    Engine: uses ripgrep (rg) when it is on PATH -- one streamed invocation
    over the whole store -- and falls back to Select-String otherwise. Both
    engines match case-insensitively and produce the same result shape.
    Note rg uses Rust regex syntax, Select-String .NET; the common core
    (literals, classes, alternation, anchors) behaves identically, and
    -SimpleMatch sidesteps the difference entirely.

    Hit counts skip request-replay lines (api-request-blob / api-request-shape),
    which re-carry message content and would otherwise count every real
    mention twice or more.

    Snippets are taken from the message text (user prompts, assistant replies)
    around the match whenever the matched line is a message; only matches in
    structural/metadata lines fall back to a raw-line window. This keeps the
    output readable and avoids dragging adjacent transcript internals
    (tool output, env dumps) into the calling session.

.PARAMETER Pattern
    Regex (case-insensitive). Use -SimpleMatch for literal text.

.PARAMETER MaxSnippets
    Max snippets returned per session. Default 3.

.PARAMETER ProjectDir
    Restrict the search to one project folder name under ~/.claude/projects
    (e.g. 'C--Projects-myapp').

.PARAMETER After
    Only search transcripts last modified at or after this time.

.PARAMETER Before
    Only search transcripts last modified at or before this time.

.PARAMETER ExcludeSessionId
    Session UUID to skip. The search assistant should pass its own session id
    here, because the current conversation always matches the query the user
    just typed into it.
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory)] [string]$Pattern,
    [switch]$SimpleMatch,
    [int]$MaxSnippets = 3,
    [int]$SnippetWidth = 160,
    [string]$ProjectDir,
    [datetime]$After,
    [datetime]$Before,
    [string]$ExcludeSessionId,
    [string]$ClaudeDir = (Join-Path $env:USERPROFILE '.claude')
)

$ErrorActionPreference = 'Stop'
$projectsDir = Join-Path $ClaudeDir 'projects'

# --- index (data.js) for decorating results -----------------------------------
# Best effort: results still come back bare when the index is missing, stale,
# or malformed -- the search itself never depends on it.
$scriptDir = $PSScriptRoot
if (-not $scriptDir) { $scriptDir = Split-Path -Parent $MyInvocation.MyCommand.Definition }
$root = Split-Path (Split-Path $scriptDir -Parent) -Parent
$index = @{}
$dataPath = Join-Path $root 'data.js'
if (Test-Path $dataPath) {
    try {
        $rawIdx = Get-Content -Path $dataPath -Raw
        if ($rawIdx -match '(?s)^\s*window\.SESSION_DATA\s*=\s*(.*);\s*$') {
            foreach ($s in (($Matches[1] | ConvertFrom-Json).sessions)) {
                if ($s.sessionId -and -not $index.ContainsKey($s.sessionId)) {
                    $index[$s.sessionId] = $s
                }
            }
        }
    } catch { }
}

# --- helpers -------------------------------------------------------------------

# Request-replay lines re-carry message content, so counting them reports every
# real mention twice or more. Cheap substring check; the marker appearing inside
# genuine message text is possible but rare, and only costs one hit.
$ReplayMarks = @('"type":"api-request-blob"', '"type":"api-request-shape"', '"type":"last-prompt"')
function Test-ReplayLine {
    param([string]$Line)
    foreach ($m in $ReplayMarks) { if ($Line.Contains($m)) { return $true } }
    return $false
}

function Get-ContentText {
    # The human-readable text of a transcript message: string content as-is,
    # array content (assistant messages) joined from its text blocks.
    param($Obj)
    $c = $Obj.message.content
    if ($c -is [string]) { return $c }
    if ($c -is [System.Array]) {
        $parts = foreach ($b in $c) { if ($b.type -eq 'text' -and $b.text) { $b.text } }
        if ($parts) { return (@($parts) -join ' ') }
    }
    return $null
}

function Get-Window {
    param([string]$Text, [int]$Index)
    $start = [Math]::Max(0, $Index - [int]($SnippetWidth / 2))
    $len = [Math]::Min($SnippetWidth, $Text.Length - $start)
    if ($len -le 0) { return $Text }
    return $Text.Substring($start, $len)
}

function Find-PatternIndex {
    # Where the pattern matches inside extracted message text. Case-insensitive
    # to mirror both engines' matching.
    param([string]$Text)
    if ($SimpleMatch) {
        return $Text.IndexOf($Pattern, [System.StringComparison]::OrdinalIgnoreCase)
    }
    try {
        $m = [regex]::Match($Text, $Pattern, [System.Text.RegularExpressions.RegexOptions]::IgnoreCase)
        if ($m.Success) { return $m.Index }
    } catch { }
    return -1
}

function Get-Snippet {
    # Prefer a window over the message text; fall back to the raw line only
    # when the match is not inside readable content.
    param([string]$Line, [int]$RawIndex)
    $o = $null
    try { $o = $Line | ConvertFrom-Json -ErrorAction Stop } catch { }
    if ($o -and ($o.type -eq 'user' -or $o.type -eq 'assistant')) {
        $text = Get-ContentText $o
        if ($text) {
            $idx = Find-PatternIndex $text
            if ($idx -ge 0) { return (Get-Window $text $idx) }
        }
    }
    return (Get-Window $Line ([Math]::Max(0, $RawIndex)))
}

function New-ResultRow {
    param([string]$SessionId, [string]$ProjDirName, [int]$HitCount, $Snippets)
    $row = [ordered]@{
        sessionId     = $SessionId
        projectDir    = $ProjDirName
        hitCount      = $HitCount
        snippets      = @($Snippets)
        resumeCommand = "claude --resume $SessionId"
    }
    $ix = $index[$SessionId]
    if ($ix) {
        $row.title        = $ix.title
        $row.lastActivity = $ix.lastActivity
        $row.cwd          = $ix.cwd
        $row.firstPrompt  = $ix.firstPrompt
    }
    return [pscustomobject]$row
}

# --- select transcripts ----------------------------------------------------------

$files = Get-ChildItem -Path $projectsDir -Recurse -Filter '*.jsonl' -File |
    Where-Object { $_.Name -notlike 'agent-*' }
if ($ProjectDir) { $files = $files | Where-Object { $_.Directory.Name -eq $ProjectDir } }
if ($PSBoundParameters.ContainsKey('After'))  { $files = $files | Where-Object { $_.LastWriteTime -ge $After } }
if ($PSBoundParameters.ContainsKey('Before')) { $files = $files | Where-Object { $_.LastWriteTime -le $Before } }
if ($ExcludeSessionId) { $files = $files | Where-Object { $_.BaseName -ne $ExcludeSessionId } }
$files = @($files)

# path -> file entry, for attributing rg hits and validating them against the
# selection above (rg scans the directory; the mtime/exclusion filters are ours).
$fileByPath = @{}
foreach ($f in $files) { $fileByPath[$f.FullName] = $f }

$results = [System.Collections.Generic.List[object]]::new()

# --- engine: ripgrep when available ----------------------------------------------

$rg = Get-Command rg -ErrorAction SilentlyContinue

if ($rg -and $files.Count -gt 0) {
    $searchRoot = if ($ProjectDir) { Join-Path $projectsDir $ProjectDir } else { $projectsDir }
    # --no-config: never let a user rgrc change matching semantics.
    # --no-messages: suppress unreadable-file noise on stderr (a live transcript
    # can be locked mid-write); missing files simply don't match.
    $rgArgs = @('--json', '--ignore-case', '--no-config', '--no-messages',
                '--glob', '*.jsonl', '--glob', '!agent-*')
    if ($SimpleMatch) { $rgArgs += '--fixed-strings' }
    $rgArgs += @('--regexp', $Pattern, '--', $searchRoot)

    # Inside a --json match event the transcript line is a JSON string, so the
    # replay marker appears with escaped quotes.
    $escapedReplayMarks = @($ReplayMarks | ForEach-Object { $_.Replace('"', '\"') })

    $byFile = [ordered]@{}   # path -> @{ Count; Snips }
    & $rg.Source @rgArgs | ForEach-Object {
        $evt = $_
        if (-not $evt.StartsWith('{"type":"match"')) { return }
        foreach ($m in $escapedReplayMarks) { if ($evt.Contains($m)) { return } }
        $o = $null
        try { $o = $evt | ConvertFrom-Json -ErrorAction Stop } catch { return }
        $path = $o.data.path.text
        if (-not $path -or -not $fileByPath.ContainsKey($path)) { return }
        if (-not $byFile.Contains($path)) {
            $byFile[$path] = @{ Count = 0; Snips = [System.Collections.Generic.List[string]]::new() }
        }
        $slot = $byFile[$path]
        $slot.Count++
        if ($slot.Snips.Count -lt $MaxSnippets) {
            $line = [string]$o.data.lines.text
            $line = $line.TrimEnd("`r", "`n")
            # submatch offsets are bytes; close enough to a char index for
            # centering a window, and Get-Snippet re-locates inside message text.
            $idx = 0
            if ($o.data.submatches -and @($o.data.submatches).Count -gt 0) {
                $idx = [int](@($o.data.submatches)[0].start)
                if ($idx -ge $line.Length) { $idx = 0 }
            }
            $slot.Snips.Add((Get-Snippet $line $idx))
        }
    }

    foreach ($path in $byFile.Keys) {
        $f = $fileByPath[$path]
        $results.Add((New-ResultRow -SessionId $f.BaseName -ProjDirName $f.Directory.Name `
            -HitCount $byFile[$path].Count -Snippets $byFile[$path].Snips))
    }
}
elseif ($files.Count -gt 0) {

    # --- engine: Select-String fallback ------------------------------------------

    foreach ($f in $files) {
        $ssArgs = @{ Path = $f.FullName; Pattern = $Pattern }
        if ($SimpleMatch) { $ssArgs.SimpleMatch = $true }
        $hits = @(Select-String @ssArgs | Where-Object { -not (Test-ReplayLine $_.Line) })
        if ($hits.Count -eq 0) { continue }

        $snippets = foreach ($h in ($hits | Select-Object -First $MaxSnippets)) {
            # -SimpleMatch leaves MatchInfo.Matches empty; locate the hit ourselves
            # so the fallback window still centers on it.
            $idx = if ($h.Matches.Count -gt 0) { $h.Matches[0].Index }
                   else { [Math]::Max(0, (Find-PatternIndex $h.Line)) }
            Get-Snippet $h.Line $idx
        }

        $results.Add((New-ResultRow -SessionId $f.BaseName -ProjDirName $f.Directory.Name `
            -HitCount $hits.Count -Snippets $snippets))
    }
}

[pscustomobject]@{
    pattern  = $Pattern
    engine   = if ($rg) { 'ripgrep' } else { 'select-string' }
    sessions = @($results | Sort-Object hitCount -Descending)
    total    = [int](($results | Measure-Object -Property hitCount -Sum).Sum)
} | ConvertTo-Json -Depth 4
