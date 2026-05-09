# Copyright (c) 2026 Arron Craig
# SPDX-License-Identifier: GPL-3.0-or-later
# This file is part of Ansys Elastic Licence Monitor. See LICENSE for terms.

[CmdletBinding()]
param(
    [string]$SampleLog
)

$ErrorActionPreference = 'Stop'
$scriptRoot = if ($PSScriptRoot) { $PSScriptRoot } else { Split-Path -Parent $MyInvocation.MyCommand.Path }
if ([string]::IsNullOrEmpty($SampleLog)) {
    $SampleLog = Join-Path $scriptRoot 'sample-acl-log.log'
}
. (Join-Path $scriptRoot 'common.ps1')

if (-not (Test-Path $SampleLog)) {
    throw "Sample log not found: $SampleLog"
}

$content = Get-Content $SampleLog -Raw
$matches = Find-ElasticCheckouts -Content $content

Write-Host "Sample log: $SampleLog"
Write-Host "Elastic events found: $($matches.Count)"
Write-Host ""

foreach ($m in $matches) {
    "  {0}  {1,-15}  {2,-20}  user={3}" -f $m.Timestamp, $m.Action, $m.Feature, $m.User
}
Write-Host ""

# Sample contains: 2 elastic CHECKOUT/SPLIT_CHECKOUT, 2 elastic CHECKIN.
# 4 perpetual lines should NOT match.
$expected = 4
if ($matches.Count -eq $expected) {
    Write-Host ("PASS: expected {0} elastic events, found {1}" -f $expected, $matches.Count) -ForegroundColor Green
    exit 0
} else {
    Write-Host ("FAIL: expected {0} elastic events, found {1}" -f $expected, $matches.Count) -ForegroundColor Red
    exit 1
}
