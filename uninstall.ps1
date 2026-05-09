# Copyright (c) 2026 Arron Craig
# SPDX-License-Identifier: GPL-3.0-or-later
# This file is part of Ansys Elastic Licence Monitor. See LICENSE for terms.

[CmdletBinding()]
param(
    # Inno Setup's [UninstallRun] passes this so it can own the dir-removal step
    # itself (via [UninstallDelete]). Manual `uninstall.ps1` invocations omit it
    # and the script wipes the dir as before.
    [switch]$SkipDirRemoval
)

$TaskName   = 'Ansys Elastic Licence Monitor'
$InstallDir = Join-Path $env:LOCALAPPDATA 'AnsysElasticLicenceMonitor'

Write-Host "Uninstalling Ansys Elastic Licence Monitor..."

$task = Get-ScheduledTask -TaskName $TaskName -ErrorAction SilentlyContinue
if ($task) {
    if ($task.State -eq 'Running') {
        Stop-ScheduledTask -TaskName $TaskName -ErrorAction SilentlyContinue
    }
    Unregister-ScheduledTask -TaskName $TaskName -Confirm:$false
    Write-Host "  Scheduled task removed"
} else {
    Write-Host "  No scheduled task found"
}

# Kill any running agent.ps1 instances.
Get-CimInstance Win32_Process -Filter "Name='powershell.exe'" -ErrorAction SilentlyContinue |
    Where-Object { $_.CommandLine -like '*agent.ps1*' } |
    ForEach-Object {
        try {
            Stop-Process -Id $_.ProcessId -Force -ErrorAction SilentlyContinue
            Write-Host "  Killed running agent (PID $($_.ProcessId))"
        } catch {}
    }

$regBase = 'HKCU:\Software\Classes\ansyselastic'
if (Test-Path $regBase) {
    Remove-Item -Path $regBase -Recurse -Force -ErrorAction SilentlyContinue
    Write-Host "  Unregistered ansyselastic: URL protocol"
}

if ($SkipDirRemoval) {
    Write-Host "  Skipping install-dir removal (-SkipDirRemoval set)"
} elseif (Test-Path $InstallDir) {
    try {
        Remove-Item -Path $InstallDir -Recurse -Force
        Write-Host "  Removed $InstallDir"
    } catch {
        Write-Warning "  Could not remove $InstallDir : $_"
    }
}

Write-Host ""
Write-Host "Uninstall complete."
Write-Host "Note: BurntToast PowerShell module was left installed."
Write-Host "To remove it: Uninstall-Module BurntToast"
