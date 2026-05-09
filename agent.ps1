# Copyright (c) 2026 Arron Craig
# SPDX-License-Identifier: GPL-3.0-or-later
# This file is part of Ansys Elastic Licence Monitor. See LICENSE for terms.

[CmdletBinding()]
param(
    [int]$PollIntervalSeconds            = 10,
    [int]$EscalationMinutes              = 60,
    [int]$ElasticDetectionThresholdSec   = 30
)

# Resolve script root robustly when launched via -File.
$scriptRoot = if ($PSScriptRoot) { $PSScriptRoot } else { Split-Path -Parent $MyInvocation.MyCommand.Path }
. (Join-Path $scriptRoot 'common.ps1')

Initialize-AppDataDir
Write-AgentLog "agent.ps1 starting (poll=${PollIntervalSeconds}s escalation=${EscalationMinutes}m threshold=${ElasticDetectionThresholdSec}s pid=$PID)"

try {
    Import-Module BurntToast -ErrorAction Stop
    Write-AgentLog "BurntToast loaded"
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
        $actions = New-BTAction  -Buttons $btnGotIt, $btnSuppress
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

function Show-EscalationToast {
    param([Parameter(Mandatory)][string]$SessionKey)
    try {
        $encodedKey = [System.Uri]::EscapeDataString($SessionKey)
        $btnAccept  = New-BTButton -Content "Accept - keep using elastic" -Arguments "ansyselastic:accept?session=$encodedKey" -ActivationType Protocol

        $headerText = New-BTText -Content "ANSYS Elastic Licensing - action needed"
        $bodyText   = New-BTText -Content "ANSYS elastic licensing has been in use for $EscalationMinutes min. Click Accept to acknowledge, or close ANSYS to stop billing."

        $binding = New-BTBinding -Children $headerText, $bodyText
        $visual  = New-BTVisual  -BindingGeneric $binding
        $actions = New-BTAction  -Buttons $btnAccept
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
    $clicks = Read-ToastQueue
    foreach ($evt in $clicks) {
        $key = [string]$evt.session_key
        if (-not $State.sessions.ContainsKey($key)) {
            Write-AgentLog "Click '$($evt.action)' for unknown session $key, ignoring" -Level DEBUG
            continue
        }
        $session = $State.sessions[$key]
        switch ($evt.action) {
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
            default {
                Write-AgentLog "Unknown click action '$($evt.action)' for $key" -Level WARN
            }
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
                log_path         = $s.LogPath
                byte_offset      = [long]$eofOffset
                ansyscl_pid      = $s.AnsysclPid
                first_seen_at    = $now.ToString('o')
                first_elastic_at = ''
                next_prompt_at   = ''
                state            = 'NEW'
                held_elastic     = @{}   # feature -> ISO8601 checkout time
            }
            Write-AgentLog "New session $($s.Key) (pid $($s.AnsysclPid)) starting at offset $eofOffset"
        } elseif (-not $State.sessions[$s.Key].ContainsKey('held_elastic')) {
            # Backfill for sessions persisted by older agent versions.
            $State.sessions[$s.Key].held_elastic = @{}
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
            $matches = Find-ElasticCheckouts -Content $result.Content
            foreach ($m in $matches) {
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
        }

        # Threshold gate: only fire toast 1 if an elastic feature has been
        # continuously held for at least $ElasticDetectionThresholdSec.
        # Filters out transient checkouts like rdpara that fire on Workbench
        # open and release within seconds.
        if ($session.state -eq 'NEW' -and $session.held_elastic.Count -gt 0) {
            $oldestTs = $null
            $oldestFeature = $null
            foreach ($f in @($session.held_elastic.Keys)) {
                try { $heldAt = [datetime]::Parse($session.held_elastic[$f]) } catch { continue }
                if ($null -eq $oldestTs -or $heldAt -lt $oldestTs) {
                    $oldestTs = $heldAt
                    $oldestFeature = $f
                }
            }
            if ($oldestTs -and ($now - $oldestTs).TotalSeconds -ge $ElasticDetectionThresholdSec) {
                $session.state            = 'NOTIFIED'
                $session.first_elastic_at = $oldestTs.ToString('o')
                $session.next_prompt_at   = $now.AddMinutes($EscalationMinutes).ToString('o')
                Write-AgentLog ("Sustained elastic threshold reached: feature={0} held={1:n0}s" -f $oldestFeature, ($now - $oldestTs).TotalSeconds)
                Show-FirstElasticToast -SessionKey $s.Key -Feature $oldestFeature
            }
        }

        # Escalation timer.
        if ($session.state -eq 'NOTIFIED' -and -not [string]::IsNullOrEmpty($session.next_prompt_at)) {
            try {
                $nextPrompt = [datetime]::Parse($session.next_prompt_at)
                if ($now -ge $nextPrompt) {
                    Show-EscalationToast -SessionKey $s.Key
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

while ($true) {
    try {
        Step-Agent -State $state
        Save-State -State $state
    } catch {
        Write-AgentLog "Main loop iteration failed: $_" -Level ERROR
    }
    Start-Sleep -Seconds $PollIntervalSeconds
}
