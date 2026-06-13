<#
.SYNOPSIS
    Full-text search across all session transcripts. Returns compact JSON
    grouped by session: which sessions mention the pattern, how often, and
    short context snippets. For Claude to consume; keeps token cost low.

.PARAMETER Pattern
    Regex (Select-String semantics). Use -SimpleMatch for literal text.

.PARAMETER MaxSnippets
    Max snippets returned per session. Default 3.
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory)] [string]$Pattern,
    [switch]$SimpleMatch,
    [int]$MaxSnippets = 3,
    [int]$SnippetWidth = 160,
    [string]$ClaudeDir = (Join-Path $env:USERPROFILE '.claude')
)

$ErrorActionPreference = 'Stop'
$projectsDir = Join-Path $ClaudeDir 'projects'

$files = Get-ChildItem -Path $projectsDir -Recurse -Filter '*.jsonl' -File |
    Where-Object { $_.Name -notlike 'agent-*' }

$results = [System.Collections.Generic.List[object]]::new()

foreach ($f in $files) {
    $ssArgs = @{ Path = $f.FullName; Pattern = $Pattern }
    if ($SimpleMatch) { $ssArgs.SimpleMatch = $true }
    $hits = @(Select-String @ssArgs)
    if ($hits.Count -eq 0) { continue }

    $snippets = foreach ($h in ($hits | Select-Object -First $MaxSnippets)) {
        $line = $h.Line
        $idx = if ($h.Matches.Count -gt 0) { $h.Matches[0].Index } else { 0 }
        $start = [Math]::Max(0, $idx - [int]($SnippetWidth / 2))
        $len = [Math]::Min($SnippetWidth, $line.Length - $start)
        $line.Substring($start, $len)
    }

    $results.Add([pscustomobject]@{
        sessionId  = $f.BaseName
        projectDir = $f.Directory.Name
        hitCount   = $hits.Count
        snippets   = @($snippets)
    })
}

[pscustomobject]@{
    pattern  = $Pattern
    sessions = @($results | Sort-Object hitCount -Descending)
    total    = [int](($results | Measure-Object -Property hitCount -Sum).Sum)
} | ConvertTo-Json -Depth 4
