# Copyright (c) 2026 Arron Craig
# SPDX-License-Identifier: GPL-3.0-or-later
# This file is part of Ansys Elastic Licence Monitor. See LICENSE for terms.
#
# test-configcheck.ps1 - exercises Test-AnsysConfig + New-AnsysConfigFixBat
# against fixture paths so the check can be validated without an actual ANSYS
# install. Run from the repo root:
#
#   powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\test-configcheck.ps1

[CmdletBinding()]
param()

$scriptRoot = if ($PSScriptRoot) { $PSScriptRoot } else { Split-Path -Parent $MyInvocation.MyCommand.Path }
. (Join-Path $scriptRoot 'common.ps1')

$fixtureRoot   = Join-Path $env:TEMP ("ansys-licence-check-test-{0}" -f ([guid]::NewGuid().ToString('N').Substring(0,8)))
$fixtureIni    = Join-Path $fixtureRoot 'ansyslmd.ini'
$fixtureAppData= Join-Path $fixtureRoot 'AppData\Ansys'
$fixtureV251   = Join-Path $fixtureAppData 'v251'
$fixtureXml    = Join-Path $fixtureV251    'MechanicalLicenseOptions.xml'
$batOut        = Join-Path $fixtureRoot 'fix-ansys-config.bat'

$forbiddenEnv  = 'ANSYSCONFIGCHECK_TEST_FORBIDDEN_VAR'
$failures      = 0

function Assert {
    param([Parameter(Mandatory)][string]$Label, [Parameter(Mandatory)][bool]$Condition)
    if ($Condition) {
        Write-Host "  OK   $Label"
    } else {
        Write-Host "  FAIL $Label" -ForegroundColor Red
        $script:failures++
    }
}

try {
    New-Item -ItemType Directory -Path $fixtureV251 -Force | Out-Null

    # Configure expected values for the duration of the test.
    $script:ExpectedConfig.AnsyslmdServer         = '1055@expected-server'
    $script:ExpectedConfig.ForbiddenUserEnvVars   = @($forbiddenEnv)
    $script:ExpectedConfig.RequiredLicenseOptions = @{ 'Mechanical' = 'Ansys Mechanical Pro' }

    # --- Scenario 1: everything correct -> no findings ---
    Write-Host "Scenario 1: compliant fixture"
    Set-Content -LiteralPath $fixtureIni -Value 'SERVER=1055@expected-server' -Encoding ASCII
    Set-Content -LiteralPath $fixtureXml -Value @'
<Licenses>
  <LicenseInfo Active="1" LicenseName="Ansys Mechanical Pro"/>
</Licenses>
'@ -Encoding UTF8
    [Environment]::SetEnvironmentVariable($forbiddenEnv, $null, 'User')

    $findings = Test-AnsysConfig -AnsyslmdIniPath $fixtureIni -AnsysUserAppData $fixtureAppData
    Assert "compliant fixture yields zero findings" ($findings.Count -eq 0)

    # --- Scenario 2: every check fails -> three findings ---
    Write-Host "Scenario 2: every check fails"
    Set-Content -LiteralPath $fixtureIni -Value 'SERVER=9999@wrong-server' -Encoding ASCII
    Set-Content -LiteralPath $fixtureXml -Value @'
<Licenses>
  <LicenseInfo Active="1" LicenseName="Ansys Mechanical Elastic"/>
</Licenses>
'@ -Encoding UTF8
    [Environment]::SetEnvironmentVariable($forbiddenEnv, 'something', 'User')

    $findings = Test-AnsysConfig -AnsyslmdIniPath $fixtureIni -AnsysUserAppData $fixtureAppData
    Assert "non-compliant fixture yields three findings" ($findings.Count -eq 3)
    # Wrap in @() because Where-Object can return a single hashtable, whose
    # .Count reports the *key count* (4), not the pipeline count (1).
    Assert "server finding has expected key"            (@($findings | Where-Object { $_.key -eq 'server.ansyslmd_ini' }).Count -eq 1)
    Assert "env finding has expected key"               (@($findings | Where-Object { $_.key -eq "env.$forbiddenEnv" }).Count -eq 1)
    Assert "licopt finding has expected key"            (@($findings | Where-Object { $_.key -eq 'licopt.Mechanical.v251' }).Count -eq 1)

    # --- Scenario 3: ignored_hash is stable for the same set, changes on edit ---
    Write-Host "Scenario 3: findings hash stability"
    $hash1 = Get-AnsysConfigFindingsHash -Findings $findings
    $hash2 = Get-AnsysConfigFindingsHash -Findings (Test-AnsysConfig -AnsyslmdIniPath $fixtureIni -AnsysUserAppData $fixtureAppData)
    Assert "hash is stable across calls"                ($hash1 -eq $hash2 -and -not [string]::IsNullOrEmpty($hash1))
    Set-Content -LiteralPath $fixtureIni -Value 'SERVER=8888@some-other-wrong-server' -Encoding ASCII
    $hash3 = Get-AnsysConfigFindingsHash -Findings (Test-AnsysConfig -AnsyslmdIniPath $fixtureIni -AnsysUserAppData $fixtureAppData)
    Assert "hash changes when finding actuals change"   ($hash1 -ne $hash3)

    # --- Scenario 4: bat generation contains expected commands ---
    Write-Host "Scenario 4: bat generation"
    $findings = Test-AnsysConfig -AnsyslmdIniPath $fixtureIni -AnsysUserAppData $fixtureAppData
    [void](New-AnsysConfigFixBat -Findings $findings -OutPath $batOut)
    Assert "bat file created"                           (Test-Path -LiteralPath $batOut)
    $batText = Get-Content -LiteralPath $batOut -Raw
    Assert "bat clears forbidden env var"               ($batText -match "reg delete `"HKCU\\Environment`" /v $forbiddenEnv")
    Assert "bat uses -EncodedCommand for PS payloads"   ($batText -match '-EncodedCommand [A-Za-z0-9+/=]+')

    # Decode each EncodedCommand and assert it contains the expected PS code.
    $encodedMatches = [regex]::Matches($batText, '-EncodedCommand\s+([A-Za-z0-9+/=]+)')
    $decoded = $encodedMatches | ForEach-Object {
        [System.Text.Encoding]::Unicode.GetString([Convert]::FromBase64String($_.Groups[1].Value))
    }
    Assert "decoded payload writes ansyslmd.ini"        (@($decoded | Where-Object { $_ -match 'ansyslmd\.ini' -and $_ -match 'SERVER=' }).Count -ge 1)
    Assert "decoded payload writes Mechanical xml"      (@($decoded | Where-Object { $_ -match 'MechanicalLicenseOptions\.xml' -and $_ -match 'Ansys Mechanical Pro' }).Count -ge 1)

    # M1: a failed elevated write must be reported, not silently "OK". Every PS
    # payload sets ErrorActionPreference=Stop and has an exit-1 failure path.
    $payloadCount = @($decoded).Count
    Assert "two PS payloads generated (ini + xml)"      ($payloadCount -eq 2)
    Assert "every payload sets ErrorActionPreference Stop" (@($decoded | Where-Object { $_ -match "ErrorActionPreference = 'Stop'" }).Count -eq $payloadCount)
    Assert "every payload has an exit 1 failure path"   (@($decoded | Where-Object { $_ -match 'exit 1' }).Count -eq $payloadCount)

    # M4: the elevated XML parse must refuse DTDs (billion-laughs hardening).
    Assert "xml payload prohibits DTD processing"       (@($decoded | Where-Object { $_ -match 'DtdProcessing' -and $_ -match 'Prohibit' }).Count -ge 1)

    # M3: the ini fix must target the same file the check inspected (the fixture),
    # not a hardcoded canonical path the running ANSYS may never read.
    $serverFinding = @($findings | Where-Object { $_.key -eq 'server.ansyslmd_ini' })[0]
    Assert "server finding carries ini_path of inspected file" ($serverFinding.ini_path -eq $fixtureIni)
    Assert "ini payload targets the inspected file"     (@($decoded | Where-Object { $_ -match [regex]::Escape($fixtureIni) }).Count -ge 1)

    # --- Scenario 5: M2 elevated-path / key validation ---
    Write-Host "Scenario 5: M2 path + key validation"
    Assert "rejects '..' traversal"                     (-not (Test-SafeFixTargetPath 'C:\ANSYS Inc\..\..\Windows\System32\x.ini'))
    Assert "rejects relative path"                      (-not (Test-SafeFixTargetPath 'foo\bar.ini'))
    Assert "rejects drive-relative path"                (-not (Test-SafeFixTargetPath 'C:foo.ini'))
    Assert "rejects empty path"                         (-not (Test-SafeFixTargetPath ''))
    Assert "accepts fully-qualified local path"         (Test-SafeFixTargetPath 'C:\Program Files\ANSYS Inc\Shared Files\licensing\ansyslmd.ini')
    Assert "accepts UNC path"                           (Test-SafeFixTargetPath '\\server\share\ansyslmd.ini')

    # A traversal key in requiredLicenseOptions must be skipped, not interpolated
    # into a path that would then be [xml]-loaded and .Save()-d as admin.
    $script:ExpectedConfig.RequiredLicenseOptions = @{ '..\..\Evil' = 'X' }
    $badKeyFindings = Test-AnsysConfig -AnsyslmdIniPath $fixtureIni -AnsysUserAppData $fixtureAppData
    Assert "traversal app-key yields no licopt finding" (@($badKeyFindings | Where-Object { $_.key -like 'licopt.*' }).Count -eq 0)

    # The bat generator must skip a finding whose target path is unsafe, emitting
    # no -EncodedCommand for it.
    $unsafeFinding = @{ key = 'server.ansyslmd_ini'; expected = '1@x'; actual = ''; ini_path = 'C:\x\..\..\Windows\evil.ini' }
    $unsafeBat = Join-Path $fixtureRoot 'unsafe.bat'
    [void](New-AnsysConfigFixBat -Findings @($unsafeFinding) -OutPath $unsafeBat)
    $unsafeText = Get-Content -LiteralPath $unsafeBat -Raw
    Assert "bat skips unsafe ini target"                ($unsafeText -match 'unsafe target path')
    Assert "bat emits no command for unsafe target"     ($unsafeText -notmatch '-EncodedCommand')

}
finally {
    [Environment]::SetEnvironmentVariable($forbiddenEnv, $null, 'User')
    if (Test-Path -LiteralPath $fixtureRoot) {
        Remove-Item -LiteralPath $fixtureRoot -Recurse -Force -ErrorAction SilentlyContinue
    }
}

if ($failures -eq 0) {
    Write-Host ""
    Write-Host "All assertions passed." -ForegroundColor Green
    exit 0
} else {
    Write-Host ""
    Write-Host "$failures assertion(s) failed." -ForegroundColor Red
    exit 1
}
