<#
.SYNOPSIS
    Handler for the claudesessions:// protocol. Invoked by the browser with
    the clicked URL as its argument.

.DESCRIPTION
    Verbs:
      claudesessions://resume/<session-uuid>     resume that session in its directory
      claudesessions://delete/<session-uuid>     permanently delete that transcript
                                                 (native Yes/No confirm; path resolved
                                                 from the index, never from the URL)
      claudesessions://new/<projectKey>          new claude session in that project
      claudesessions://continue/<projectKey>     claude --continue in that project
      claudesessions://assist/start              claude session in the install folder,
                                                 fixed kickoff prompt (search assistant)
      claudesessions://reindex/now               regenerate data.js (no terminal,
                                                 no data from the URL)

    SECURITY MODEL: once registered, ANY webpage can attempt these URLs, so
    the URL is treated as hostile input. The argument is matched against a
    strict pattern and used ONLY as a lookup key into the local index
    (data.js). Directories and commands are resolved exclusively from the
    index; nothing from the URL is ever interpolated into a command line or
    used as a filesystem path. Unknown verb/key => message box, exit.
#>
[CmdletBinding()]
param([Parameter(Mandatory)][string]$Url)

$ErrorActionPreference = 'Stop'

function Show-Message {
    param([string]$Text, [string]$Title = 'Claude Sessions')
    try {
        Add-Type -AssemblyName PresentationFramework
        [System.Windows.MessageBox]::Show($Text, $Title) | Out-Null
    } catch {
        # Last-ditch fallback if WPF is unavailable
        (New-Object -ComObject WScript.Shell).Popup($Text, 0, $Title) | Out-Null
    }
}

function Confirm-Message {
    # Modal Yes/No. Returns $true only on an explicit Yes. This is the backstop
    # for destructive verbs: even a hostile page firing the URL cannot delete
    # anything without the user clicking Yes here.
    param([string]$Text, [string]$Title = 'Claude Sessions')
    try {
        Add-Type -AssemblyName PresentationFramework
        $r = [System.Windows.MessageBox]::Show(
            $Text, $Title,
            [System.Windows.MessageBoxButton]::YesNo,
            [System.Windows.MessageBoxImage]::Warning)
        return ($r -eq [System.Windows.MessageBoxResult]::Yes)
    } catch {
        # WScript.Shell.Popup: type 4 = Yes/No; return value 6 = Yes.
        $r = (New-Object -ComObject WScript.Shell).Popup($Text, 0, $Title, 4)
        return ($r -eq 6)
    }
}

try {
    # --- parse + validate (hostile input) ------------------------------------
    $decoded = [System.Uri]::UnescapeDataString($Url).Trim()
    if ($decoded -notmatch '^claudesessions://(resume|delete|new|continue|assist|reindex)/([^/?#]+)/?$') {
        Show-Message "Unrecognized link:`n$Url"
        exit 1
    }
    $verb = $Matches[1]
    $arg  = $Matches[2]

    $uuidPattern = '^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}$'
    $keyPattern  = '^[A-Za-z0-9._-]{1,200}$'

    if ($verb -in @('resume','delete') -and $arg -notmatch $uuidPattern) {
        Show-Message "Invalid session id in link."
        exit 1
    }
    if ($verb -eq 'assist' -and $arg -ne 'start') {
        # assist takes no data - the argument must be the literal 'start'
        Show-Message "Invalid assist link."
        exit 1
    }
    if ($verb -eq 'reindex' -and $arg -ne 'now') {
        # reindex takes no data - the argument must be the literal 'now'
        Show-Message "Invalid reindex link."
        exit 1
    }
    if ($verb -notin @('resume','assist','reindex') -and $arg -notmatch $keyPattern) {
        Show-Message "Invalid project key in link."
        exit 1
    }

    # reindex: no terminal, no claude, nothing from the URL. Just regenerate
    # data.js by running the indexer in-process (the handler is already hidden).
    # Handled here, before any index load, because it does not launch a session.
    if ($verb -eq 'reindex') {
        $scriptDir = $PSScriptRoot
        if (-not $scriptDir) { $scriptDir = Split-Path -Parent $MyInvocation.MyCommand.Definition }
        $updater = Join-Path $scriptDir 'Update-SessionIndex.ps1'
        if (-not (Test-Path $updater)) {
            Show-Message "Indexer not found:`n$updater"
            exit 1
        }
        & $updater -NoLaunch
        exit 0
    }

    # --- load index (the only source of truth) --------------------------------
    $scriptDir = $PSScriptRoot
    if (-not $scriptDir) { $scriptDir = Split-Path -Parent $MyInvocation.MyCommand.Definition }
    $root = Split-Path (Split-Path $scriptDir -Parent) -Parent
    $dataPath = Join-Path $root 'data.js'
    if (-not (Test-Path $dataPath)) {
        Show-Message "Index not found:`n$dataPath`n`nRun Update-SessionIndex.ps1 first."
        exit 1
    }
    $raw = Get-Content -Path $dataPath -Raw
    if ($raw -notmatch '(?s)^\s*window\.SESSION_DATA\s*=\s*(.*);\s*$') {
        Show-Message "Index file is malformed. Re-run Update-SessionIndex.ps1."
        exit 1
    }
    $data = $Matches[1] | ConvertFrom-Json

    # delete: no terminal, no claude. Resolve the transcript path from the index
    # (never from the URL), prove it is a .jsonl under this machine's
    # ~/.claude/projects tree, confirm with the user, delete, then reindex.
    if ($verb -eq 'delete') {
        $s = @($data.sessions | Where-Object { $_.sessionId -eq $arg }) | Select-Object -First 1
        if (-not $s) {
            Show-Message "Session not in the index. The page may be stale - refresh the index and try again."
            exit 1
        }
        $target = $s.filePath
        if (-not $target) {
            Show-Message "That session has no file path in the index."
            exit 1
        }

        # Path safety (defense in depth): the file must live under the indexed
        # claudeDir\projects tree and be a .jsonl transcript. Guards against a
        # corrupted index pointing the delete somewhere it should never reach.
        $projectsRoot = Join-Path $data.claudeDir 'projects'
        try {
            $fullTarget = [System.IO.Path]::GetFullPath($target)
            $fullRoot   = [System.IO.Path]::GetFullPath($projectsRoot)
        } catch {
            Show-Message "Could not resolve the transcript path."
            exit 1
        }
        $rootPrefix = $fullRoot.TrimEnd('\') + '\'
        if (-not $fullTarget.StartsWith($rootPrefix, [System.StringComparison]::OrdinalIgnoreCase) -or
            -not $fullTarget.EndsWith('.jsonl', [System.StringComparison]::OrdinalIgnoreCase)) {
            Show-Message "Refusing to delete - path is outside the session store:`n$fullTarget"
            exit 1
        }
        if (-not (Test-Path -LiteralPath $fullTarget)) {
            Show-Message "Transcript already gone:`n$fullTarget`n`nThe page may be stale - refresh the index."
            exit 1
        }

        if (-not (Confirm-Message "Permanently delete this session transcript?`n`n$fullTarget`n`nThis cannot be undone." 'Delete session')) {
            exit 0
        }

        try {
            Remove-Item -LiteralPath $fullTarget -Force -ErrorAction Stop
        } catch {
            # A live session holds a lock on its own transcript on Windows.
            Show-Message "Could not delete the transcript:`n$($_.Exception.Message)`n`nIf this is the session you are currently running, exit it first."
            exit 1
        }

        # Refresh the index so the reloaded page no longer shows the row.
        $updater = Join-Path $scriptDir 'Update-SessionIndex.ps1'
        if (Test-Path $updater) { & $updater -NoLaunch }
        exit 0
    }

    # --- resolve from index ----------------------------------------------------
    $cwd = $null
    $claudeArgs = $null

    switch ($verb) {
        'assist' {
            $cwd = $root
            # Fixed, hardcoded prompt. NEVER substitute URL content here (SECURITY.md).
            $claudeArgs = '"The user clicked Search with Claude on the sessions page. Greet them in one line and ask what they want to find in their session history, then answer using the scripts per CLAUDE.md."'
            # The session's startup hook re-runs the indexer; the page is already open.
            $env:CLAUDESESSIONS_NOLAUNCH = '1'
        }
        'resume' {
            $s = @($data.sessions | Where-Object { $_.sessionId -eq $arg }) | Select-Object -First 1
            if (-not $s) {
                Show-Message "Session not in the index. The page may be stale - refresh the index and try again."
                exit 1
            }
            $cwd = $s.cwd
            $claudeArgs = "--resume $($s.sessionId)"   # value from index, not from URL
        }
        default {
            $matches2 = @($data.sessions | Where-Object { $_.projectDir -eq $arg } |
                          Sort-Object lastActivity -Descending)
            if ($matches2.Count -eq 0) {
                Show-Message "Project not in the index. Refresh the index and try again."
                exit 1
            }
            $cwd = $matches2[0].cwd
            $claudeArgs = if ($verb -eq 'continue') { '--continue' } else { '' }
        }
    }

    if (-not $cwd -or -not (Test-Path -LiteralPath $cwd)) {
        Show-Message "Directory no longer exists:`n$cwd"
        exit 1
    }

    # --- launch ----------------------------------------------------------------
    if (-not (Get-Command claude -ErrorAction SilentlyContinue)) {
        Show-Message "Could not find 'claude' on PATH for this user."
        exit 1
    }

    # Terminal preference from config.json (Setup.ps1); sane fallback without it.
    $term = $null
    $configPath = Join-Path $root 'config.json'
    if (Test-Path $configPath) {
        try { $term = (Get-Content -Path $configPath -Raw | ConvertFrom-Json).terminal } catch { }
    }
    if (-not $term) {
        $term = if (Get-Command pwsh -ErrorAction SilentlyContinue) { 'pwsh' } else { 'powershell' }
    }
    $cmd = ('claude ' + $claudeArgs).Trim()
    # -EncodedCommand: the command crosses up to three argument parsers
    # (Start-Process join, argv tokenizer, wt). Plain -Command loses its
    # quotes in transit (see GOTCHAS.md); base64 survives all layers intact.
    $enc = [Convert]::ToBase64String([System.Text.Encoding]::Unicode.GetBytes($cmd))

    if ($term -eq 'wt' -and (Get-Command wt -ErrorAction SilentlyContinue)) {
        $inner = if (Get-Command pwsh -ErrorAction SilentlyContinue) { 'pwsh' } else { 'powershell' }
        Start-Process -FilePath (Get-Command wt).Source -ArgumentList @('-d', $cwd, $inner, '-NoExit', '-EncodedCommand', $enc)
    } else {
        if ($term -eq 'wt') { $term = 'powershell' }   # configured wt but it's gone
        Start-Process -FilePath $term -WorkingDirectory $cwd -ArgumentList @('-NoExit', '-EncodedCommand', $enc)
    }
} catch {
    Show-Message "Launch failed:`n$($_.Exception.Message)"
    exit 1
}
