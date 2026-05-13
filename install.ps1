# Copyright (c) 2026 Arron Craig
# SPDX-License-Identifier: GPL-3.0-or-later
# This file is part of Ansys Elastic Licence Monitor. See LICENSE for terms.

[CmdletBinding()]
param()

$ErrorActionPreference = 'Stop'

# WinPS 5.1 defaults SecurityProtocol to TLS 1.0/1.1. PSGallery dropped both
# in 2020, so without this every PSGallery contact (Install-PackageProvider,
# Install-Module) sits in a long internal retry loop and the hidden installer
# window appears to hang. Set once, up front.
try {
    [Net.ServicePointManager]::SecurityProtocol = `
        [Net.ServicePointManager]::SecurityProtocol -bor [Net.SecurityProtocolType]::Tls12
} catch {}

$TaskName    = 'Ansys Elastic Licence Monitor'
$InstallDir  = Join-Path $env:LOCALAPPDATA 'AnsysElasticLicenceMonitor'
$sourceDir   = if ($PSScriptRoot) { $PSScriptRoot } else { Split-Path -Parent $MyInvocation.MyCommand.Path }

# Hard ceiling on the BurntToast install step. Without this, a slow network,
# blocked proxy, or hidden PSGallery prompt can hang the Inno wizard forever
# (the [Run] step uses waituntilterminated). On timeout we fall through; the
# agent's startup self-test will toast the user about the missing module.
$burntToastInstallTimeoutSec = [int]($env:AELM_BURNTTOAST_INSTALL_TIMEOUT_SEC)
if ($burntToastInstallTimeoutSec -le 0) { $burntToastInstallTimeoutSec = 180 }

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

    # VERSION file ships next to the scripts so Get-AgentVersion has something
    # to read post-install. Absent in dev runs that haven't tagged a version.
    $verSrc = Join-Path $sourceDir 'VERSION'
    if (Test-Path $verSrc) {
        Copy-Item -Path $verSrc -Destination $InstallDir -Force
        Write-Host "  Copied VERSION"
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

# 3. Install BurntToast if absent. Pinned to a known-good version so a future
#    breaking release from the upstream module doesn't silently break the agent.
#    Bump when validating a newer release.
#
#    The actual install runs in a background job with a hard timeout because
#    Install-PackageProvider and Install-Module have NO native timeout and
#    can hang for minutes on slow networks, corporate proxies, or invisible
#    prompts (the Inno [Run] step uses runhidden waituntilterminated, so any
#    interactive prompt sits forever waiting for input that can't arrive).
$BurntToastMinVersion = '0.8.5'
$existing = Get-Module -ListAvailable -Name BurntToast | Sort-Object Version -Descending | Select-Object -First 1
if (-not $existing -or $existing.Version -lt [version]$BurntToastMinVersion) {
    Write-Host "  Installing BurntToast PowerShell module $BurntToastMinVersion+ (CurrentUser scope, up to ${burntToastInstallTimeoutSec}s)..."
    $job = Start-Job -ScriptBlock {
        param($MinVersion)
        $ErrorActionPreference = 'Stop'
        # Re-apply TLS 1.2 inside the job (separate runspace, fresh defaults).
        try {
            [Net.ServicePointManager]::SecurityProtocol = `
                [Net.ServicePointManager]::SecurityProtocol -bor [Net.SecurityProtocolType]::Tls12
        } catch {}
        if (-not (Get-PackageProvider -Name NuGet -ErrorAction SilentlyContinue)) {
            Install-PackageProvider -Name NuGet -Scope CurrentUser -Force -ForceBootstrap | Out-Null
        }
        # Trust PSGallery unconditionally and best-effort. The previous gated
        # version skipped this entirely if Get-PSRepository returned nothing,
        # which left Install-Module to emit a hidden "untrusted repo" prompt.
        try { Set-PSRepository -Name PSGallery -InstallationPolicy Trusted -ErrorAction SilentlyContinue } catch {}
        Install-Module -Name BurntToast -MinimumVersion $MinVersion -Scope CurrentUser -Force -AllowClobber -Confirm:$false
    } -ArgumentList $BurntToastMinVersion

    $completed = Wait-Job -Job $job -Timeout $burntToastInstallTimeoutSec
    if (-not $completed) {
        Write-Host "  WARN: BurntToast install did not finish within ${burntToastInstallTimeoutSec}s; continuing without it."
        Write-Host "        The agent will detect the missing module on startup and toast the user."
        Write-Host "        To install manually later, run:  Install-Module BurntToast -Scope CurrentUser"
        try { Stop-Job -Job $job -ErrorAction SilentlyContinue } catch {}
    } else {
        try {
            $jobOutput = Receive-Job -Job $job -ErrorAction Stop
            Write-Host "  BurntToast install completed"
        } catch {
            Write-Host "  WARN: BurntToast install failed: $_"
            Write-Host "        The agent will detect the missing module on startup and toast the user."
        }
    }
    try { Remove-Job -Job $job -Force -ErrorAction SilentlyContinue } catch {}
} else {
    Write-Host "  BurntToast already installed (v$($existing.Version))"
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
