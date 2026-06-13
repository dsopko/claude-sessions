<#
.SYNOPSIS
    Compact JSON digest of one session: metadata, first prompt, last N user
    prompts, event counts, duration. Designed for Claude to consume instead
    of raw-reading transcripts.

.PARAMETER Id
    Session UUID (full or unique prefix).

.PARAMETER LastN
    How many trailing user prompts to include. Default 10.
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory)] [string]$Id,
    [int]$LastN = 10,
    [string]$ClaudeDir = (Join-Path $env:USERPROFILE '.claude')
)

$ErrorActionPreference = 'Stop'
$projectsDir = Join-Path $ClaudeDir 'projects'

$match = Get-ChildItem -Path $projectsDir -Recurse -Filter '*.jsonl' -File |
    Where-Object { $_.BaseName -like "$Id*" -and $_.Name -notlike 'agent-*' }

if (-not $match) { Write-Error "No session file matching '$Id'"; exit 1 }
if ($match.Count -gt 1) {
    Write-Error ("Ambiguous prefix '{0}' matches: {1}" -f $Id, ($match.BaseName -join ', '))
    exit 1
}
$file = $match[0]

$meta = $null; $firstPrompt = $null; $firstTs = $null; $lastTs = $null
$customTitle = $null
$counts = @{}
$userPrompts = [System.Collections.Generic.List[object]]::new()

$reader = [System.IO.StreamReader]::new($file.FullName)
try {
    while (-not $reader.EndOfStream) {
        $raw = $reader.ReadLine()
        if (-not $raw.Trim()) { continue }
        try { $o = $raw | ConvertFrom-Json -ErrorAction Stop } catch { continue }

        $t = if ($o.type) { [string]$o.type } else { 'unknown' }
        if ($counts.ContainsKey($t)) { $counts[$t]++ } else { $counts[$t] = 1 }

        if ($null -eq $meta -and $o.sessionId) { $meta = $o; $firstTs = $o.timestamp }
        if ($o.timestamp) { $lastTs = $o.timestamp }
        if ($t -eq 'custom-title' -and $o.title) { $customTitle = $o.title }

        $c = $o.message.content
        if ($t -eq 'user' -and $o.isMeta -ne $true -and $c -is [string] -and
            -not $c.TrimStart().StartsWith('<')) {
            if ($null -eq $firstPrompt) { $firstPrompt = $c }
            $userPrompts.Add([pscustomobject]@{
                timestamp = $o.timestamp
                prompt    = $c.Substring(0, [Math]::Min(500, $c.Length))
            })
        }
    }
} finally { $reader.Dispose() }

$durationMin = $null
if ($firstTs -and $lastTs) {
    try { $durationMin = [Math]::Round(([datetime]$lastTs - [datetime]$firstTs).TotalMinutes, 1) } catch { }
}

[pscustomobject]@{
    sessionId     = $file.BaseName
    title         = $customTitle
    filePath      = $file.FullName
    sizeBytes     = $file.Length
    cwd           = $meta.cwd
    gitBranch     = $meta.gitBranch
    version       = $meta.version
    startTime     = $firstTs
    lastActivity  = $lastTs
    durationMin   = $durationMin
    eventCounts   = $counts
    userPromptCount = $userPrompts.Count
    firstPrompt   = $firstPrompt
    lastPrompts   = @($userPrompts | Select-Object -Last $LastN)
    resumeCommand = "claude --resume $($file.BaseName)"
} | ConvertTo-Json -Depth 5
