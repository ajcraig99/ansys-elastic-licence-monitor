# Copyright (c) 2026 Arron Craig
# SPDX-License-Identifier: GPL-3.0-or-later
# This file is part of Ansys Elastic Licence Monitor. See LICENSE for terms.
#
# common.ps1 - shared paths, regex, IO helpers. Dot-source from agent.ps1 / test scripts.

$script:AppDataDir     = Join-Path $env:LOCALAPPDATA 'AnsysElasticLicenceMonitor'
$script:LogFilePath    = Join-Path $script:AppDataDir 'agent.log'
$script:StateFilePath  = Join-Path $script:AppDataDir 'state.json'
$script:QueueFilePath  = Join-Path $script:AppDataDir 'toast-queue.jsonl'

# config.json sits next to common.ps1 in both the installed layout (everything
# under %LOCALAPPDATA%\AnsysElasticLicenceMonitor\) and the dev layout (the
# repo root). Resolve the script's own directory so dev runs pick up the repo's
# config.json without needing an install.
$script:CommonScriptDir = if ($PSScriptRoot) { $PSScriptRoot } else { Split-Path -Parent $MyInvocation.MyCommand.Path }
$script:ConfigFilePath  = Join-Path $script:CommonScriptDir 'config.json'

# Defaults are intentionally empty: detection works without any site config
# (the (elastic) tag in the ACL log is universal), but the perpetual-context
# enrichment (the "perpetual is held by other-user" toast variant) requires
# you to point it at your site's FlexLM server and list which features you
# own perpetually. Set those in config.json -- see README.md.
#
# Import-AppConfig at the bottom of this file overwrites these defaults from
# config.json when present.
#
# Phase B (planned): a daily check pulls a remote config.json from a stable
# URL and overwrites the local one in place. Hook point will be agent.ps1's
# main loop; the file format here is the contract.
$script:LicServerHost       = ''
$script:LicServerPort       = 0
$script:PerpetualFeatures   = @()
$script:FeatureDisplayNames = @{}
$script:LmutilPath = $null

# Validated against real ACL logs. See docs/ARCHITECTURE.md "Detection signal".
$script:ElasticCheckoutPattern =
    '^(?<ts>\d{4}/\d{2}/\d{2} \d{2}:\d{2}:\d{2})\s+' +
    '(?<action>CHECKOUT|SPLIT_CHECKOUT|CHECKIN)\s+' +
    '(?<feature>\S+)\s+\(elastic\)\s+' +
    '.*?(?<a>\d+)/(?<b>\d+)/(?<c>\d+)/(?<d>\d+)\s+' +
    '\d+:\d+:[^:]+:(?<user>[^@]+)@(?<host>\S+)'

function Initialize-AppDataDir {
    if (-not (Test-Path $script:AppDataDir)) {
        New-Item -ItemType Directory -Path $script:AppDataDir -Force | Out-Null
    }
}

function Write-AgentLog {
    param(
        [Parameter(Mandatory)][string]$Message,
        [ValidateSet('INFO','WARN','ERROR','DEBUG')][string]$Level = 'INFO'
    )
    Initialize-AppDataDir
    if ((Test-Path $script:LogFilePath) -and ((Get-Item $script:LogFilePath).Length -gt 5MB)) {
        Move-Item $script:LogFilePath "$($script:LogFilePath).1" -Force
    }
    $line = "{0} [{1}] {2}" -f (Get-Date -Format 'yyyy-MM-dd HH:mm:ss'), $Level, $Message
    Add-Content -Path $script:LogFilePath -Value $line
}

function Import-AppConfig {
    # Overrides the hardcoded defaults at the top of this file with values from
    # config.json next to common.ps1, when present. Any missing field falls
    # back to the default. Malformed JSON is logged and ignored (defaults stand).
    if (-not (Test-Path $script:ConfigFilePath)) { return }
    try {
        $cfg = Get-Content -Path $script:ConfigFilePath -Raw -ErrorAction Stop |
            ConvertFrom-Json -ErrorAction Stop
    } catch {
        Write-AgentLog "Failed to parse config.json at $script:ConfigFilePath : $_. Using built-in defaults." -Level WARN
        return
    }

    if ($cfg.PSObject.Properties.Name -contains 'licenseServer' -and $cfg.licenseServer) {
        if ($cfg.licenseServer.host) { $script:LicServerHost = [string]$cfg.licenseServer.host }
        if ($cfg.licenseServer.port) { $script:LicServerPort = [int]$cfg.licenseServer.port }
    }
    if ($cfg.PSObject.Properties.Name -contains 'perpetualFeatures' -and $cfg.perpetualFeatures) {
        $script:PerpetualFeatures = @($cfg.perpetualFeatures | ForEach-Object { [string]$_ })
    }
    if ($cfg.PSObject.Properties.Name -contains 'featureDisplayNames' -and $cfg.featureDisplayNames) {
        $h = @{}
        foreach ($p in $cfg.featureDisplayNames.PSObject.Properties) {
            $h[$p.Name] = [string]$p.Value
        }
        $script:FeatureDisplayNames = $h
    }
    Write-AgentLog "Loaded config.json: server=$($script:LicServerHost):$($script:LicServerPort) perpetualFeatures=$($script:PerpetualFeatures -join ',')" -Level DEBUG
}

function Get-ActiveAnsysclSessions {
    $results = @()
    try {
        $procs = Get-CimInstance Win32_Process -Filter "Name='ansyscl.exe'" -ErrorAction SilentlyContinue
        foreach ($p in $procs) {
            if ([string]::IsNullOrEmpty($p.CommandLine)) { continue }
            if ($p.CommandLine -match '-log\s+"?([^"]+\.log)"?') {
                $logPath = $Matches[1].Trim()
                $filename = Split-Path -Leaf $logPath
                if ($filename -match '^ansyscl\.(?<host>[^.]+)\.(?<pid1>\d+)\.(?<pid2>\d+)\.log$') {
                    $key = "{0}.{1}.{2}" -f $Matches['host'], $Matches['pid1'], $Matches['pid2']
                    $results += [PSCustomObject]@{
                        Key         = $key
                        LogPath     = $logPath
                        AnsysclPid  = [int]$p.ProcessId
                        SessionHost = $Matches['host']
                        Pid1        = $Matches['pid1']
                        Pid2        = $Matches['pid2']
                    }
                }
            }
        }
    } catch {
        Write-AgentLog "Failed to enumerate ansyscl.exe processes: $_" -Level ERROR
    }
    return $results
}

function Read-NewLogContent {
    param(
        [Parameter(Mandatory)][string]$Path,
        [Parameter(Mandatory)][long]$Offset
    )
    if (-not (Test-Path $Path)) {
        return @{ Content = ''; Offset = $Offset }
    }
    try {
        $fs = [System.IO.FileStream]::new(
            $Path,
            [System.IO.FileMode]::Open,
            [System.IO.FileAccess]::Read,
            [System.IO.FileShare]::ReadWrite)
        try {
            if ($Offset -gt $fs.Length) {
                # File rotated or truncated. Restart from beginning.
                $Offset = 0
            }
            [void]$fs.Seek($Offset, [System.IO.SeekOrigin]::Begin)
            $sr = [System.IO.StreamReader]::new($fs)
            try {
                $content = $sr.ReadToEnd()
                $newOffset = $fs.Position
                return @{ Content = $content; Offset = $newOffset }
            } finally { $sr.Dispose() }
        } finally { $fs.Dispose() }
    } catch {
        Write-AgentLog "Failed to read log $Path : $_" -Level WARN
        return @{ Content = ''; Offset = $Offset }
    }
}

function Get-FileSize {
    param([Parameter(Mandatory)][string]$Path)
    try { return (Get-Item -Path $Path -ErrorAction Stop).Length } catch { return 0 }
}

function Find-ElasticCheckouts {
    param([Parameter(Mandatory)][AllowEmptyString()][string]$Content)
    $results = @()
    if ([string]::IsNullOrEmpty($Content)) { return $results }
    foreach ($line in ($Content -split "`r?`n")) {
        if ($line -match $script:ElasticCheckoutPattern) {
            $results += [PSCustomObject]@{
                Timestamp   = $Matches['ts']
                Action      = $Matches['action']
                Feature     = $Matches['feature']
                User        = $Matches['user']
                ElasticHost = $Matches['host']
            }
        }
    }
    return $results
}

function Write-ToastQueueEntry {
    param(
        [Parameter(Mandatory)][string]$SessionKey,
        [Parameter(Mandatory)][string]$Action
    )
    Initialize-AppDataDir
    $entry = [PSCustomObject]@{
        ts          = (Get-Date).ToString('o')
        action      = $Action
        session_key = $SessionKey
    } | ConvertTo-Json -Compress
    Add-Content -Path $script:QueueFilePath -Value $entry -Encoding UTF8
}

function Register-ToastProtocol {
    param([Parameter(Mandatory)][string]$ScriptDir)
    $vbsPath = Join-Path $ScriptDir 'toast-callback.vbs'
    if (-not (Test-Path $vbsPath)) {
        Write-AgentLog "toast-callback.vbs not at $vbsPath ; protocol not registered" -Level WARN
        return
    }
    $regBase = 'HKCU:\Software\Classes\ansyselastic'
    # wscript.exe runs the .vbs without a window; the .vbs spawns powershell hidden.
    # This avoids the brief console flash that powershell.exe -WindowStyle Hidden still produces.
    $cmd = "wscript.exe `"$vbsPath`" `"%1`""

    if (-not (Test-Path $regBase)) { New-Item -Path $regBase -Force | Out-Null }
    New-ItemProperty -Path $regBase -Name '(Default)'    -Value 'URL:Ansys Elastic Licence Monitor Click' -PropertyType String -Force | Out-Null
    New-ItemProperty -Path $regBase -Name 'URL Protocol' -Value ''                                        -PropertyType String -Force | Out-Null

    $cmdKey = "$regBase\shell\open\command"
    if (-not (Test-Path $cmdKey)) { New-Item -Path $cmdKey -Force | Out-Null }
    New-ItemProperty -Path $cmdKey -Name '(Default)' -Value $cmd -PropertyType String -Force | Out-Null

    Write-AgentLog "Registered ansyselastic: protocol -> $cmd"
}

function Unregister-ToastProtocol {
    $regBase = 'HKCU:\Software\Classes\ansyselastic'
    if (Test-Path $regBase) {
        Remove-Item -Path $regBase -Recurse -Force -ErrorAction SilentlyContinue
    }
}

function Read-ToastQueue {
    if (-not (Test-Path $script:QueueFilePath)) { return @() }
    try {
        # Atomic drain: rename then read.
        $tempPath = "$($script:QueueFilePath).processing"
        if (Test-Path $tempPath) { Remove-Item $tempPath -Force -ErrorAction SilentlyContinue }
        Move-Item -Path $script:QueueFilePath -Destination $tempPath -Force -ErrorAction Stop
        $events = @()
        foreach ($line in (Get-Content $tempPath -ErrorAction SilentlyContinue)) {
            if ([string]::IsNullOrWhiteSpace($line)) { continue }
            try { $events += ($line | ConvertFrom-Json) }
            catch { Write-AgentLog "Bad queue line: $line" -Level WARN }
        }
        Remove-Item $tempPath -Force -ErrorAction SilentlyContinue
        return $events
    } catch {
        Write-AgentLog "Failed to read toast queue: $_" -Level WARN
        return @()
    }
}

function Load-State {
    $default = @{ sessions = @{} }
    if (-not (Test-Path $script:StateFilePath)) { return $default }
    try {
        $obj = Get-Content $script:StateFilePath -Raw | ConvertFrom-Json
        $sessions = @{}
        if ($obj.PSObject.Properties.Name -contains 'sessions' -and $obj.sessions) {
            foreach ($prop in $obj.sessions.PSObject.Properties) {
                $v = $prop.Value
                $heldElastic = @{}
                if ($v.PSObject.Properties.Name -contains 'held_elastic' -and $v.held_elastic) {
                    foreach ($hp in $v.held_elastic.PSObject.Properties) {
                        $heldElastic[$hp.Name] = [string]$hp.Value
                    }
                }
                $sessions[$prop.Name] = @{
                    log_path         = [string]$v.log_path
                    byte_offset      = [long]($v.byte_offset)
                    ansyscl_pid      = [int]($v.ansyscl_pid)
                    first_seen_at    = [string]$v.first_seen_at
                    first_elastic_at = [string]$v.first_elastic_at
                    next_prompt_at   = [string]$v.next_prompt_at
                    state            = [string]$v.state
                    held_elastic     = $heldElastic
                }
            }
        }
        return @{ sessions = $sessions }
    } catch {
        Write-AgentLog "Failed to load state, starting fresh: $_" -Level WARN
        return $default
    }
}

function Save-State {
    param([Parameter(Mandatory)][hashtable]$State)
    Initialize-AppDataDir
    $State | ConvertTo-Json -Depth 10 | Set-Content -Path $script:StateFilePath -Encoding UTF8
}

function Test-TcpConnect {
    # Cheap TCP probe with a short timeout. Used to short-circuit lmutil calls
    # when the licence server is unreachable (lmutil itself takes ~30s to time
    # out, which would block the agent loop).
    param(
        [Parameter(Mandatory)][string]$ServerHost,
        [Parameter(Mandatory)][int]$Port,
        [int]$TimeoutMs = 1500
    )
    $client = $null
    try {
        $client = New-Object System.Net.Sockets.TcpClient
        $iar = $client.BeginConnect($ServerHost, $Port, $null, $null)
        $ok = $iar.AsyncWaitHandle.WaitOne($TimeoutMs, $false)
        if ($ok -and $client.Connected) { return $true }
        return $false
    } catch {
        return $false
    } finally {
        if ($client) { $client.Close() }
    }
}

function Get-LmutilPath {
    if ($script:LmutilPath -and (Test-Path $script:LmutilPath)) { return $script:LmutilPath }
    $base = 'C:\Program Files\ANSYS Inc'
    if (-not (Test-Path $base)) { return $null }
    $versionDirs = Get-ChildItem -Path $base -Directory -Filter 'v*' -ErrorAction SilentlyContinue |
        Sort-Object Name -Descending
    foreach ($v in $versionDirs) {
        $candidate = Join-Path $v.FullName 'licensingclient\winx64\lmutil.exe'
        if (Test-Path $candidate) {
            $script:LmutilPath = $candidate
            return $script:LmutilPath
        }
    }
    return $null
}

function Get-FeatureDisplayName {
    param([Parameter(Mandatory)][string]$Feature)
    if ($script:FeatureDisplayNames.ContainsKey($Feature)) {
        return $script:FeatureDisplayNames[$Feature]
    }
    return $Feature
}

function Get-PerpetualContext {
    # Returns context for the toast body when an elastic checkout is for a
    # feature we own perpetually. Three outcomes:
    #   $null        -> not a perpetual feature, or perpetual is free (skip msg)
    #   Unreachable  -> server cannot be reached from this machine
    #   InUseByOthers -> perpetual is held by other user(s), names in .Users
    param([Parameter(Mandatory)][string]$Feature)

    if ($Feature -notin $script:PerpetualFeatures) { return $null }

    if (-not (Test-TcpConnect -ServerHost $script:LicServerHost -Port $script:LicServerPort -TimeoutMs 1500)) {
        return @{ Status = 'Unreachable'; Feature = $Feature }
    }

    $lmutil = Get-LmutilPath
    if (-not $lmutil) {
        Write-AgentLog "lmutil.exe not found; skipping perpetual context for $Feature" -Level WARN
        return $null
    }

    try {
        $licServer = "$($script:LicServerPort)@$($script:LicServerHost)"
        $output = & $lmutil lmstat -f $Feature -c $licServer 2>&1 | Out-String

        if ($output -match 'Total of \d+ licenses? issued;\s+Total of (\d+) licenses? in use') {
            $inUseCount = [int]$Matches[1]
            if ($inUseCount -eq 0) {
                # Perpetual free - per user direction, skip enrichment to avoid
                # the confusing "perpetual is available but you're using elastic" message.
                return $null
            }
            $users = @()
            foreach ($line in ($output -split "`r?`n")) {
                # User lines look like:
                #   "    user.name workstation-host.internal... workstation-host.internal... 43360 (v...)"
                if ($line -match '^\s{4,}(?<user>\S+)\s+(?<host>\S+)\s+\S+\s+\d+') {
                    $users += $Matches['user']
                }
            }
            return @{
                Status  = 'InUseByOthers'
                Feature = $Feature
                Users   = $users
            }
        }
        return $null
    } catch {
        Write-AgentLog "lmutil call failed for $Feature : $_" -Level WARN
        return $null
    }
}

# Apply config.json overrides at dot-source time so every consumer (agent.ps1,
# test-parser.ps1, test-perpetual.ps1) sees the resolved values without each
# one having to call this explicitly.
Import-AppConfig
