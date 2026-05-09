# Copyright (c) 2026 Arron Craig
# SPDX-License-Identifier: GPL-3.0-or-later
# This file is part of Ansys Elastic Licence Monitor. See LICENSE for terms.

[CmdletBinding()]
param([Parameter(Position=0)][string]$Url)

$scriptRoot = if ($PSScriptRoot) { $PSScriptRoot } else { Split-Path -Parent $MyInvocation.MyCommand.Path }
. (Join-Path $scriptRoot 'common.ps1')

if ([string]::IsNullOrEmpty($Url)) { exit 0 }

# Expected: ansyselastic:<action>?session=<urlencoded-key>
if ($Url -match '^ansyselastic:(?<action>[a-z_]+)\?session=(?<key>.+)$') {
    try {
        $action = $Matches['action']
        $key    = [System.Uri]::UnescapeDataString($Matches['key'])
        Write-ToastQueueEntry -SessionKey $key -Action $action
    } catch {
        Write-AgentLog "toast-callback failed for url '$Url': $_" -Level ERROR
    }
} else {
    Write-AgentLog "toast-callback got unexpected URL: $Url" -Level WARN
}
