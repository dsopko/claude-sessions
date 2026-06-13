<#
.SYNOPSIS
    Registers the claudesessions:// protocol for the current user (HKCU, no
    admin rights needed), pointing at Launch-Handler.ps1 in this folder.

.PARAMETER Unregister
    Remove the protocol registration instead.
#>
[CmdletBinding()]
param([switch]$Unregister)

$ErrorActionPreference = 'Stop'
$key = 'HKCU:\Software\Classes\claudesessions'

if ($Unregister) {
    if (Test-Path $key) {
        Remove-Item -Path $key -Recurse -Force
        Write-Host 'claudesessions:// protocol unregistered.'
    } else {
        Write-Host 'Protocol was not registered.'
    }
    return
}

$handler = Join-Path $PSScriptRoot 'Launch-Handler.ps1'
if (-not (Test-Path $handler)) {
    Write-Error "Launch-Handler.ps1 not found next to this script."
    exit 1
}

# Browser invokes this hidden; the handler itself opens the visible terminal.
$command = '"{0}" -NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File "{1}" "%1"' -f `
    (Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe'), $handler

New-Item -Path $key -Force | Out-Null
Set-ItemProperty -Path $key -Name '(Default)' -Value 'URL:Claude Sessions'
Set-ItemProperty -Path $key -Name 'URL Protocol' -Value ''
New-Item -Path "$key\shell\open\command" -Force | Out-Null
Set-ItemProperty -Path "$key\shell\open\command" -Name '(Default)' -Value $command

Write-Host 'claudesessions:// protocol registered for the current user.'
Write-Host "Handler: $handler"
Write-Host 'Note: if you move this folder, run this script again to update the path.'
