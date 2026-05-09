# Copyright (c) 2026 Arron Craig
# SPDX-License-Identifier: GPL-3.0-or-later
# This file is part of Ansys Elastic Licence Monitor. See LICENSE for terms.

[CmdletBinding()]
param()

$ErrorActionPreference = 'Stop'
$scriptRoot = if ($PSScriptRoot) { $PSScriptRoot } else { Split-Path -Parent $MyInvocation.MyCommand.Path }
. (Join-Path $scriptRoot 'common.ps1')

Write-Host "lmutil path: $(Get-LmutilPath)"
Write-Host "Lic server : $($script:LicServerHost):$($script:LicServerPort)"
Write-Host "TCP probe  : $(Test-TcpConnect -ServerHost $script:LicServerHost -Port $script:LicServerPort -TimeoutMs 1500)"
Write-Host ""

# Mix of perpetual features (should enrich) and elastic-only ones (should return null).
$features = @('mech_1', 'advanced_meshing', 'dsdxm', 'anshpc', 'disco_level3')
foreach ($f in $features) {
    Write-Host "=== $f ==="
    $ctx = Get-PerpetualContext -Feature $f
    if ($null -eq $ctx) {
        Write-Host "  null (not perpetual, or perpetual is free)"
    } else {
        foreach ($k in $ctx.Keys) {
            $v = $ctx[$k]
            if ($v -is [array]) { $v = $v -join ', ' }
            Write-Host ("  {0,-12} = {1}" -f $k, $v)
        }
    }
    Write-Host ""
}
