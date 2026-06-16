<#
.SYNOPSIS
    Scans ~/.claude/projects, extracts per-session metadata, writes data.js,
    and opens sessions.html in the default browser.

.DESCRIPTION
    Head/tail-only reads: never parses full transcripts, so cost is
    independent of transcript size. Tolerant parser: unknown line types and
    malformed lines are skipped, missing fields become null.

.PARAMETER ClaudeDir
    Root of the Claude Code data directory. Default: $env:USERPROFILE\.claude

.PARAMETER OutputDir
    Where data.js / sessions.html live. Default: the project root (parent of this script).

.PARAMETER NoLaunch
    Skip opening the browser (used when Claude refreshes the index mid-session).
#>
[CmdletBinding()]
param(
    [string]$ClaudeDir = (Join-Path $env:USERPROFILE '.claude'),
    [string]$OutputDir,
    [switch]$NoLaunch
)

$ErrorActionPreference = 'Stop'

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

# --- scan --------------------------------------------------------------------

$sessions = [System.Collections.Generic.List[object]]::new()
$files = Get-ChildItem -Path $projectsDir -Directory | ForEach-Object {
    $projDir = $_
    Get-ChildItem -Path $projDir.FullName -Filter '*.jsonl' -File |
        Where-Object { $_.Name -notlike 'agent-*' } |       # exclude sub-agent transcripts
        ForEach-Object { [pscustomobject]@{ File = $_; ProjDirName = $projDir.Name } }
}

foreach ($entry in $files) {
    $f = $entry.File
    try {
        $head = Read-HeadLines -Path $f.FullName
        if ($head.Count -eq 0) { continue }

        $meta        = $null   # first line carrying sessionId/cwd/etc.
        $firstPrompt = $null
        $firstTs     = $null
        $customTitle = $null
        $isFork      = $false

        foreach ($raw in $head) {
            $o = ConvertFrom-JsonSafe $raw
            if ($null -eq $o) { continue }
            if ($null -eq $meta -and $o.sessionId) {
                $meta = $o
                $firstTs = $o.timestamp
            }
            if ($o.type -eq 'custom-title' -and $o.title) { $customTitle = $o.title }
            if ($o.type -eq 'summary') { $isFork = $true }   # summary pointer at head => resumed/branched lineage
            if ($null -eq $firstPrompt -and (Test-RealUserPrompt $o)) {
                $firstPrompt = $o.message.content
            }
            if ($meta -and $firstPrompt) { break }
        }

        # Last activity: prefer last parseable timestamp in the tail; fall back to mtime.
        $lastTs = $null
        foreach ($raw in (Read-TailLines -Path $f.FullName)) {
            $o = ConvertFrom-JsonSafe $raw
            if ($o -and $o.timestamp) { $lastTs = $o.timestamp }
        }
        if (-not $lastTs) { $lastTs = $f.LastWriteTimeUtc.ToString('o') }

        $durationMin = $null
        if ($firstTs -and $lastTs) {
            try {
                $durationMin = [Math]::Round(([datetime]$lastTs - [datetime]$firstTs).TotalMinutes, 1)
                if ($durationMin -lt 0) { $durationMin = $null }
            } catch { }
        }

        $sessions.Add([pscustomobject]@{
            sessionId    = if ($meta) { $meta.sessionId } else { [System.IO.Path]::GetFileNameWithoutExtension($f.Name) }
            title        = $customTitle
            firstPrompt  = if ($firstPrompt) { $firstPrompt.Substring(0, [Math]::Min(300, $firstPrompt.Length)) } else { $null }
            cwd          = if ($meta -and $meta.cwd) { $meta.cwd } else { Get-ProjectLabel $entry.ProjDirName }
            projectDir   = $entry.ProjDirName
            gitBranch    = if ($meta) { $meta.gitBranch } else { $null }
            version      = if ($meta) { $meta.version } else { $null }
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
    generated         = (Get-Date).ToUniversalTime().ToString('o')
    machine           = $env:COMPUTERNAME
    claudeDir         = $ClaudeDir
    launchEnabled     = $launchEnabled
    cleanupPeriodDays = $cleanupPeriodDays
    sessions          = $sessions
}

$json = $payload | ConvertTo-Json -Depth 6 -Compress
$dataPath = Join-Path $OutputDir 'data.js'
# data.js, not data.json: <script src> sidesteps the file:// fetch restriction.
Set-Content -Path $dataPath -Value "window.SESSION_DATA = $json;" -Encoding UTF8

Write-Host ("Indexed {0} sessions across {1} projects -> {2}" -f `
    $sessions.Count, ($sessions.projectDir | Select-Object -Unique).Count, $dataPath)

if (-not $NoLaunch) {
    $page = Join-Path $OutputDir 'sessions.html'
    if (Test-Path $page) { Start-Process $page } else { Write-Warning "Viewer not found: $page" }
}
