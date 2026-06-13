<#
.SYNOPSIS
    Cleanly removes everything ClaudeSessions installed or generated:
    the claudesessions:// protocol registration, the desktop shortcut,
    and the generated data/config files.

.DESCRIPTION
    Does NOT delete:
      - this install folder (delete it yourself afterward if you want)
      - anything under ~/.claude (your transcripts are never touched)
    Safe to run repeatedly; missing pieces are skipped with a note.

.EXAMPLE
    .\Uninstall.ps1          # remove protocol + shortcut + generated files
#>
[CmdletBinding()]
param()

$ErrorActionPreference = 'Stop'
$scriptDir = $PSScriptRoot
if (-not $scriptDir) { $scriptDir = Split-Path -Parent $MyInvocation.MyCommand.Definition }
$root = Split-Path (Split-Path $scriptDir -Parent) -Parent

Write-Host 'ClaudeSessions uninstall' -ForegroundColor Cyan

# 1. Protocol registration
$key = 'HKCU:\Software\Classes\claudesessions'
if (Test-Path $key) {
    Remove-Item -Path $key -Recurse -Force
    Write-Host '  removed: claudesessions:// protocol registration'
} else {
    Write-Host '  skipped: protocol was not registered'
}

# 2. Desktop shortcut
$lnk = Join-Path ([Environment]::GetFolderPath('Desktop')) 'Claude Sessions.lnk'
if (Test-Path $lnk) {
    Remove-Item -Path $lnk -Force
    Write-Host '  removed: desktop shortcut'
} else {
    Write-Host '  skipped: no desktop shortcut found'
}

# 3. Generated files (index + config)
foreach ($f in @('data.js', 'config.json')) {
    $p = Join-Path $root $f
    if (Test-Path $p) {
        Remove-Item -Path $p -Force
        Write-Host "  removed: $f"
    } else {
        Write-Host "  skipped: $f not present"
    }
}

Write-Host ''
Write-Host 'Done. Not touched:' -ForegroundColor Green
Write-Host "  - this folder ($root) - delete it manually for full removal"
Write-Host '  - your transcripts under ~/.claude/projects (never modified by this tool)'
Write-Host ''
Write-Host 'To reinstall fresh: .\scripts\windows\Setup.ps1'
