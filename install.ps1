# Copyright (c) 2026 Arron Craig
# SPDX-License-Identifier: GPL-3.0-or-later
# This file is part of Ansys Elastic Licence Monitor. See LICENSE for terms.

[CmdletBinding()]
param()

$ErrorActionPreference = 'Stop'

$TaskName    = 'Ansys Elastic Licence Monitor'
$InstallDir  = Join-Path $env:LOCALAPPDATA 'AnsysElasticLicenceMonitor'
$sourceDir   = if ($PSScriptRoot) { $PSScriptRoot } else { Split-Path -Parent $MyInvocation.MyCommand.Path }

Write-Host "Installing Ansys Elastic Licence Monitor..."
Write-Host "  Install directory: $InstallDir"

# 1. Create install dir.
if (-not (Test-Path $InstallDir)) {
    New-Item -ItemType Directory -Path $InstallDir -Force | Out-Null
}

# 2. Copy agent files (assume they sit alongside install.ps1).
#    Skip when source == install dir (e.g. invoked from {app} by the Inno
#    Setup post-install [Run] step, where Inno has already laid the files down).
$samePath = $false
try {
    $samePath = (Resolve-Path -LiteralPath $sourceDir).Path -ieq (Resolve-Path -LiteralPath $InstallDir).Path
} catch {}
if ($samePath) {
    Write-Host "  Source dir is install dir; skipping file copy"
} else {
    $filesToCopy = @('agent.ps1', 'common.ps1', 'toast-callback.ps1', 'toast-callback.vbs')
    foreach ($f in $filesToCopy) {
        $src = Join-Path $sourceDir $f
        if (-not (Test-Path $src)) {
            throw "Missing source file: $src. Run install.ps1 from the folder that contains all agent files."
        }
        Copy-Item -Path $src -Destination $InstallDir -Force
        Write-Host "  Copied $f"
    }

    # config.json is copied only if absent so admin/user edits survive an
    # in-place re-install. To force a config reset, delete the file first or
    # uninstall (which wipes the dir) before re-running install.
    $cfgSrc = Join-Path $sourceDir 'config.json'
    $cfgDst = Join-Path $InstallDir 'config.json'
    if (Test-Path $cfgSrc) {
        if (Test-Path $cfgDst) {
            Write-Host "  config.json already exists; preserving existing config"
        } else {
            Copy-Item -Path $cfgSrc -Destination $cfgDst
            Write-Host "  Copied config.json"
        }
    } else {
        Write-Host "  config.json not in source dir; agent will use built-in defaults"
    }
}

# 3. Install BurntToast if absent.
if (-not (Get-Module -ListAvailable -Name BurntToast)) {
    Write-Host "  Installing BurntToast PowerShell module (CurrentUser scope)..."
    if (-not (Get-PackageProvider -Name NuGet -ErrorAction SilentlyContinue)) {
        Install-PackageProvider -Name NuGet -Scope CurrentUser -Force -ForceBootstrap | Out-Null
    }
    $gallery = Get-PSRepository -Name PSGallery -ErrorAction SilentlyContinue
    if ($gallery -and $gallery.InstallationPolicy -ne 'Trusted') {
        Set-PSRepository -Name PSGallery -InstallationPolicy Trusted
    }
    Install-Module -Name BurntToast -Scope CurrentUser -Force -AllowClobber
} else {
    Write-Host "  BurntToast already installed"
}

# 4. Register scheduled task: At Logon, current user, hidden window.
$agentPath = Join-Path $InstallDir 'agent.ps1'
$action = New-ScheduledTaskAction `
    -Execute 'powershell.exe' `
    -Argument "-NoProfile -WindowStyle Hidden -ExecutionPolicy Bypass -File `"$agentPath`""

$trigger = New-ScheduledTaskTrigger -AtLogOn -User "$env:USERDOMAIN\$env:USERNAME"

$settings = New-ScheduledTaskSettingsSet `
    -AllowStartIfOnBatteries `
    -DontStopIfGoingOnBatteries `
    -StartWhenAvailable `
    -RestartCount 3 `
    -RestartInterval (New-TimeSpan -Minutes 1) `
    -ExecutionTimeLimit ([TimeSpan]::Zero)

$principal = New-ScheduledTaskPrincipal `
    -UserId "$env:USERDOMAIN\$env:USERNAME" `
    -LogonType Interactive `
    -RunLevel Limited

if (Get-ScheduledTask -TaskName $TaskName -ErrorAction SilentlyContinue) {
    Unregister-ScheduledTask -TaskName $TaskName -Confirm:$false
}

Register-ScheduledTask `
    -TaskName    $TaskName `
    -Action      $action `
    -Trigger     $trigger `
    -Settings    $settings `
    -Principal   $principal `
    -Description "Detects ANSYS elastic licence checkouts and shows Windows toast notifications." | Out-Null

Write-Host "  Scheduled task '$TaskName' registered"

# 4b. Register ansyselastic: URL protocol so toast button clicks reach the agent.
. (Join-Path $InstallDir 'common.ps1')
Register-ToastProtocol -ScriptDir $InstallDir
Write-Host "  Registered ansyselastic: URL protocol"

# 5. Start it now (so the user does not need to log out / back in).
Start-ScheduledTask -TaskName $TaskName
Write-Host "  Agent started"

# 6. One-shot compliance check from inside the installer so any toast appears
#    while the user is still in the wizard's Finish page. The scheduled task
#    will run the same check on its first iteration, but that may be a few
#    seconds later; running it here is the explicit "on first install" trigger.
try {
    Import-Module BurntToast -ErrorAction Stop | Out-Null
    $installState = Load-State
    Invoke-ConfigCheckCycle -State $installState -RunMode Install
    Save-State -State $installState
} catch {
    Write-Host "  (Compliance check skipped: $_)"
}

Write-Host ""
Write-Host "Install complete."
Write-Host "  Logs:  $InstallDir\agent.log"
Write-Host "  State: $InstallDir\state.json"
Write-Host ""
Write-Host "To uninstall: powershell.exe -ExecutionPolicy Bypass -File uninstall.ps1"
