# Copyright (c) 2026 Arron Craig
# SPDX-License-Identifier: GPL-3.0-or-later
# This file is part of Ansys Elastic Licence Monitor. See LICENSE for terms.
#
# test-config.ps1 - exercises Merge-AppConfigJson's tolerance of malformed
# central config (H1) and the explicit debug-flag coercion (L4). No ANSYS
# install or licence server needed; runs anywhere PowerShell does.
#
#   powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\test-config.ps1

[CmdletBinding()]
param()

$scriptRoot = if ($PSScriptRoot) { $PSScriptRoot } else { Split-Path -Parent $MyInvocation.MyCommand.Path }
. (Join-Path $scriptRoot 'common.ps1')

$failures = 0
function Assert {
    param([Parameter(Mandatory)][string]$Label, [Parameter(Mandatory)][bool]$Condition)
    if ($Condition) { Write-Host "  OK   $Label" }
    else { Write-Host "  FAIL $Label" -ForegroundColor Red; $script:failures++ }
}

# Reset the vars Merge-AppConfigJson can touch so each case starts from a known
# baseline (common.ps1 dot-sourcing already ran Import-AppConfig once).
function Reset-ConfigVars {
    $script:LicServerHost    = ''
    $script:LicServerPort    = 0
    $script:DebugModeEnabled = $false
}

# --- Scenario 1: a malformed central config must NOT crash the agent (H1) ---
# A non-numeric port used to be a hard [int] cast -> terminating PSInvalidCast ->
# propagated out of the dot-source-time Import-AppConfig and killed every
# workstation pointed at the shared central config.
Write-Host "Scenario 1: malformed central config does not throw (H1)"
Reset-ConfigVars
$threw = $false
try {
    [void](Merge-AppConfigJson -Json '{ "licenseServer": { "host": "good-host", "port": "1055x" } }')
} catch { $threw = $true }
Assert "non-numeric port does not throw"            (-not $threw)
Assert "host still applied despite bad port"        ($script:LicServerHost -eq 'good-host')
Assert "bad port left at prior value (0)"           ($script:LicServerPort -eq 0)

# --- Scenario 2: valid licenseServer applies ---
Write-Host "Scenario 2: valid licenseServer applies"
Reset-ConfigVars
[void](Merge-AppConfigJson -Json '{ "licenseServer": { "host": "h", "port": 1055 } }')
Assert "valid host applied"                         ($script:LicServerHost -eq 'h')
Assert "valid numeric port applied"                 ($script:LicServerPort -eq 1055)

# Port supplied as a JSON string is still parsed (TryParse).
Reset-ConfigVars
[void](Merge-AppConfigJson -Json '{ "licenseServer": { "port": "2055" } }')
Assert "numeric string port parsed"                 ($script:LicServerPort -eq 2055)

# --- Scenario 3: debug.enabled coercion (L4) ---
# [bool] of any non-empty string is $true, so a quoted "false" would silently
# enable debug. Coercion must compare the text.
Write-Host "Scenario 3: debug.enabled coercion (L4)"
Reset-ConfigVars
[void](Merge-AppConfigJson -Json '{ "debug": { "enabled": "false" } }')
Assert "quoted false stays disabled"                ($script:DebugModeEnabled -eq $false)
Reset-ConfigVars
[void](Merge-AppConfigJson -Json '{ "debug": { "enabled": true } }')
Assert "boolean true enables"                       ($script:DebugModeEnabled -eq $true)
Reset-ConfigVars
[void](Merge-AppConfigJson -Json '{ "debug": { "enabled": "true" } }')
Assert "quoted true enables"                        ($script:DebugModeEnabled -eq $true)
Reset-ConfigVars
[void](Merge-AppConfigJson -Json '{ "debug": { "enabled": false } }')
Assert "boolean false stays disabled"               ($script:DebugModeEnabled -eq $false)

# --- Scenario 4: malformed JSON is tolerated ---
Write-Host "Scenario 4: malformed JSON returns false, no throw"
Reset-ConfigVars
$threw = $false
$res = $null
try { $res = Merge-AppConfigJson -Json '{ this is not valid json ' } catch { $threw = $true }
Assert "malformed JSON does not throw"              (-not $threw)
Assert "malformed JSON returns false"               ($res -eq $false)

if ($failures -eq 0) {
    Write-Host ""
    Write-Host "All assertions passed." -ForegroundColor Green
    exit 0
} else {
    Write-Host ""
    Write-Host "$failures assertion(s) failed." -ForegroundColor Red
    exit 1
}
