# Copyright (c) 2026 Arron Craig
# SPDX-License-Identifier: GPL-3.0-or-later
# This file is part of Ansys Elastic Licence Monitor. See LICENSE for terms.

[CmdletBinding()]
param([Parameter(Position=0)][string]$Url)

Set-StrictMode -Version 3.0

$scriptRoot = if ($PSScriptRoot) { $PSScriptRoot } else { Split-Path -Parent $MyInvocation.MyCommand.Path }
. (Join-Path $scriptRoot 'common.ps1')

if ([string]::IsNullOrEmpty($Url)) { exit 0 }

# Strict allowlist. The agent's switch on $evt.action only handles these six,
# so anything else is silently dropped rather than written to the queue. This
# also keeps the queue from accumulating spam if a stray ansyselastic: URL
# (e.g. handcrafted by another app) hits the handler.
$AllowedActions = @('got_it','suppress','accept','snooze','fix_config','ignore_config')

# Expected: ansyselastic:<action>?session=<urlencoded-key>
# Bound key length so a pathological URL can't blow up the queue file.
if ($Url -match '^ansyselastic:(?<action>[a-z_]{1,32})\?session=(?<key>.{1,256})$') {
    try {
        $action = $Matches['action']
        if ($AllowedActions -notcontains $action) {
            Write-AgentLog "toast-callback dropping unknown action '$action'" -Level WARN
            exit 0
        }
        $key = [System.Uri]::UnescapeDataString($Matches['key'])
        Write-ToastQueueEntry -SessionKey $key -Action $action
    } catch {
        Write-AgentLog "toast-callback failed for url '$Url': $_" -Level ERROR
    }
} else {
    Write-AgentLog "toast-callback got unexpected URL: $Url" -Level WARN
}
