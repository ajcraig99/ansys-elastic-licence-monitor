# Copyright (c) 2026 Arron Craig
# SPDX-License-Identifier: GPL-3.0-or-later
# This file is part of Ansys Elastic Licence Monitor. See LICENSE for terms.

[CmdletBinding()]
param(
    [int]$PollIntervalSeconds            = 10,
    [int]$EscalationMinutes              = 60,
    [int]$ElasticDetectionThresholdSec   = 30,
    # When set, prints a one-shot status summary and exits. For "is the agent
    # actually doing anything?" troubleshooting without tailing logs.
    [switch]$Status
)

Set-StrictMode -Version 3.0
$ErrorActionPreference = 'Stop'

# Resolve script root robustly when launched via -File.
$scriptRoot = if ($PSScriptRoot) { $PSScriptRoot } else { Split-Path -Parent $MyInvocation.MyCommand.Path }
. (Join-Path $scriptRoot 'common.ps1')

Initialize-AppDataDir

if ($Status) {
    # Summary-and-exit path for users who want to know the agent is alive.
    $version = Get-AgentVersion
    $envInfo = Get-AnsysEnvironment
    Write-Host "Ansys Elastic Licence Monitor"
    Write-Host "  Version            : $version"
    Write-Host "  Install dir        : $script:AppDataDir"
    Write-Host "  Log file           : $script:LogFilePath"
    Write-Host "  State file         : $script:StateFilePath"
    Write-Host "  ANSYS Inc root     : $($envInfo.AnsysIncRoot)"
    Write-Host "  Versions detected  : $(@($envInfo.VersionDirs | ForEach-Object { $_.Name }) -join ', ')"
    Write-Host "  lmutil.exe         : $($envInfo.LmutilPath)"
    Write-Host "  ansyslmd.ini       : $($envInfo.AnsyslmdIniPath)"
    Write-Host "  Licence server     : $($script:LicServerHost):$($script:LicServerPort)"
    Write-Host "  Detection process  : $script:DetectionProcessName"
    $task = Get-ScheduledTask -TaskName 'Ansys Elastic Licence Monitor' -ErrorAction SilentlyContinue
    Write-Host "  Scheduled task     : $(if ($task) { "$($task.State)" } else { 'not installed' })"
    $running = Get-CimInstance Win32_Process -Filter "Name='powershell.exe'" -ErrorAction SilentlyContinue |
        Where-Object { $_.CommandLine -like '*agent.ps1*' -and $_.ProcessId -ne $PID }
    Write-Host "  Agent process      : $(if ($running) { "PID $(@($running).ForEach{ $_.ProcessId } -join ',')" } else { 'not running' })"
    exit 0
}

# Single-instance guard. Two agents draining the same toast queue and writing
# state.json would double-toast and clobber each other's state -- possible via the
# scheduled task's -RestartCount overlap or a manual run beside the task. Hold a
# session-scoped named mutex for the process lifetime; a second instance sees it
# held and exits cleanly. AbandonedMutexException means the prior holder died
# without releasing (e.g. was killed) -- we then legitimately own it.
#
# Wait briefly rather than giving up at once: after Stop-ScheduledTask the old
# agent only notices its launcher is gone at the top of its next iteration (see
# Test-LauncherAlive), so an immediate Start-ScheduledTask must outlast that.
$script:SingleInstanceMutex = New-Object System.Threading.Mutex($false, 'Local\AnsysElasticLicenceMonitor')
$haveInstanceLock = $false
$instanceWait = [TimeSpan]::FromSeconds([Math]::Max(30, 2 * $PollIntervalSeconds + 10))
try {
    $haveInstanceLock = $script:SingleInstanceMutex.WaitOne($instanceWait)
} catch [System.Threading.AbandonedMutexException] {
    $haveInstanceLock = $true
}
if (-not $haveInstanceLock) {
    Write-AgentLog "Another agent instance is already running; exiting." -Level WARN
    exit 0
}

# Launcher watch. The scheduled task runs wscript.exe agent-launcher.vbs, which
# starts this process hidden and waits on it. Stop-ScheduledTask kills only the
# wscript.exe it started, so without this the agent would outlive a task stop and
# a restart would not reload config. When launched that way, remember the parent
# (PID + start time, to survive PID reuse) and exit once it is gone. Dev runs from
# a console have a different parent and are unaffected. One CommandLine read of a
# single PID at startup, so the slow-WMI concern in CLAUDE.md does not apply.
$script:LauncherPid   = $null
$script:LauncherStart = $null
try {
    $self   = Get-CimInstance Win32_Process -Filter "ProcessId=$PID" -ErrorAction Stop
    $parent = Get-CimInstance Win32_Process -Filter "ProcessId=$($self.ParentProcessId)" -ErrorAction Stop
    if ($parent -and $parent.Name -eq 'wscript.exe' -and $parent.CommandLine -like '*agent-launcher.vbs*') {
        $script:LauncherStart = (Get-Process -Id $parent.ProcessId -ErrorAction Stop).StartTime
        $script:LauncherPid   = [int]$parent.ProcessId
    }
} catch {
    Write-AgentLog "Could not identify launcher process: $_" -Level DEBUG
}

function Test-LauncherAlive {
    if (-not $script:LauncherPid) { return $true }
    $p = Get-Process -Id $script:LauncherPid -ErrorAction SilentlyContinue
    return [bool]($p -and $p.StartTime -eq $script:LauncherStart)
}

Write-AgentLog "agent.ps1 starting (version=$(Get-AgentVersion) poll=${PollIntervalSeconds}s escalation=${EscalationMinutes}m threshold=${ElasticDetectionThresholdSec}s pid=$PID)"

try {
    Import-PinnedBurntToast
} catch {
    Write-AgentLog "BurntToast not available: $_" -Level ERROR
    Write-AgentLog "Run install.ps1, or: Install-Module BurntToast -Scope CurrentUser" -Level ERROR
    exit 1
}

# Toast button clicks fire a custom URL protocol (ansyselastic:<action>?session=<key>)
# which Windows hands off to toast-callback.ps1 via HKCU registry. The callback
# writes to the queue file we drain each loop iteration.
Register-ToastProtocol -ScriptDir $scriptRoot

function Show-FirstElasticToast {
    param(
        [Parameter(Mandatory)][string]$SessionKey,
        [string]$Feature
    )
    try {
        $encodedKey  = [System.Uri]::EscapeDataString($SessionKey)
        $btnGotIt    = New-BTButton -Content "Got it"                    -Arguments "ansyselastic:got_it?session=$encodedKey"   -ActivationType Protocol
        $btnSuppress = New-BTButton -Content "Don't bug me this session" -Arguments "ansyselastic:suppress?session=$encodedKey" -ActivationType Protocol

        # Default body names the specific feature so the user can see what
        # actually went elastic (often surprising in a "just Mechanical" session).
        $displayName = if ($Feature) { Get-FeatureDisplayName -Feature $Feature } else { 'a feature' }
        $bodyMsg = "You are now using paid ANSYS elastic licensing for $displayName. Reminder in $EscalationMinutes min if still active."

        # Enrich with perpetual context if the feature is one we own perpetually
        # and the perpetual is currently unavailable.
        if ($Feature) {
            $ctx = Get-PerpetualContext -Feature $Feature
            if ($ctx) {
                switch ($ctx.Status) {
                    'Unreachable' {
                        $bodyMsg = "ANSYS licence server unreachable. You are now using paid elastic for $displayName."
                    }
                    'InUseByOthers' {
                        $userList = ($ctx.Users | Select-Object -Unique) -join ', '
                        $bodyMsg = "Perpetual $displayName held by $userList. You are now using paid elastic instead."
                    }
                }
                Write-AgentLog "Perpetual context for $Feature : $($ctx.Status)"
            }
        }

        $headerText = New-BTText -Content "ANSYS Elastic Licensing"
        $bodyText   = New-BTText -Content $bodyMsg

        $binding = New-BTBinding -Children $headerText, $bodyText
        $visual  = New-BTVisual  -BindingGeneric $binding

        # Debug builds gain two triage buttons. BurntToast accepts at most 5
        # buttons per toast; we ship 4 here, so any future addition has to
        # think about that limit.
        $buttons = @($btnGotIt, $btnSuppress)
        if ($script:DebugModeEnabled) {
            $btnTriggers = New-BTButton -Content "View triggers" -Arguments "ansyselastic:view_triggers?session=$encodedKey" -ActivationType Protocol
            $btnOpenLog  = New-BTButton -Content "Open full log" -Arguments "ansyselastic:open_log?session=$encodedKey"      -ActivationType Protocol
            $buttons += $btnTriggers
            $buttons += $btnOpenLog
        }
        $actions = New-BTAction  -Buttons $buttons
        $audio   = New-BTAudio   -Source 'ms-winsoundevent:Notification.Reminder'
        # Body click is harmless on toast 1 (same effect as "Got it"), so route it to got_it.
        $content = New-BTContent -Visual $visual -Actions $actions -Audio $audio `
                                 -Launch "ansyselastic:got_it?session=$encodedKey" -ActivationType Protocol

        Submit-BTNotification -Content $content -UniqueIdentifier "elastic-first-$SessionKey"
        Write-AgentLog "Toast 1 fired for $SessionKey"
    } catch {
        Write-AgentLog "Toast 1 failed for $SessionKey : $_" -Level ERROR
    }
}

function Format-Elapsed {
    param([Parameter(Mandatory)][int]$Minutes)
    if ($Minutes -lt 60) { return "$Minutes min" }
    $h = [Math]::Floor($Minutes / 60); $m = $Minutes % 60
    if ($m -eq 0) { return "$h h" }
    return "$h h $m min"
}

function Show-EscalationToast {
    param(
        [Parameter(Mandatory)][string]$SessionKey,
        # Minutes the longest-held elastic feature has been continuously checked
        # out, so the text stays true after re-arms (2 h, 3 h) and snoozes.
        [Parameter(Mandatory)][int]$ElapsedMinutes
    )
    try {
        $encodedKey = [System.Uri]::EscapeDataString($SessionKey)
        $btnAccept  = New-BTButton -Content "Keep billing me" -Arguments "ansyselastic:accept?session=$encodedKey" -ActivationType Protocol

        $headerText = New-BTText -Content "ANSYS Elastic Licensing - action needed"
        $bodyText   = New-BTText -Content "ANSYS elastic licensing has been in use for $(Format-Elapsed -Minutes $ElapsedMinutes). This costs money for every hour it stays open. Close ANSYS now to stop billing, or click 'Keep billing me' to continue."

        $binding = New-BTBinding -Children $headerText, $bodyText
        $visual  = New-BTVisual  -BindingGeneric $binding

        $buttons = @($btnAccept)
        if ($script:DebugModeEnabled) {
            $btnTriggers = New-BTButton -Content "View triggers" -Arguments "ansyselastic:view_triggers?session=$encodedKey" -ActivationType Protocol
            $btnOpenLog  = New-BTButton -Content "Open full log" -Arguments "ansyselastic:open_log?session=$encodedKey"      -ActivationType Protocol
            $buttons += $btnTriggers
            $buttons += $btnOpenLog
        }
        $actions = New-BTAction  -Buttons $buttons
        $audio   = New-BTAudio   -Source 'ms-winsoundevent:Notification.Looping.Alarm2'
        # scenario=Reminder makes the toast sticky (does not auto-dismiss) and loops the audio.
        # Body click goes to "snooze" so an accidental click only buys 5 minutes of quiet.
        $content = New-BTContent -Visual $visual -Actions $actions -Audio $audio -Scenario Reminder `
                                 -Launch "ansyselastic:snooze?session=$encodedKey" -ActivationType Protocol

        Submit-BTNotification -Content $content -UniqueIdentifier "elastic-escalate-$SessionKey"
        Write-AgentLog "Toast 2 (escalation) fired for $SessionKey"
    } catch {
        Write-AgentLog "Toast 2 failed for $SessionKey : $_" -Level ERROR
    }
}

function Step-Agent {
    param([Parameter(Mandatory)][hashtable]$State)

    $now = Get-Date

    # 1. Drain toast click queue and apply effects.
    # @() wrap required: an empty queue returns $null and a single click returns
    # a bare object, and .Count on either throws under StrictMode 3.0 -- which
    # failed every loop iteration before session detection ran.
    $clicks = @(Read-ToastQueue)
    foreach ($evt in $clicks) {
        # Queue entries come from JSON written by toast-callback.ps1; under
        # strict mode we have to guard against any line missing the expected
        # properties (manual edit, bug in the callback, ...).
        $evtProps = $evt.PSObject.Properties.Name
        if ($evtProps -notcontains 'action' -or $evtProps -notcontains 'session_key') {
            Write-AgentLog "Queue entry missing action/session_key, skipping" -Level WARN
            continue
        }
        $key    = [string]$evt.session_key
        $action = [string]$evt.action

        # Compliance-check actions are session-less (key == 'config').
        if ($action -eq 'fix_config' -or $action -eq 'ignore_config') {
            if (-not ($State.ContainsKey('config_check'))) {
                $State.config_check = @{ last_run_at = ''; ignored_hash = '' }
            }
            if ($action -eq 'fix_config') {
                try {
                    $findings = Test-AnsysConfig
                    if ($null -eq $findings) { $findings = @() }
                    if ($findings.Count -eq 0) {
                        Write-AgentLog "fix_config clicked but no findings remain; nothing to do"
                    } else {
                        $batPath = Join-Path $scriptRoot 'fix-ansys-config.bat'
                        [void](New-AnsysConfigFixBat -Findings $findings -OutPath $batPath)
                        Write-AgentLog "Generated $batPath with $($findings.Count) fix(es)"
                        # The bat self-deletes after running successfully. If the
                        # launch itself failed (UAC declined, elevation blocked),
                        # remove the artifact now so it doesn't sit on disk.
                        if (Invoke-AnsysConfigFixLaunch -BatPath $batPath) {
                            Show-ConfigFixLaunchedToast
                        } else {
                            Remove-Item -LiteralPath $batPath -Force -ErrorAction SilentlyContinue
                        }
                    }
                } catch {
                    Write-AgentLog "fix_config handling failed: $_" -Level ERROR
                }
            } else {
                try {
                    $findings = Test-AnsysConfig
                    if ($null -eq $findings) { $findings = @() }
                    $State.config_check.ignored_hash = Get-AnsysConfigFindingsHash -Findings $findings
                    Write-AgentLog "Compliance check ignored by user (hash=$($State.config_check.ignored_hash))"
                } catch {
                    Write-AgentLog "ignore_config handling failed: $_" -Level ERROR
                }
            }
            continue
        }

        if (-not $State.sessions.ContainsKey($key)) {
            Write-AgentLog "Click '$action' for unknown session $key, ignoring" -Level DEBUG
            continue
        }
        $session = $State.sessions[$key]
        switch ($action) {
            'got_it' {
                Write-AgentLog "Got-it clicked for $key"
            }
            'suppress' {
                $session.state = 'SUPPRESSED'
                Write-AgentLog "Suppressed for $key"
            }
            'accept' {
                # User confirmed intentional use. Stop nagging for the rest of this session.
                # Same effect as clicking "Don't bug me this session" on the first toast.
                $session.state          = 'SUPPRESSED'
                $session.next_prompt_at = ''
                Write-AgentLog "Accept clicked for $key, suppressing for rest of session"
            }
            'snooze' {
                # Body-click on the escalation toast. Could be intentional, could be accidental.
                # Re-prompt in 5 minutes rather than the full escalation window.
                $session.next_prompt_at = $now.AddMinutes(5).ToString('o')
                Write-AgentLog "Snoozed (body click) for $key, next prompt at $($session.next_prompt_at)"
            }
            'view_triggers' {
                # Debug button: write an evidence file for this session and open
                # it in the default text editor. Safe even if DebugModeEnabled
                # has since been flipped off -- helper just writes a file.
                try {
                    $evidencePath = Write-DebugEvidenceFile -SessionKey $key -Session $session
                    Start-Process -FilePath $evidencePath -ErrorAction Stop
                    Write-AgentLog "view_triggers opened evidence file: $evidencePath"
                } catch {
                    Write-AgentLog "view_triggers failed for $key : $_" -Level ERROR
                }
            }
            'open_log' {
                # Debug button: open the raw ACL log. .log has no default Windows
                # verb on a stock install, so Start-Process pops the "How do you
                # want to open this?" dialog -- fall back to notepad in that case.
                try {
                    if ($session.log_path -and (Test-Path -LiteralPath $session.log_path)) {
                        try {
                            Start-Process -FilePath $session.log_path -ErrorAction Stop
                        } catch {
                            Start-Process -FilePath 'notepad.exe' -ArgumentList $session.log_path -ErrorAction Stop
                        }
                        Write-AgentLog "open_log launched editor for $($session.log_path)"
                    } else {
                        Write-AgentLog "open_log: log path missing or no longer on disk: $($session.log_path)" -Level WARN
                    }
                } catch {
                    Write-AgentLog "open_log failed for $key : $_" -Level ERROR
                }
            }
            default {
                Write-AgentLog "Unknown click action '$action' for $key" -Level WARN
            }
        }
    }

    # Persist queue effects immediately. If Step-Agent throws later in this
    # iteration, the user's click (suppress, ignore_config, ...) is already
    # durable -- so they don't have to click again on the next loop.
    if ($clicks.Count -gt 0) {
        Save-State -State $State
    }

    # 1b. Manual-trigger sentinel. The debug installer ships a Start-menu
    #     shortcut "Run ANSYS checks now (Debug)" whose target writes this
    #     flag; the loop consumes (deletes) it and re-runs the compliance
    #     check immediately. Compliance otherwise only runs once at startup
    #     (see Invoke-ConfigCheckCycle call below the loop), so this is the
    #     only re-run path. We check the flag unconditionally so a tester
    #     who drops the file on a release install still gets the run.
    if (Test-Path -LiteralPath $script:ManualTriggerFlagPath) {
        Remove-Item -LiteralPath $script:ManualTriggerFlagPath -Force -ErrorAction SilentlyContinue
        Write-AgentLog "Manual trigger sentinel consumed at $script:ManualTriggerFlagPath"
        try {
            # Clear ignored_hash so a previously-dismissed finding set re-toasts.
            # A tester clicking the shortcut almost certainly wants a fresh
            # signal, not silence based on an old dismissal.
            if (-not ($State.ContainsKey('config_check'))) {
                $State.config_check = @{ last_run_at = ''; ignored_hash = '' }
            }
            $State.config_check.ignored_hash = ''
            Invoke-ConfigCheckCycle -State $State -RunMode Agent
            Save-State -State $State
        } catch {
            Write-AgentLog "Manual config-check failed: $_" -Level ERROR
        }
    }

    # 2. Discover currently-active sessions.
    $active = Get-ActiveAnsysclSessions
    $activeKeys = @($active | ForEach-Object { $_.Key })

    # 3. Add new sessions (start at EOF to avoid retroactive toast-bombing).
    foreach ($s in $active) {
        if (-not $State.sessions.ContainsKey($s.Key)) {
            $eofOffset = Get-FileSize -Path $s.LogPath
            $State.sessions[$s.Key] = @{
                log_path             = $s.LogPath
                byte_offset          = [long]$eofOffset
                ansyscl_pid          = $s.AnsysclPid
                first_seen_at        = $now.ToString('o')
                first_elastic_at     = ''
                next_prompt_at       = ''
                state                = 'NEW'
                held_elastic         = @{}   # feature -> ISO8601 checkout time
                recent_elastic_lines = @()   # debug ring; only populated when DebugModeEnabled
            }
            Write-AgentLog "New session $($s.Key) (pid $($s.AnsysclPid)) starting at offset $eofOffset"
        } else {
            # Backfill for sessions persisted by older agent versions.
            if (-not $State.sessions[$s.Key].ContainsKey('held_elastic')) {
                $State.sessions[$s.Key].held_elastic = @{}
            }
            if (-not $State.sessions[$s.Key].ContainsKey('recent_elastic_lines')) {
                $State.sessions[$s.Key].recent_elastic_lines = @()
            }
        }
    }

    # 4. Remove sessions whose ansyscl.exe is gone.
    foreach ($key in @($State.sessions.Keys)) {
        if ($activeKeys -notcontains $key) {
            $State.sessions.Remove($key)
            Write-AgentLog "Session $key ended, removed from state"
        }
    }

    # 5. Per-session: tail log, fire toast 1 on first elastic match, escalate on timer.
    foreach ($s in $active) {
        $session = $State.sessions[$s.Key]
        $result = Read-NewLogContent -Path $s.LogPath -Offset $session.byte_offset
        $session.byte_offset = [long]$result.Offset

        if (-not [string]::IsNullOrEmpty($result.Content)) {
            # Named $elasticMatches (not $matches) so it doesn't shadow the
            # automatic $Matches, which the -match at the end of this block writes.
            $elasticMatches = Find-ElasticCheckouts -Content $result.Content
            foreach ($m in $elasticMatches) {
                Write-AgentLog ("Elastic {0}: feature={1} user={2} session={3}" -f $m.Action, $m.Feature, $m.User, $s.Key)
                if ($m.Action -eq 'CHECKOUT' -or $m.Action -eq 'SPLIT_CHECKOUT') {
                    if (-not $session.held_elastic.ContainsKey($m.Feature)) {
                        $session.held_elastic[$m.Feature] = $now.ToString('o')
                    }
                } elseif ($m.Action -eq 'CHECKIN') {
                    if ($session.held_elastic.ContainsKey($m.Feature)) {
                        $session.held_elastic.Remove($m.Feature)
                    }
                }
            }

            # Debug-only: persist matched + near-miss lines into a per-session
            # FIFO ring so the View-triggers button has something to show, and
            # mirror them into agent.log so testers have a permanent record.
            # Near-miss = any line containing 'elastic' that did NOT match the
            # regex; surfaces both true and false positives in one place.
            if ($script:DebugModeEnabled) {
                foreach ($m in $elasticMatches) {
                    $session.recent_elastic_lines += @{
                        kind    = 'match'
                        ts      = $m.Timestamp
                        feature = $m.Feature
                        user    = $m.User
                        line    = $m.RawLine
                    }
                    Write-AgentLog ("DEBUG elastic match: feature={0} user={1} raw={2}" -f $m.Feature, $m.User, $m.RawLine) -Level DEBUG
                }
                foreach ($line in ($result.Content -split "`r?`n")) {
                    if ($line -match '(?i)elastic' -and $line -notmatch $script:ElasticCheckoutPattern) {
                        $session.recent_elastic_lines += @{
                            kind    = 'near_miss'
                            ts      = ''
                            feature = ''
                            user    = ''
                            line    = $line
                        }
                        Write-AgentLog "DEBUG near-miss (contains 'elastic' but failed regex): $line" -Level DEBUG
                    }
                }
                # Cap to most-recent N. @() wrap required under StrictMode 3.0.
                if (@($session.recent_elastic_lines).Count -gt $script:DebugRecentLinesCap) {
                    $session.recent_elastic_lines = @($session.recent_elastic_lines | Select-Object -Last $script:DebugRecentLinesCap)
                }
            }
        }

        # Threshold gate: only fire toast 1 if an elastic feature has been
        # continuously held for at least $ElasticDetectionThresholdSec.
        # Filters out transient checkouts like rdpara that fire on Workbench
        # open and release within seconds.
        # Oldest currently-held elastic feature, if any. Drives both the
        # threshold gate and the escalation timer / elapsed-time text.
        $oldestTs = $null
        $oldestFeature = $null
        foreach ($f in @($session.held_elastic.Keys)) {
            try { $heldAt = [datetime]::Parse($session.held_elastic[$f]) } catch { continue }
            if ($null -eq $oldestTs -or $heldAt -lt $oldestTs) {
                $oldestTs = $heldAt
                $oldestFeature = $f
            }
        }

        if ($session.state -eq 'NEW' -and $session.held_elastic.Count -gt 0) {
            if ($oldestTs -and ($now - $oldestTs).TotalSeconds -ge $ElasticDetectionThresholdSec) {
                $session.state            = 'NOTIFIED'
                $session.first_elastic_at = $oldestTs.ToString('o')
                $session.next_prompt_at   = $now.AddMinutes($EscalationMinutes).ToString('o')
                Write-AgentLog ("Sustained elastic threshold reached: feature={0} held={1:n0}s" -f $oldestFeature, ($now - $oldestTs).TotalSeconds)
                Show-FirstElasticToast -SessionKey $s.Key -Feature $oldestFeature
            }
        }

        # Escalation timer. Runs only while an elastic feature is still held: once
        # everything is checked back in (the user switched to perpetual but kept
        # ANSYS open) the timer pauses, so we don't keep telling them it costs
        # money. A later elastic checkout re-arms it a full EscalationMinutes
        # after that checkout, so a reminder always means that much continuous use.
        if ($session.state -eq 'NOTIFIED') {
            if ($null -eq $oldestTs) {
                if (-not [string]::IsNullOrEmpty($session.next_prompt_at)) {
                    $session.next_prompt_at = ''
                    Write-AgentLog "No elastic feature held for $($s.Key); escalation paused"
                }
            } elseif ([string]::IsNullOrEmpty($session.next_prompt_at)) {
                $session.next_prompt_at = $oldestTs.AddMinutes($EscalationMinutes).ToString('o')
                Write-AgentLog "Elastic held again for $($s.Key) (feature=$oldestFeature); escalation re-armed for $($session.next_prompt_at)"
            }
        }
        if ($session.state -eq 'NOTIFIED' -and -not [string]::IsNullOrEmpty($session.next_prompt_at)) {
            try {
                $nextPrompt = [datetime]::Parse($session.next_prompt_at)
                if ($now -ge $nextPrompt) {
                    $elapsedMin = [int][Math]::Floor(($now - $oldestTs).TotalMinutes)
                    Show-EscalationToast -SessionKey $s.Key -ElapsedMinutes $elapsedMin
                    # Re-arm: keep nagging hourly until accepted, suppressed, or session ends.
                    $session.next_prompt_at = $now.AddMinutes($EscalationMinutes).ToString('o')
                }
            } catch {
                Write-AgentLog "Bad next_prompt_at '$($session.next_prompt_at)' for $($s.Key): $_" -Level WARN
            }
        }
    }
}

# Main loop.
$state = Load-State
Write-AgentLog ("Loaded {0} session(s) from prior run" -f $state.sessions.Count)

# Startup self-test. Catches "agent is running but missing a prerequisite"
# (e.g. no ANSYS install detected on a workstation where compliance is
# configured) so the user knows about it before they spend an hour
# wondering why nothing toasts.
try {
    $selfTestFindings = Invoke-AgentSelfTest
    if ($selfTestFindings -and $selfTestFindings.Count -gt 0) {
        foreach ($f in $selfTestFindings) {
            Write-AgentLog "Self-test: $($f.key) - $($f.message)" -Level WARN
        }
        Show-AgentSelfTestToast -Findings $selfTestFindings
    } else {
        Write-AgentLog "Self-test: all checks passed" -Level DEBUG
    }
} catch {
    Write-AgentLog "Self-test threw: $_" -Level ERROR
}

# One-shot compliance check at startup. Toasts only if there are findings the
# user hasn't already dismissed via "Ignore".
Invoke-ConfigCheckCycle -State $state -RunMode Agent
Save-State -State $state

while ($true) {
    if (-not (Test-LauncherAlive)) {
        Write-AgentLog "Launcher (wscript.exe pid $script:LauncherPid) has exited; the scheduled task was stopped. Exiting."
        exit 0
    }
    try {
        Step-Agent -State $state
        Save-State -State $state
    } catch {
        Write-AgentLog "Main loop iteration failed: $_" -Level ERROR
    }
    Start-Sleep -Seconds $PollIntervalSeconds
}
