<#
.SYNOPSIS
    Scans ~/.claude/projects, extracts per-session metadata, writes data.js,
    and opens sessions.html in the user's default browser, forcing a fresh
    window (app window on Chromium) so it lands on the current virtual desktop.
    Launch style is read from config.json "viewerLaunch" (app|window|default).

.DESCRIPTION
    Head/tail-only reads: never parses full transcripts, so cost is
    independent of transcript size. Tolerant parser: unknown line types and
    malformed lines are skipped, missing fields become null.

    Incremental: rows are reused from the previous data.js for every transcript
    whose size and mtime say it has not changed since that index was generated,
    so a run costs time proportional to what CHANGED, not to how many sessions
    exist. This matters because the script runs on every launch (Start Menu
    shortcut, and again from the SessionStart hook), and transcripts accumulate
    forever when cleanupPeriodDays is raised.

.PARAMETER ClaudeDir
    Root of the Claude Code data directory. Default: $env:USERPROFILE\.claude

.PARAMETER OutputDir
    Where data.js / sessions.html live. Default: the project root (parent of this script).

.PARAMETER NoLaunch
    Skip opening the browser (used when Claude refreshes the index mid-session).

.PARAMETER Force
    Ignore the previous data.js and re-parse every transcript. Use after editing
    the extraction logic, or to rebuild an index you suspect is wrong.
#>
[CmdletBinding()]
param(
    [string]$ClaudeDir = (Join-Path $env:USERPROFILE '.claude'),
    [string]$OutputDir,
    [switch]$NoLaunch,
    [switch]$Force
)

$ErrorActionPreference = 'Stop'

# Bump whenever the per-session extraction below changes shape or meaning, so
# rows cached by an older build are discarded instead of silently surviving a
# script upgrade with missing or stale fields.
$IndexerVersion = 2

# Resolve our own location defensively: $PSScriptRoot can come up empty under
# some hook/host invocation paths, and Split-Path '' throws.
$scriptDir = $PSScriptRoot
if (-not $scriptDir) { $scriptDir = Split-Path -Parent $MyInvocation.MyCommand.Definition }
if (-not $scriptDir) { $scriptDir = (Get-Location).Path }
if (-not $OutputDir) { $OutputDir = Split-Path (Split-Path $scriptDir -Parent) -Parent }
if ($env:CLAUDESESSIONS_NOLAUNCH) { $NoLaunch = $true }
$projectsDir = Join-Path $ClaudeDir 'projects'
if (-not (Test-Path $projectsDir)) {
    Write-Error "Projects directory not found: $projectsDir"
    exit 1
}

# --- helpers -----------------------------------------------------------------

function Read-HeadLines {
    # Stream up to $MaxLines lines or $MaxBytes from the top of a file.
    param([string]$Path, [int]$MaxLines = 120, [int]$MaxBytes = 262144)
    $lines = [System.Collections.Generic.List[string]]::new()
    $reader = [System.IO.StreamReader]::new($Path)
    try {
        while (-not $reader.EndOfStream -and
               $lines.Count -lt $MaxLines -and
               $reader.BaseStream.Position -lt $MaxBytes) {
            $lines.Add($reader.ReadLine())
        }
    } finally { $reader.Dispose() }
    return $lines
}

function Read-TailLines {
    # Read the last ~$TailBytes of a file and return its complete lines.
    param([string]$Path, [int]$TailBytes = 65536)
    $fs = [System.IO.File]::Open($Path, 'Open', 'Read', 'ReadWrite')
    try {
        $len = $fs.Length
        $start = [Math]::Max(0, $len - $TailBytes)
        $fs.Seek($start, 'Begin') | Out-Null
        $buf = New-Object byte[] ($len - $start)
        $read = $fs.Read($buf, 0, $buf.Length)
        $text = [System.Text.Encoding]::UTF8.GetString($buf, 0, $read)
        $all = $text -split "`n"
        # First element may be a partial line when we seeked mid-line; drop it.
        if ($start -gt 0 -and $all.Count -gt 1) { $all = $all[1..($all.Count - 1)] }
        return $all | Where-Object { $_.Trim() }
    } finally { $fs.Dispose() }
}

function ConvertFrom-JsonSafe {
    param([string]$Line)
    try { return $Line | ConvertFrom-Json -ErrorAction Stop } catch { return $null }
}

function Test-RealUserPrompt {
    # A human-typed prompt: type user, string content, not meta,
    # not a local-command echo (<command-name>, <local-command-stdout>, ...).
    param($Obj)
    if ($null -eq $Obj -or $Obj.type -ne 'user') { return $false }
    if ($Obj.isMeta -eq $true) { return $false }
    $c = $Obj.message.content
    if ($c -isnot [string]) { return $false }
    if ($c.TrimStart().StartsWith('<')) { return $false }
    return $true
}

function Get-ProjectLabel {
    # Decode 'C--Projects-myapp' -> 'C:\Projects\myapp' (best effort).
    # The encoding is lossy (dashes in real names are ambiguous), so prefer the
    # cwd recorded inside the transcript when available; this is the fallback.
    param([string]$DirName)
    if ($DirName -match '^([A-Za-z])--(.*)$') {
        return ('{0}:\{1}' -f $Matches[1], ($Matches[2] -replace '-', '\'))
    }
    return ($DirName -replace '^-', '/' -replace '-', '/')
}

# Leading sentence of the fixed kickoff prompt that Launch-Handler.ps1 injects
# for the "search with claude" (assist) verb. That prompt lands as the session's
# FIRST user message, so without special-casing it every assist session shows
# the same boilerplate in the list. When we see it we skip it, take the next
# real user prompt as the query, and synthesize a friendly named-session title
# from it (see the emit below). Match a stable prefix, not the whole string, so
# wording tweaks to the tail of the prompt don't break detection. Keep this in
# sync with the prompt in Launch-Handler.ps1 (the 'assist' switch arm).
$AssistKickoffPrefix = 'The user clicked Search with Claude on the sessions page'

# --- previous index (row cache) ----------------------------------------------

# data.js is its own cache: every row already carries filePath and sizeBytes,
# so a prior run tells us what each transcript looked like when it was parsed.
# A row is reusable when the file is byte-identical to what produced it, which
# for append-only JSONL means: same length, and untouched since that index was
# generated. Anything else -- new file, appended file, corrupt or absent cache,
# a different ClaudeDir, an extraction change ($IndexerVersion) -- re-parses.
$dataPath = Join-Path $OutputDir 'data.js'
$cache = @{}
$cacheGenerated = $null
if (-not $Force -and (Test-Path $dataPath)) {
    try {
        $prevRaw = Get-Content -Path $dataPath -Raw
        if ($prevRaw -match '(?s)^\s*window\.SESSION_DATA\s*=\s*(.*);\s*$') {
            $prev = $Matches[1] | ConvertFrom-Json
            if ($prev.indexerVersion -eq $IndexerVersion -and
                $prev.claudeDir -eq $ClaudeDir -and
                $prev.generated) {
                $cacheGenerated = ([datetime]$prev.generated).ToUniversalTime()
                foreach ($s in $prev.sessions) {
                    if ($s.filePath) { $cache[$s.filePath] = $s }
                }
            }
        }
    } catch {
        # Unreadable or malformed index: fall through to a full rebuild.
        $cache = @{}
        $cacheGenerated = $null
    }
}

# --- scan --------------------------------------------------------------------

# Stamped as "generated" below. Taken BEFORE the scan, not after: a transcript
# appended to while the scan is running must look newer than the index it lands
# in, or the next run would reuse a row built from a partial read.
$scanStarted = (Get-Date).ToUniversalTime().ToString('o')

$reused = 0
$sessions = [System.Collections.Generic.List[object]]::new()
$files = Get-ChildItem -Path $projectsDir -Directory | ForEach-Object {
    $projDir = $_
    Get-ChildItem -Path $projDir.FullName -Filter '*.jsonl' -File |
        Where-Object { $_.Name -notlike 'agent-*' } |       # exclude sub-agent transcripts
        ForEach-Object { [pscustomobject]@{ File = $_; ProjDirName = $projDir.Name } }
}

foreach ($entry in $files) {
    $f = $entry.File

    # Unchanged since the cached index was built? Reuse the row and skip the
    # head/tail parse entirely -- this is the whole point of the optimization.
    if ($cacheGenerated -and $cache.ContainsKey($f.FullName)) {
        $hit = $cache[$f.FullName]
        if ($hit.sizeBytes -eq $f.Length -and $f.LastWriteTimeUtc -le $cacheGenerated) {
            $sessions.Add($hit)
            $reused++
            continue
        }
    }

    try {
        $head = Read-HeadLines -Path $f.FullName
        if ($head.Count -eq 0) { continue }

        $meta        = $null   # first line carrying sessionId
        $firstPrompt = $null
        $firstTs     = $null
        $gitBranch   = $null
        $version     = $null
        $cwd         = $null
        $customTitle = $null
        $aiTitle     = $null
        $assistKickoff = $false   # first real prompt was the injected "search with claude" kickoff
        $isFork      = $false

        # Take the first non-null value of each field across the (bounded) head.
        # The sessionId-bearing "meta" line frequently lacks timestamp / gitBranch
        # / cwd / version, because summary, file-history-snapshot, and queue lines
        # lead the file in current Claude Code transcripts. Reading those off the
        # meta line alone left 'started', 'branch', and 'version' blank for most
        # sessions, so each is captured independently of meta detection.
        foreach ($raw in $head) {
            $o = ConvertFrom-JsonSafe $raw
            if ($null -eq $o) { continue }
            if ($null -eq $meta      -and $o.sessionId) { $meta = $o }
            if ($null -eq $firstTs   -and $o.timestamp) { $firstTs = $o.timestamp }
            if ($null -eq $gitBranch -and $o.gitBranch) { $gitBranch = $o.gitBranch }
            if ($null -eq $version   -and $o.version)   { $version = $o.version }
            if ($null -eq $cwd       -and $o.cwd)       { $cwd = $o.cwd }
            # Titles: keep the LAST of each type seen (renames stack; the newest
            # wins). The tail pass below overrides these — see the note there.
            if ($o.type -eq 'custom-title' -and $o.customTitle) { $customTitle = $o.customTitle }
            if ($o.type -eq 'ai-title'     -and $o.aiTitle)     { $aiTitle     = $o.aiTitle }
            if ($o.forkedFrom) { $isFork = $true }           # branched from another transcript
            if ($null -eq $firstPrompt -and (Test-RealUserPrompt $o)) {
                $content = $o.message.content
                if (-not $assistKickoff -and $content -like "$AssistKickoffPrefix*") {
                    # Injected "search with claude" kickoff: skip it so firstPrompt
                    # (and the synthesized title) reflect the user's real query,
                    # captured from the next real prompt on a later pass of this loop.
                    $assistKickoff = $true
                } else {
                    $firstPrompt = $content
                }
            }
        }

        # Last activity: prefer last parseable timestamp in the tail; fall back to mtime.
        # Branch: take the LAST gitBranch in the tail so the column shows where the
        # session ended (e.g. work that began on a feature branch and landed on
        # main), not where it started. gitBranch rides on every event line, so the
        # tail carries it; fall back to the head value if the tail somehow lacks it.
        #
        # Titles are re-stamped once per prompt for the life of a session, so the
        # current value of each always sits within a prompt or two of EOF -- the
        # tail is the only place that reliably has it. A rename lands wherever it
        # happened (line 476 of 484 in one measured transcript), far past the head
        # window. Measured worst case across this machine: custom-title 27 KB from
        # EOF, ai-title 33 KB, against the 64 KB tail. Head values (above) act as a
        # fallback for the rare file whose titles all predate the tail window.
        # lastPrompt rides along on this same pass: the last real user prompt in
        # the tail is where the session left off, which is what you want when
        # deciding whether to resume it. Keep overwriting -- the final match wins.
        # The assist kickoff is skipped for the same reason the head pass skips
        # it: it is injected boilerplate, not something the user typed.
        $lastTs = $null
        $lastBranch = $null
        $lastPrompt = $null
        foreach ($raw in (Read-TailLines -Path $f.FullName)) {
            $o = ConvertFrom-JsonSafe $raw
            if ($o -and $o.timestamp) { $lastTs = $o.timestamp }
            if ($o -and $o.gitBranch) { $lastBranch = $o.gitBranch }
            if ($o -and $o.type -eq 'custom-title' -and $o.customTitle) { $customTitle = $o.customTitle }
            if ($o -and $o.type -eq 'ai-title'     -and $o.aiTitle)     { $aiTitle     = $o.aiTitle }
            if ($o -and $o.forkedFrom) { $isFork = $true }
            if (Test-RealUserPrompt $o) {
                $lc = $o.message.content
                if ($lc -notlike "$AssistKickoffPrefix*") { $lastPrompt = $lc }
            }
        }
        # A long agentic session can end in far more than 64 KB of assistant and
        # tool-result traffic, so the standard tail finds no prompt at all --
        # measured here, that was 120 of 286 sessions, every one of them over
        # 64 KB, median 1.3 MB. Those are exactly the sessions where "where did I
        # leave off?" is worth answering, so widen the window once when the first
        # pass comes up empty. Scanned backwards with a break: it stops at the
        # first prompt found, so the extra parsing is bounded by how far the
        # trailing tool output actually runs, not by the window size.
        if (-not $lastPrompt -and $f.Length -gt 65536) {
            $wide = @(Read-TailLines -Path $f.FullName -TailBytes 524288)
            for ($i = $wide.Count - 1; $i -ge 0; $i--) {
                $o = ConvertFrom-JsonSafe $wide[$i]
                if (Test-RealUserPrompt $o) {
                    $lc = $o.message.content
                    if ($lc -notlike "$AssistKickoffPrefix*") { $lastPrompt = $lc; break }
                }
            }
        }

        if (-not $lastTs) { $lastTs = $f.LastWriteTimeUtc.ToString('o') }
        if ($lastBranch) { $gitBranch = $lastBranch }   # end-of-session branch wins

        $durationMin = $null
        if ($firstTs -and $lastTs) {
            try {
                $durationMin = [Math]::Round(([datetime]$lastTs - [datetime]$firstTs).TotalMinutes, 1)
                if ($durationMin -lt 0) { $durationMin = $null }
            } catch { }
        }

        # Name a row the way Claude Code names the session: the user's rename if
        # there is one, else Claude's own auto title. Ordering is by SOURCE, never
        # by file position -- both types keep re-stamping, so the last title line
        # in a renamed transcript is often the stale ai-title (6 of 17 measured).
        #
        #   custom-title  ->  synthesized assist label  ->  ai-title  ->  firstPrompt
        #
        # The synthesized label outranks ai-title because a "search with claude"
        # session's auto title is generated from the injected kickoff boilerplate,
        # so it describes this app rather than what the user asked. That label is
        # index-only: it lives in data.js, not in the transcript, so it shows here
        # and not in Claude's /resume list. firstPrompt is the viewer's fallback.
        $displayTitle = $customTitle
        if (-not $displayTitle -and $assistKickoff) {
            if ($firstPrompt) {
                $q = $firstPrompt.Trim() -replace '\s+', ' '
                if ($q.Length -gt 80) { $q = $q.Substring(0, 80).TrimEnd() + '...' }
                $displayTitle = "Searching Claude sessions - $q"
            } else {
                # Assist session opened but no query typed yet.
                $displayTitle = 'Searching Claude sessions'
            }
        }
        if (-not $displayTitle -and $aiTitle) { $displayTitle = $aiTitle }

        $sessions.Add([pscustomobject]@{
            sessionId    = if ($meta) { $meta.sessionId } else { [System.IO.Path]::GetFileNameWithoutExtension($f.Name) }
            title        = $displayTitle
            firstPrompt  = if ($firstPrompt) { $firstPrompt.Substring(0, [Math]::Min(300, $firstPrompt.Length)) } else { $null }
            lastPrompt   = if ($lastPrompt)  { $lastPrompt.Substring(0, [Math]::Min(300, $lastPrompt.Length)) }   else { $null }
            cwd          = if ($cwd) { $cwd } else { Get-ProjectLabel $entry.ProjDirName }
            projectDir   = $entry.ProjDirName
            gitBranch    = $gitBranch
            version      = $version
            startTime    = $firstTs
            lastActivity = $lastTs
            durationMin  = $durationMin
            sizeBytes    = $f.Length
            isFork       = $isFork
            filePath     = $f.FullName
        })
    } catch {
        Write-Warning "Skipped $($f.FullName): $_"
    }
}

# --- emit --------------------------------------------------------------------

# Capabilities come from config.json (written by Setup.ps1); absent => browse-only.
$launchEnabled = $false
$configPath = Join-Path $OutputDir 'config.json'
if (Test-Path $configPath) {
    try {
        $cfg = Get-Content -Path $configPath -Raw | ConvertFrom-Json
        $launchEnabled = [bool]$cfg.protocolRegistered
    } catch { Write-Warning "config.json unreadable; launch buttons disabled." }
}

# Retention window: Claude Code deletes transcripts older than cleanupPeriodDays
# (measured by last activity). Default is 30 when the key is absent. Read from
# the user's settings.json so the viewer can show per-session expiry.
$cleanupPeriodDays = 30
$settingsPath = Join-Path $ClaudeDir 'settings.json'
if (Test-Path $settingsPath) {
    try {
        $settings = Get-Content -Path $settingsPath -Raw | ConvertFrom-Json
        if ($null -ne $settings.cleanupPeriodDays) {
            $cleanupPeriodDays = [int]$settings.cleanupPeriodDays
        }
    } catch { Write-Warning "settings.json unreadable; assuming cleanupPeriodDays=30." }
}

$payload = [pscustomobject]@{
    generated         = $scanStarted
    indexerVersion    = $IndexerVersion
    machine           = $env:COMPUTERNAME
    claudeDir         = $ClaudeDir
    launchEnabled     = $launchEnabled
    cleanupPeriodDays = $cleanupPeriodDays
    sessions          = $sessions
}

$json = $payload | ConvertTo-Json -Depth 6 -Compress
# data.js, not data.json: <script src> sidesteps the file:// fetch restriction.
Set-Content -Path $dataPath -Value "window.SESSION_DATA = $json;" -Encoding UTF8

$parsed = $sessions.Count - $reused
Write-Host ("Indexed {0} sessions across {1} projects ({2} parsed, {3} reused) -> {4}" -f `
    $sessions.Count, ($sessions.projectDir | Select-Object -Unique).Count, `
    $parsed, $reused, $dataPath)

function Resolve-DefaultBrowser {
    # Full path to the user's default browser exe, or $null. Reads the https (then
    # http) UserChoice ProgId and follows it to its shell\open\command, then peels
    # the exe out of the command string.
    $progId = $null
    foreach ($scheme in 'https', 'http') {
        try {
            $progId = (Get-ItemProperty "HKCU:\Software\Microsoft\Windows\Shell\Associations\UrlAssociations\$scheme\UserChoice" -ErrorAction Stop).ProgId
            if ($progId) { break }
        } catch { }
    }
    if (-not $progId) { return $null }
    $cmd = $null
    foreach ($hive in 'Registry::HKEY_CLASSES_ROOT', 'HKCU:\Software\Classes', 'HKLM:\SOFTWARE\Classes') {
        try {
            $cmd = (Get-ItemProperty -LiteralPath "$hive\$progId\shell\open\command" -ErrorAction Stop).'(default)'
            if ($cmd) { break }
        } catch { }
    }
    if (-not $cmd) { return $null }
    if ($cmd -match '^\s*"([^"]+)"') { return $Matches[1] }   # quoted path
    if ($cmd -match '^\s*(\S+)')     { return $Matches[1] }   # bare token
    return $null
}

function Get-BrowserKind {
    # Classify a browser exe so we know which new-window flag it understands.
    param([string]$Exe)
    if (-not $Exe) { return 'other' }
    switch -Regex ([System.IO.Path]::GetFileName($Exe).ToLowerInvariant()) {
        '^(msedge|chrome|brave|vivaldi|opera)' { 'chromium'; break }   # all Chromium: --app / --new-window
        'firefox'                              { 'firefox';  break }   # new-window only, no app mode
        default                                { 'other' }
    }
}

function Open-Viewer {
    # Open the viewer in the user's DEFAULT browser, forcing a fresh window so it
    # lands on the *current* virtual desktop instead of being folded into an
    # existing window stranded on another desktop. Mode (from config.json):
    #   app     -> Chromium app window (--app); Firefox degrades to a new window
    #   window  -> normal new window  (--new-window / -new-window)
    #   default -> hand off to the OS (Start-Process); no forced window
    # Any unknown browser or failure falls back to Start-Process (today's behavior).
    param(
        [Parameter(Mandatory)][string]$Page,
        [ValidateSet('app', 'window', 'default')][string]$Mode = 'app'
    )
    if ($Mode -eq 'default') { Start-Process $Page; return }

    $url  = ([Uri]((Resolve-Path -LiteralPath $Page).Path)).AbsoluteUri   # file:///C:/.../sessions.html
    $exe  = Resolve-DefaultBrowser
    $kind = Get-BrowserKind $exe

    $launchArgs = $null
    if ($exe -and (Test-Path -LiteralPath $exe)) {
        if ($kind -eq 'chromium') {
            $launchArgs = if ($Mode -eq 'app') { @("--app=$url") } else { @('--new-window', $url) }
        } elseif ($kind -eq 'firefox') {
            $launchArgs = @('-new-window', $url)
        }
    }

    if ($launchArgs) {
        try { Start-Process -FilePath $exe -ArgumentList $launchArgs; return }
        catch { Write-Warning "Could not launch $exe ($($_.Exception.Message)); using the default browser." }
    }
    Start-Process $Page   # unknown browser / detection failed / launch failed
}

if (-not $NoLaunch) {
    $page = Join-Path $OutputDir 'sessions.html'
    if (Test-Path $page) {
        $mode = 'app'
        $cfgPath = Join-Path $OutputDir 'config.json'
        if (Test-Path $cfgPath) {
            try {
                $vl = (Get-Content -Path $cfgPath -Raw | ConvertFrom-Json).viewerLaunch
                if ($vl -in @('app', 'window', 'default')) { $mode = $vl }
            } catch { }
        }
        Open-Viewer -Page $page -Mode $mode
    } else { Write-Warning "Viewer not found: $page" }
}
