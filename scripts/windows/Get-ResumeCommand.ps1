<#
.SYNOPSIS
    Print the command that reopens a session in the permission mode it was
    running under when it ended.

.DESCRIPTION
    Bounded tail read of one transcript: never parses the whole file, and never
    returns transcript text -- only the session's permission mode and the
    resulting command line.

    Resolution rule (see STORAGE.md): take the last record in the tail window
    carrying a `permissionMode` field, whatever its type. Both 'user' records
    and dedicated 'permission-mode' records carry it; requiring a prompt
    specifically picks up a stale value on sessions whose last prompt-shaped
    record is machinery, or that toggled mode after their final prompt.

.PARAMETER Id
    Session UUID (full or unique prefix).

.PARAMETER Mode
    Skip the transcript read and map a permission mode you already have. Useful
    for testing the mapping, and for callers holding an indexed value.

.PARAMETER Quiet
    Print only the command line, with no leading `cd`.

.EXAMPLE
    ./Get-ResumeCommand.ps1 -Id 8e201382
    cd 'C:\Projects\thing'; claude --resume 8e201382-... --permission-mode acceptEdits
#>
[CmdletBinding(DefaultParameterSetName = 'ById')]
param(
    [Parameter(Mandatory, ParameterSetName = 'ById', Position = 0)] [string]$Id,
    [Parameter(Mandatory, ParameterSetName = 'ByMode')] [string]$Mode,
    [switch]$Quiet,
    [string]$ClaudeDir = (Join-Path $env:USERPROFILE '.claude')
)

$ErrorActionPreference = 'Stop'

function ConvertTo-PermissionFlag {
    <#
      Canonical permission-mode -> CLI flag mapping for this repo. Keep in sync
      with the copy in sessions.html (permFlag) and Get-SessionDetail.ps1.

      `--permission-mode` also accepts 'manual' and 'dontAsk'; both pass through
      the default arm. 'default' emits nothing -- the CLI does accept
      `--permission-mode default` despite it being absent from the advertised
      choice list, but omitting it is clearer and is what the user typed.
    #>
    param([string]$PermissionMode)
    switch ($PermissionMode) {
        'default'           { '' }
        'acceptEdits'       { '--permission-mode acceptEdits' }
        'auto'              { '--permission-mode auto' }
        'plan'              { '--permission-mode plan' }
        # The dedicated flag is the form Claude Code gates on; it can still be
        # refused at runtime (root user, settings policy), leaving 'default'.
        'bypassPermissions' { '--dangerously-skip-permissions' }
        ''                  { '' }
        $null               { '' }
        default             { "--permission-mode $PermissionMode" }
    }
}

if ($PSCmdlet.ParameterSetName -eq 'ByMode') {
    ("claude --resume <sessionId> " + (ConvertTo-PermissionFlag $Mode)).TrimEnd()
    return
}

$projectsDir = Join-Path $ClaudeDir 'projects'
$match = @(Get-ChildItem -Path $projectsDir -Recurse -Filter '*.jsonl' -File |
    Where-Object { $_.BaseName -like "$Id*" -and $_.Name -notlike 'agent-*' })

if ($match.Count -eq 0) { Write-Error "No session file matching '$Id'"; exit 1 }
if ($match.Count -gt 1) {
    Write-Error ("Ambiguous prefix '{0}' matches: {1}" -f $Id, ($match.BaseName -join ', '))
    exit 1
}
$file = $match[0]

function Read-TailScan {
    # Last $TailBytes of the file -> the last permissionMode and cwd it carries.
    param([string]$Path, [int]$TailBytes)
    $mode = $null; $dir = $null
    $fs = [System.IO.File]::Open($Path, 'Open', 'Read', 'ReadWrite')
    try {
        $len = $fs.Length
        $start = [Math]::Max(0, $len - $TailBytes)
        $fs.Seek($start, 'Begin') | Out-Null
        $buf = New-Object byte[] ($len - $start)
        $read = $fs.Read($buf, 0, $buf.Length)
        $all = [System.Text.Encoding]::UTF8.GetString($buf, 0, $read) -split "`n"
        if ($start -gt 0 -and $all.Count -gt 1) { $all = $all[1..($all.Count - 1)] }   # drop partial first line
        foreach ($raw in $all) {
            if (-not $raw.Trim()) { continue }
            try { $o = $raw | ConvertFrom-Json -ErrorAction Stop } catch { continue }
            if ($o.permissionMode) { $mode = [string]$o.permissionMode }
            if ($o.cwd) { $dir = [string]$o.cwd }
        }
    } finally { $fs.Dispose() }
    return [pscustomobject]@{ PermissionMode = $mode; Cwd = $dir }
}

# 64 KB matches the indexer's window. A long session can end with that much
# unbroken tool traffic and carry no mode record in it (3 of 164 measured, the
# worst a 12.9 MB transcript), so widen once to 1 MB before giving up. Widening
# beats reading the head, which holds the LAUNCH mode rather than the exit mode.
$scan = Read-TailScan -Path $file.FullName -TailBytes 65536
if (-not $scan.PermissionMode) {
    $wide = Read-TailScan -Path $file.FullName -TailBytes 1048576
    if ($wide.PermissionMode) { $scan = $wide }
}
$permissionMode = $scan.PermissionMode
$cwd = $scan.Cwd

$flag = ConvertTo-PermissionFlag $permissionMode
$cmd = ("claude --resume $($file.BaseName) $flag").TrimEnd()

if ($Quiet) { $cmd; return }

if ($cwd) { "cd '{0}'; {1}" -f $cwd.Replace("'", "''"), $cmd } else { $cmd }
