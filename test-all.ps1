# Copyright (c) 2026 Arron Craig
# SPDX-License-Identifier: GPL-3.0-or-later
# This file is part of Ansys Elastic Licence Monitor. See LICENSE for terms.
#
# test-all.ps1 - aggregator that runs the offline tests in one go.
#
#   powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\test-all.ps1
#
# Skips test-perpetual.ps1 by default (requires a reachable licence server).
# Pass -IncludePerpetual to run it too.

[CmdletBinding()]
param(
    [switch]$IncludePerpetual
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version 3.0

$scriptRoot = if ($PSScriptRoot) { $PSScriptRoot } else { Split-Path -Parent $MyInvocation.MyCommand.Path }

$tests = @(
    @{ Name = 'parser';      File = 'test-parser.ps1' }
    @{ Name = 'configcheck'; File = 'test-configcheck.ps1' }
)
if ($IncludePerpetual) {
    $tests += @{ Name = 'perpetual'; File = 'test-perpetual.ps1' }
}

# Also do a syntax pass over every .ps1 so we catch parse errors that the
# individual tests wouldn't necessarily exercise.
Write-Host "=== Syntax check ==="
$psFiles = Get-ChildItem -Path $scriptRoot -Filter '*.ps1' -File | Where-Object { $_.Name -ne 'test-all.ps1' }
$syntaxErrors = 0
foreach ($f in $psFiles) {
    $errs = $null; $tokens = $null
    [void][System.Management.Automation.Language.Parser]::ParseFile($f.FullName, [ref]$tokens, [ref]$errs)
    if ($errs.Count -eq 0) {
        Write-Host "  OK   $($f.Name)"
    } else {
        $syntaxErrors += $errs.Count
        Write-Host "  FAIL $($f.Name): $($errs.Count) error(s)" -ForegroundColor Red
        foreach ($e in $errs) {
            Write-Host "       $($e.Message) (line $($e.Extent.StartLineNumber))" -ForegroundColor Red
        }
    }
}
Write-Host ""

$results = @()
foreach ($t in $tests) {
    Write-Host "=== $($t.Name) ==="
    $file = Join-Path $scriptRoot $t.File
    if (-not (Test-Path -LiteralPath $file)) {
        Write-Host "  MISSING $file" -ForegroundColor Red
        $results += @{ Name = $t.Name; Pass = $false }
        continue
    }
    # Spawn a fresh PowerShell so each test runs in its own session and can
    # dot-source common.ps1 cleanly without test-A's state leaking into test-B.
    $proc = Start-Process powershell.exe `
        -ArgumentList @('-NoProfile','-ExecutionPolicy','Bypass','-File',$file) `
        -NoNewWindow -PassThru -Wait
    $results += @{ Name = $t.Name; Pass = ($proc.ExitCode -eq 0) }
    Write-Host ""
}

Write-Host "=== Summary ==="
if ($syntaxErrors -gt 0) {
    Write-Host "  Syntax errors: $syntaxErrors" -ForegroundColor Red
}
foreach ($r in $results) {
    if ($r.Pass) {
        Write-Host "  PASS $($r.Name)" -ForegroundColor Green
    } else {
        Write-Host "  FAIL $($r.Name)" -ForegroundColor Red
    }
}

$failed = @($results | Where-Object { -not $_.Pass }).Count + $syntaxErrors
if ($failed -eq 0) {
    Write-Host ""
    Write-Host "All checks passed." -ForegroundColor Green
    exit 0
} else {
    Write-Host ""
    Write-Host "$failed check(s) failed." -ForegroundColor Red
    exit 1
}
