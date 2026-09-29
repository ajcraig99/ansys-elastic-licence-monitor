# Copyright (c) 2026 Arron Craig
# SPDX-License-Identifier: GPL-3.0-or-later
# This file is part of Ansys Elastic Licence Monitor. See LICENSE for terms.

[CmdletBinding()]
param(
    # Set by the debug build of the Inno installer (ISCC /DDebugBuild=1).
    # Flips debug.enabled=true in the installed config.json so the agent
    # surfaces View-triggers / Open-full-log toast buttons and verbose
    # match/near-miss logging. The release installer never passes this.
    [switch]$DebugBuild
)

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
    $filesToCopy = @('agent.ps1', 'agent-launcher.vbs', 'common.ps1', 'toast-callback.ps1', 'toast-callback.vbs')
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

# 2b. Debug build: flip debug.enabled in the installed config.json via a JSON
#     merge so we preserve any other user/admin edits (config.json copy uses
#     onlyifdoesntexist, so an upgrade may be sitting on a customised file).
#     This is a one-way switch: the release installer does NOT clear the flag
#     on its own. To leave debug, edit config.json or uninstall + reinstall.
if ($DebugBuild) {
    Write-Host "  Debug build requested; enabling debug mode in config.json"
    $cfgPath = Join-Path $InstallDir 'config.json'
    try {
        if (Test-Path -LiteralPath $cfgPath) {
            $existing = Get-Content -LiteralPath $cfgPath -Raw | ConvertFrom-Json
        } else {
            $existing = [PSCustomObject]@{}
        }
        $existingProps = $existing.PSObject.Properties.Name
        if ($existingProps -notcontains 'debug') {
            $existing | Add-Member -NotePropertyName 'debug' -NotePropertyValue ([PSCustomObject]@{ enabled = $true })
        } else {
            $dbgProps = $existing.debug.PSObject.Properties.Name
            if ($dbgProps -contains 'enabled') {
                $existing.debug.enabled = $true
            } else {
                $existing.debug | Add-Member -NotePropertyName 'enabled' -NotePropertyValue $true
            }
        }
        $existing | ConvertTo-Json -Depth 10 | Set-Content -LiteralPath $cfgPath -Encoding UTF8
        Write-Host "  Set debug.enabled = true in $cfgPath"
    } catch {
        Write-Host "  WARN: failed to set debug.enabled in $cfgPath : $_"
    }
}

# 3. Install BurntToast if absent. Pinned to exactly the version the agent is
#    tested against (-RequiredVersion, side by side with any other installed
#    version) -- the PSGallery latest is 1.x, which has not been validated.
#    agent.ps1 imports this exact version when present. Bump both together
#    ($script:BurntToastVersion in common.ps1) after validating a newer release.
#
#    The actual install runs in a background job with a hard timeout because
#    Install-PackageProvider and Install-Module have NO native timeout and
#    can hang for minutes on slow networks, corporate proxies, or invisible
#    prompts (the Inno [Run] step uses runhidden waituntilterminated, so any
#    interactive prompt sits forever waiting for input that can't arrive).
$BurntToastVersion = '0.8.5'
$existing = Get-Module -ListAvailable -Name BurntToast | Where-Object { $_.Version -eq [version]$BurntToastVersion } | Select-Object -First 1
if (-not $existing) {
    Write-Host "  Installing BurntToast PowerShell module $BurntToastVersion (CurrentUser scope, up to ${burntToastInstallTimeoutSec}s)..."
    $job = Start-Job -ScriptBlock {
        param($Version)
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
        Install-Module -Name BurntToast -RequiredVersion $Version -Scope CurrentUser -Force -AllowClobber -Confirm:$false
    } -ArgumentList $BurntToastVersion

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

# 4. Register scheduled task: At Logon, current user, no window.
#    The task runs wscript.exe on agent-launcher.vbs rather than powershell.exe
#    directly: with Windows Terminal as the default terminal (Windows 11),
#    powershell.exe -WindowStyle Hidden leaves a visible Terminal window open
#    for the agent's whole lifetime. //B suppresses any script-error dialog.
$launcherPath = Join-Path $InstallDir 'agent-launcher.vbs'
$action = New-ScheduledTaskAction `
    -Execute 'wscript.exe' `
    -Argument "//B //Nologo `"$launcherPath`""

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

$existingTask = Get-ScheduledTask -TaskName $TaskName -ErrorAction SilentlyContinue
if ($existingTask) {
    if ($existingTask.State -eq 'Running') {
        Stop-ScheduledTask -TaskName $TaskName -ErrorAction SilentlyContinue
    }
    Unregister-ScheduledTask -TaskName $TaskName -Confirm:$false
}

# Stop any agent still running from a previous install. Inno Setup installs over
# the top without running the old uninstaller, and the running agent holds the
# single-instance mutex -- so without this the freshly started agent exits at
# once and the old code (and, pre-launcher, its visible window) runs until logoff.
# Same full-path match as uninstall.ps1 so unrelated PowerShell is left alone.
$agentPattern = [regex]::Escape((Join-Path $InstallDir 'agent.ps1'))
Get-CimInstance Win32_Process -Filter "Name='powershell.exe'" -ErrorAction SilentlyContinue |
    Where-Object { $_.CommandLine -and $_.CommandLine -match $agentPattern -and $_.CommandLine -notmatch '-Status' } |
    ForEach-Object {
        try {
            Stop-Process -Id $_.ProcessId -Force -ErrorAction Stop
            Write-Host "  Stopped previously running agent (PID $($_.ProcessId))"
        } catch {}
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
    Import-PinnedBurntToast
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
