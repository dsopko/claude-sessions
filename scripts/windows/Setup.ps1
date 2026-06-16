<#
.SYNOPSIS
    One-shot setup for Windows. Designed to be the single command Claude runs
    after the install interview, so the user approves one action, not twelve.

.PARAMETER Terminal
    Which terminal hosts launched sessions: powershell, pwsh, or wt.
    Default: pwsh if installed, else powershell.

.PARAMETER Protocol
    yes = register claudesessions:// links (launch / + new / continue buttons).
    no  = browse-only; the page hides launch buttons.

.EXAMPLE
    .\Setup.ps1 -Terminal powershell -Protocol yes
#>
[CmdletBinding()]
param(
    [ValidateSet('powershell', 'pwsh', 'wt')]
    [string]$Terminal,
    [ValidateSet('yes', 'no')]
    [string]$Protocol = 'yes',
    [ValidateSet('page', 'claude', 'no', 'yes')]
    [string]$Shortcut = 'page',
    [ValidateSet('app', 'window', 'default')]
    [string]$ViewerLaunch = 'app'
)
if ($Shortcut -eq 'yes') { $Shortcut = 'page' }   # back-compat

$ErrorActionPreference = 'Stop'
$scriptDir = $PSScriptRoot
if (-not $scriptDir) { $scriptDir = Split-Path -Parent $MyInvocation.MyCommand.Definition }
$root = Split-Path (Split-Path $scriptDir -Parent) -Parent

# --- resolve terminal choice -------------------------------------------------
if (-not $Terminal) {
    $Terminal = if (Get-Command pwsh -ErrorAction SilentlyContinue) { 'pwsh' } else { 'powershell' }
}
if ($Terminal -eq 'wt' -and -not (Get-Command wt -ErrorAction SilentlyContinue)) {
    # Common Win11 case: Windows Terminal installed, its 'wt' alias switched off.
    $wtInstalled = $false
    try { $wtInstalled = [bool](Get-AppxPackage -Name Microsoft.WindowsTerminal -ErrorAction SilentlyContinue) } catch { }
    if ($wtInstalled) {
        Write-Warning ("Windows Terminal is installed but its 'wt' command alias is disabled. " +
            "Enable it: Settings > Apps > Advanced app settings > App execution aliases > Windows Terminal. " +
            "Then re-run setup with -Terminal wt. Falling back to powershell (blue window) for now.")
    } else {
        Write-Warning ("Windows Terminal is not installed. Install it with: " +
            "winget install Microsoft.WindowsTerminal  - then re-run setup with -Terminal wt. " +
            "Falling back to powershell (blue window) for now.")
    }
    $Terminal = 'powershell'
}
if ($Terminal -eq 'pwsh' -and -not (Get-Command pwsh -ErrorAction SilentlyContinue)) {
    Write-Warning "pwsh not found on PATH; falling back to powershell."
    $Terminal = 'powershell'
}

# --- preflight ----------------------------------------------------------------
$claudeOk = [bool](Get-Command claude -ErrorAction SilentlyContinue)
if (-not $claudeOk) {
    Write-Warning "'claude' not found on PATH. Indexing will work; launching will not until that's fixed."
}

# --- write config (read by indexer and launch handler) -------------------------
$config = [pscustomobject]@{
    platform           = 'windows'
    terminal           = $Terminal
    protocolRegistered = ($Protocol -eq 'yes')
    # How the viewer opens: app = Chromium app window (Firefox degrades to a new
    # window), window = normal new window, default = OS default (no forced
    # window). Forcing a fresh window keeps the page on the current virtual
    # desktop instead of folding into a window on another desktop.
    viewerLaunch       = $ViewerLaunch
    configuredAt       = (Get-Date).ToUniversalTime().ToString('o')
}
$config | ConvertTo-Json | Set-Content -Path (Join-Path $root 'config.json') -Encoding UTF8
Write-Host "config.json written: terminal=$Terminal, protocol=$Protocol, viewerLaunch=$ViewerLaunch"

# --- register protocol ----------------------------------------------------------
if ($Protocol -eq 'yes') {
    & (Join-Path $scriptDir 'Register-Protocol.ps1')
}

# --- desktop shortcut -----------------------------------------------------------
# page   = double-click opens the sessions page (refreshes index first; no Claude window)
# claude = double-click starts a Claude session here (hook refreshes + opens the page)
if ($Shortcut -ne 'no') {
    try {
        $claudeCmd = Get-Command claude -ErrorAction SilentlyContinue
        $shell = New-Object -ComObject WScript.Shell
        $lnk = $shell.CreateShortcut((Join-Path ([Environment]::GetFolderPath('Desktop')) 'Claude Sessions.lnk'))
        if ($Shortcut -eq 'claude' -and $claudeCmd) {
            $lnk.TargetPath = $claudeCmd.Source
        } else {
            if ($Shortcut -eq 'claude') { Write-Warning "claude not on PATH; shortcut will open the page instead." }
            $lnk.TargetPath = (Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe')
            $lnk.Arguments = ('-NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File "{0}"' -f `
                (Join-Path $scriptDir 'Update-SessionIndex.ps1'))
            if ($claudeCmd -and $claudeCmd.Source -like '*.exe') { $lnk.IconLocation = "$($claudeCmd.Source),0" }
        }
        $lnk.WorkingDirectory = $root
        $lnk.Description = 'Claude Code session history browser'
        $lnk.Save()
        Write-Host "Desktop shortcut created: Claude Sessions ($Shortcut mode)"
    } catch {
        Write-Warning "Could not create desktop shortcut: $($_.Exception.Message)"
    }
}

# --- first index + open the page -------------------------------------------------
& (Join-Path $scriptDir 'Update-SessionIndex.ps1')

Write-Host ''
Write-Host 'Setup complete.' -ForegroundColor Green
if ($Protocol -eq 'yes') {
    Write-Host 'First click on a launch button will show a browser permission prompt; allow it.'
}
