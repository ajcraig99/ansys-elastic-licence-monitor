# Copyright (c) 2026 Arron Craig
# SPDX-License-Identifier: GPL-3.0-or-later
# This file is part of Ansys Elastic Licence Monitor. See LICENSE for terms.
#
# common.ps1 - shared paths, regex, IO helpers. Dot-source from agent.ps1 / test scripts.

Set-StrictMode -Version 3.0

# Bump when state.json / config.json schemas gain breaking changes. Old-version
# state files are tolerated (Load-State backfills); old-version configs are
# tolerated (Merge-AppConfigJson ignores unknown fields).
$script:ConfigSchemaVersion = 1
$script:StateSchemaVersion  = 1

$script:AppDataDir     = Join-Path $env:LOCALAPPDATA 'AnsysElasticLicenceMonitor'
$script:LogFilePath    = Join-Path $script:AppDataDir 'agent.log'
$script:StateFilePath  = Join-Path $script:AppDataDir 'state.json'
$script:QueueFilePath  = Join-Path $script:AppDataDir 'toast-queue.jsonl'

# Two-tier config:
#   Tier 1: bundled config.json next to common.ps1 (always present, defaults).
#   Tier 2: central config -- a *local-or-UNC path* read from config-source.txt.
#           HTTPS fetch was removed: non-technical users got confused and the
#           MITM risk on http:// added support load with no real upside.
#
# Tier 2 layers over tier 1 -- any field present in the central config wins.
# If config-source.txt is missing or empty, tier 2 is skipped entirely.
# If the central source can't be reached or parsed, the agent logs WARN and
# uses whatever tier 1 already loaded (so detection always works).
$script:CommonScriptDir       = if ($PSScriptRoot) { $PSScriptRoot } else { Split-Path -Parent $MyInvocation.MyCommand.Path }
$script:ConfigFilePath        = Join-Path $script:CommonScriptDir 'config.json'
$script:ConfigSourceFilePath  = Join-Path $script:CommonScriptDir 'config-source.txt'
$script:VersionFilePath       = Join-Path $script:CommonScriptDir 'VERSION'

# Hard limit on central-config file size. A malicious or accidentally-massive
# JSON would otherwise let ConvertFrom-Json balloon memory.
$script:ConfigSizeLimitBytes = 1MB

# Defaults are intentionally empty: detection works without any site config
# (the (elastic) tag in the ACL log is universal), but the perpetual-context
# enrichment (the "perpetual is held by other-user" toast variant) requires
# you to point it at your site's FlexLM server and list which features you
# own perpetually. Set those in config.json -- see README.md.
#
# Import-AppConfig at the bottom of this file overwrites these defaults.
$script:LicServerHost       = ''
$script:LicServerPort       = 0
$script:PerpetualFeatures   = @()
$script:FeatureDisplayNames = @{}
$script:LmutilPath          = $null

# Detection coupling. These are deliberately overridable from config so a
# future Ansys release that renames the process or relocates the log dir can
# be supported by a config change rather than a code release. See
# Get-AnsysEnvironment for resolution and discovery order.
$script:DetectionProcessName = 'ansyscl.exe'
$script:AclLogDir            = Join-Path $env:LOCALAPPDATA 'Temp\.ansys'

# Compliance check. See Test-AnsysConfig / New-AnsysConfigFixBat below.
# Empty/missing -> check disabled, fully backward compatible.
$script:ExpectedConfig = @{
    AnsyslmdServer         = ''
    ForbiddenUserEnvVars   = @()
    RequiredLicenseOptions = @{}    # AppPrefix -> ExpectedActiveLicenseName
}

# Default discovery roots for the Ansys install. Searched in order by
# Get-AnsysEnvironment; the first one that exists wins. Overridable via
# config.expectedConfig.ansysIncRoots.
$script:AnsysIncRootDefaults = @(
    'C:\Program Files\ANSYS Inc'
    'C:\Program Files (x86)\ANSYS Inc'
)

# Canonical install location for ansyslmd.ini. The compliance check first
# probes this exact path; if missing it falls back to discovering the file
# under every Ansys Inc version directory. Overridable via
# config.expectedConfig.ansyslmdIniPath.
$script:AnsyslmdIniPath  = 'C:\Program Files\ANSYS Inc\Shared Files\licensing\ansyslmd.ini'
$script:AnsysUserAppData = Join-Path $env:APPDATA 'Ansys'   # contains v251, v242, ...

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
        # Keep the most recent N rotations; older ones would otherwise
        # accumulate forever on long-running installs.
        $maxBackups = 3
        for ($i = $maxBackups; $i -ge 1; $i--) {
            $src = "$($script:LogFilePath).$i"
            $dst = "$($script:LogFilePath).$($i+1)"
            if ($i -eq $maxBackups -and (Test-Path -LiteralPath $src)) {
                Remove-Item -LiteralPath $src -Force -ErrorAction SilentlyContinue
            } elseif (Test-Path -LiteralPath $src) {
                Move-Item -LiteralPath $src -Destination $dst -Force -ErrorAction SilentlyContinue
            }
        }
        Move-Item $script:LogFilePath "$($script:LogFilePath).1" -Force -ErrorAction SilentlyContinue
    }
    $line = "{0} [{1}] {2}" -f (Get-Date -Format 'yyyy-MM-dd HH:mm:ss'), $Level, $Message
    Add-Content -Path $script:LogFilePath -Value $line
}

function Get-CentralConfigText {
    # Reads config-source.txt to get the central-config location, then reads
    # that file. Local filesystem only (incl. UNC and mapped drives). HTTPS
    # was removed -- support load from confused users + MITM exposure on http
    # outweighed the benefit when a network share works for every PDV deploy.
    #
    # Returns the raw JSON text on success, $null on any failure (file missing,
    # source field empty, oversized, unreachable). On $null the caller falls
    # back to tier 1 -- detection never breaks because the central source is
    # offline.
    if (-not (Test-Path $script:ConfigSourceFilePath)) { return $null }
    $source = (Get-Content -Path $script:ConfigSourceFilePath -Raw -ErrorAction SilentlyContinue)
    if ($null -eq $source) { return $null }
    $source = $source.Trim()
    if ([string]::IsNullOrWhiteSpace($source)) { return $null }

    if ($source -match '^(?i)https?://') {
        Write-AgentLog "Central config source '$source' is an HTTP(S) URL; only local/UNC paths are supported. Using bundled defaults." -Level WARN
        return $null
    }

    try {
        if (-not (Test-Path -LiteralPath $source)) {
            Write-AgentLog "Central config source '$source' not reachable yet (mapping may not be ready). Using bundled defaults." -Level WARN
            return $null
        }
        $item = Get-Item -LiteralPath $source -ErrorAction Stop
        if ($item.Length -gt $script:ConfigSizeLimitBytes) {
            Write-AgentLog "Central config '$source' is $($item.Length) bytes; over the $($script:ConfigSizeLimitBytes)-byte limit. Using bundled defaults." -Level WARN
            return $null
        }
        return Get-Content -LiteralPath $source -Raw -ErrorAction Stop
    } catch {
        Write-AgentLog "Failed to read central config from '$source' : $_. Using bundled defaults." -Level WARN
        return $null
    }
}

function Merge-AppConfigJson {
    # Parses the supplied JSON text and overlays its fields onto the script-
    # scoped config vars. Each known field is checked individually so a partial
    # central config (e.g. only featureDisplayNames overridden) Just Works.
    # Returns $true if any field was overridden, $false otherwise.
    param([Parameter(Mandatory)][AllowEmptyString()][string]$Json)

    if ([string]::IsNullOrWhiteSpace($Json)) { return $false }
    if ($Json.Length -gt $script:ConfigSizeLimitBytes) {
        Write-AgentLog "Config JSON is $($Json.Length) bytes; over the $($script:ConfigSizeLimitBytes)-byte limit. Skipping." -Level WARN
        return $false
    }
    try {
        $cfg = $Json | ConvertFrom-Json -ErrorAction Stop
    } catch {
        Write-AgentLog "Failed to parse config JSON: $_. Skipping this tier." -Level WARN
        return $false
    }
    if ($null -eq $cfg -or $cfg -isnot [PSCustomObject]) { return $false }

    $cfgProps = $cfg.PSObject.Properties.Name
    $changed = $false
    if ($cfgProps -contains 'licenseServer' -and $cfg.licenseServer) {
        $lsProps = $cfg.licenseServer.PSObject.Properties.Name
        if ($lsProps -contains 'host' -and $cfg.licenseServer.host) {
            $script:LicServerHost = [string]$cfg.licenseServer.host; $changed = $true
        }
        if ($lsProps -contains 'port' -and $cfg.licenseServer.port) {
            $script:LicServerPort = [int]$cfg.licenseServer.port;   $changed = $true
        }
    }
    if ($cfgProps -contains 'perpetualFeatures' -and $cfg.perpetualFeatures) {
        $script:PerpetualFeatures = @($cfg.perpetualFeatures | ForEach-Object { [string]$_ })
        $changed = $true
    }
    if ($cfgProps -contains 'featureDisplayNames' -and $cfg.featureDisplayNames) {
        $h = @{}
        foreach ($p in $cfg.featureDisplayNames.PSObject.Properties) {
            $h[$p.Name] = [string]$p.Value
        }
        $script:FeatureDisplayNames = $h
        $changed = $true
    }
    # Detection coupling: deliberately overridable so an Ansys release that
    # renames the process or relocates the log dir is a config edit, not a
    # code release.
    if ($cfgProps -contains 'detection' -and $cfg.detection) {
        $dProps = $cfg.detection.PSObject.Properties.Name
        if ($dProps -contains 'processName' -and $cfg.detection.processName) {
            $script:DetectionProcessName = [string]$cfg.detection.processName; $changed = $true
        }
        if ($dProps -contains 'aclLogDir' -and $cfg.detection.aclLogDir) {
            $script:AclLogDir = [string]$cfg.detection.aclLogDir; $changed = $true
        }
    }
    if ($cfgProps -contains 'expectedConfig' -and $cfg.expectedConfig) {
        $ec = $cfg.expectedConfig
        $ecProps = $ec.PSObject.Properties.Name
        if ($ecProps -contains 'ansyslmdServer' -and $ec.ansyslmdServer) {
            $script:ExpectedConfig.AnsyslmdServer = [string]$ec.ansyslmdServer
            $changed = $true
        }
        if ($ecProps -contains 'ansyslmdIniPath' -and $ec.ansyslmdIniPath) {
            $script:AnsyslmdIniPath = [string]$ec.ansyslmdIniPath
            $changed = $true
        }
        if ($ecProps -contains 'ansysIncRoots' -and $ec.ansysIncRoots) {
            $script:AnsysIncRootDefaults = @($ec.ansysIncRoots | ForEach-Object { [string]$_ })
            $changed = $true
        }
        if ($ecProps -contains 'forbiddenUserEnvVars' -and $ec.forbiddenUserEnvVars) {
            $script:ExpectedConfig.ForbiddenUserEnvVars = @($ec.forbiddenUserEnvVars | ForEach-Object { [string]$_ })
            $changed = $true
        }
        if ($ecProps -contains 'requiredLicenseOptions' -and $ec.requiredLicenseOptions) {
            $h = @{}
            foreach ($p in $ec.requiredLicenseOptions.PSObject.Properties) {
                $h[$p.Name] = [string]$p.Value
            }
            $script:ExpectedConfig.RequiredLicenseOptions = $h
            $changed = $true
        }
    }
    return $changed
}

function Import-AppConfig {
    # Two-tier load:
    #   Tier 1: bundled config.json (defaults, always tried first)
    #   Tier 2: central config from config-source.txt (overrides tier 1 if set
    #           and reachable)
    # On any failure the agent silently falls back to whatever previous tier
    # already populated -- so a broken central source never breaks detection.
    $tier1Loaded = $false
    if (Test-Path $script:ConfigFilePath) {
        try {
            $tier1Json = Get-Content -Path $script:ConfigFilePath -Raw -ErrorAction Stop
            $tier1Loaded = Merge-AppConfigJson -Json $tier1Json
        } catch {
            Write-AgentLog "Failed to parse bundled config.json at $script:ConfigFilePath : $_. Using built-in defaults." -Level WARN
        }
    }

    $tier2Json = Get-CentralConfigText
    $tier2Loaded = $false
    if ($null -ne $tier2Json) {
        $tier2Loaded = Merge-AppConfigJson -Json $tier2Json
    }

    Write-AgentLog ("Config load: tier1(config.json)={0} tier2(central)={1} server={2}:{3} perpetualFeatures={4}" -f `
        $tier1Loaded, $tier2Loaded, $script:LicServerHost, $script:LicServerPort, ($script:PerpetualFeatures -join ',')) -Level DEBUG
}

function Get-ActiveAnsysclSessions {
    # Process name is overridable via config.detection.processName -- if a
    # future Ansys release renames ansyscl.exe, you update config not code.
    $results = @()
    $procName = $script:DetectionProcessName
    if ([string]::IsNullOrWhiteSpace($procName)) {
        Write-AgentLog "DetectionProcessName is empty; cannot enumerate sessions" -Level ERROR
        return $results
    }
    # Escape single quotes in the filter (Win32_Process filter uses CIM query
    # syntax: single-quoted string literal). The default value has no quotes,
    # but a config override might.
    $procFilter = "Name='" + ($procName -replace "'", "''") + "'"
    try {
        $procs = Get-CimInstance Win32_Process -Filter $procFilter -ErrorAction SilentlyContinue
        foreach ($p in $procs) {
            if ([string]::IsNullOrEmpty($p.CommandLine)) { continue }
            # Case-insensitive: a future Ansys build that uppercases -LOG should
            # still match.
            if ($p.CommandLine -match '(?i)-log\s+"?([^"]+\.log)"?') {
                $logPath  = $Matches[1].Trim()
                $filename = Split-Path -Leaf $logPath
                # Require the canonical ansyscl.<host>.<pid1>.<pid2>.log layout.
                # Anything else is either a corrupted command line or a path
                # that doesn't belong to us; ignore it.
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
        Write-AgentLog "Failed to enumerate '$procName' processes: $_" -Level ERROR
    }
    return $results
}

function Get-AnsysVersionDirs {
    # Numeric-aware enumerator for vNNN-style Ansys version directories.
    # Returns an array of directory objects sorted by numeric version
    # descending -- i.e. v261 before v251 before v100 before v99. Plain
    # alphabetic sort would put v99 above v100; that bug detonates the day
    # Ansys ships v100 (low-2030s on current cadence).
    param(
        [Parameter(Mandatory)][string]$Root
    )
    if ([string]::IsNullOrWhiteSpace($Root) -or -not (Test-Path -LiteralPath $Root)) {
        return @()
    }
    try {
        $candidates = Get-ChildItem -LiteralPath $Root -Directory -Filter 'v*' -ErrorAction SilentlyContinue
    } catch {
        return @()
    }
    $withNum = @()
    foreach ($d in $candidates) {
        if ($d.Name -match '^v(?<num>\d+)') {
            $withNum += [PSCustomObject]@{
                Dir = $d
                Num = [int]$Matches['num']
            }
        }
    }
    return @($withNum | Sort-Object Num -Descending | ForEach-Object { $_.Dir })
}

function Get-AnsysEnvironment {
    # Discovery of every Ansys-related path the agent needs. Centralised here
    # so a future Ansys release that relocates anything is one function to
    # update, not eight scattered Test-Paths.
    #
    # Returns a hashtable with:
    #   AnsysIncRoot     - the first existing root from $AnsysIncRootDefaults, or ''
    #   VersionDirs      - all vNNN directories under AnsysIncRoot, numeric desc
    #   LatestVersion    - top entry of VersionDirs, or $null
    #   LmutilPath       - first usable lmutil.exe across all VersionDirs, or $null
    #   AnsyslmdIniPath  - canonical $script:AnsyslmdIniPath if it exists, else
    #                      first discovered <ver>\Shared Files\Licensing\ansyslmd.ini, else ''
    #   AclLogDir        - $script:AclLogDir (no probing -- ANSYS creates it lazily)
    #   UserAppDataRoot  - $script:AnsysUserAppData (per-user)
    $env = @{
        AnsysIncRoot    = ''
        VersionDirs     = @()
        LatestVersion   = $null
        LmutilPath      = $null
        AnsyslmdIniPath = ''
        AclLogDir       = $script:AclLogDir
        UserAppDataRoot = $script:AnsysUserAppData
    }
    foreach ($root in $script:AnsysIncRootDefaults) {
        if (-not [string]::IsNullOrWhiteSpace($root) -and (Test-Path -LiteralPath $root)) {
            $env.AnsysIncRoot = $root
            break
        }
    }
    if ($env.AnsysIncRoot) {
        # @() forces array semantics so .Count works under StrictMode even
        # with a single result (PowerShell would otherwise unwrap to scalar).
        $env.VersionDirs = @(Get-AnsysVersionDirs -Root $env.AnsysIncRoot)
        if ($env.VersionDirs.Count -gt 0) {
            $env.LatestVersion = $env.VersionDirs[0]
        }
        foreach ($v in $env.VersionDirs) {
            $candidate = Join-Path $v.FullName 'licensingclient\winx64\lmutil.exe'
            if (Test-Path -LiteralPath $candidate) {
                $env.LmutilPath = $candidate
                break
            }
        }
    }
    # ansyslmd.ini: prefer the canonical override (set in config or the default
    # Shared Files location), else discover per-version. Discovery covers the
    # case where Ansys moves the shared-licensing directory under a vNNN root.
    if ($script:AnsyslmdIniPath -and (Test-Path -LiteralPath $script:AnsyslmdIniPath)) {
        $env.AnsyslmdIniPath = $script:AnsyslmdIniPath
    } else {
        foreach ($v in @($env.VersionDirs)) {
            $candidate = Join-Path $v.FullName 'Shared Files\Licensing\ansyslmd.ini'
            if (Test-Path -LiteralPath $candidate) {
                $env.AnsyslmdIniPath = $candidate
                break
            }
        }
    }
    return $env
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
    # State schema is forward-tolerant: missing fields get sensible defaults,
    # unknown extra fields are ignored. A truncated or malformed file is
    # discarded entirely (logged once, agent continues with a fresh state) --
    # which is recoverable because state is just session-scoped, not data.
    $default = @{
        schema_version = $script:StateSchemaVersion
        sessions       = @{}
        config_check   = @{ last_run_at = ''; ignored_hash = '' }
    }
    if (-not (Test-Path $script:StateFilePath)) { return $default }
    try {
        $obj = Get-Content $script:StateFilePath -Raw | ConvertFrom-Json
        $sessions = @{}
        $objProps = $obj.PSObject.Properties.Name
        if ($objProps -contains 'sessions' -and $obj.sessions) {
            foreach ($prop in $obj.sessions.PSObject.Properties) {
                $v = $prop.Value
                $vProps = $v.PSObject.Properties.Name
                $heldElastic = @{}
                if ($vProps -contains 'held_elastic' -and $v.held_elastic) {
                    foreach ($hp in $v.held_elastic.PSObject.Properties) {
                        $heldElastic[$hp.Name] = [string]$hp.Value
                    }
                }
                # Scrub bad next_prompt_at -- a malformed timestamp would
                # otherwise trip [datetime]::Parse every loop iteration and
                # spam WARN until the session ends.
                $nextPrompt = ''
                if ($vProps -contains 'next_prompt_at' -and $v.next_prompt_at) {
                    $candidate = [string]$v.next_prompt_at
                    try { [void][datetime]::Parse($candidate); $nextPrompt = $candidate } catch {}
                }
                $sessions[$prop.Name] = @{
                    log_path         = if ($vProps -contains 'log_path')         { [string]$v.log_path } else { '' }
                    byte_offset      = if ($vProps -contains 'byte_offset')      { [long]$v.byte_offset } else { 0 }
                    ansyscl_pid      = if ($vProps -contains 'ansyscl_pid')      { [int]$v.ansyscl_pid } else { 0 }
                    first_seen_at    = if ($vProps -contains 'first_seen_at')    { [string]$v.first_seen_at } else { '' }
                    first_elastic_at = if ($vProps -contains 'first_elastic_at') { [string]$v.first_elastic_at } else { '' }
                    next_prompt_at   = $nextPrompt
                    state            = if ($vProps -contains 'state')            { [string]$v.state } else { 'NEW' }
                    held_elastic     = $heldElastic
                }
            }
        }
        $configCheck = @{ last_run_at = ''; ignored_hash = '' }
        if ($objProps -contains 'config_check' -and $obj.config_check) {
            $ccProps = $obj.config_check.PSObject.Properties.Name
            if ($ccProps -contains 'last_run_at') {
                $configCheck.last_run_at = [string]$obj.config_check.last_run_at
            }
            if ($ccProps -contains 'ignored_hash') {
                $configCheck.ignored_hash = [string]$obj.config_check.ignored_hash
            }
        }
        return @{
            schema_version = $script:StateSchemaVersion
            sessions       = $sessions
            config_check   = $configCheck
        }
    } catch {
        Write-AgentLog "Failed to load state, starting fresh: $_" -Level WARN
        return $default
    }
}

function Save-State {
    # Atomic: write a .tmp then rename over the real file. Kill the agent
    # mid-write on a non-atomic Set-Content and the next Load-State trips
    # on truncated JSON -- and we lose every session's offset, suppressed
    # state, and configCheckIgnoredHash.
    param([Parameter(Mandatory)][hashtable]$State)
    Initialize-AppDataDir
    if (-not $State.ContainsKey('schema_version')) {
        $State.schema_version = $script:StateSchemaVersion
    }
    $tmp = "$($script:StateFilePath).tmp"
    try {
        $State | ConvertTo-Json -Depth 10 | Set-Content -Path $tmp -Encoding UTF8 -ErrorAction Stop
        Move-Item -LiteralPath $tmp -Destination $script:StateFilePath -Force -ErrorAction Stop
    } catch {
        Write-AgentLog "Failed to atomically write state: $_" -Level ERROR
        if (Test-Path -LiteralPath $tmp) {
            Remove-Item -LiteralPath $tmp -Force -ErrorAction SilentlyContinue
        }
    }
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
    # Cache only successful resolutions. A previous version cached $null too,
    # which meant an Ansys install added *after* agent startup stayed invisible
    # until the next restart. With the cache only holding hits, every lookup
    # re-probes when previously empty.
    if ($script:LmutilPath -and (Test-Path -LiteralPath $script:LmutilPath)) { return $script:LmutilPath }
    $envInfo = Get-AnsysEnvironment
    if ($envInfo.LmutilPath) {
        $script:LmutilPath = $envInfo.LmutilPath
        return $script:LmutilPath
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

function Invoke-LmutilWithTimeout {
    # Wraps a single lmutil invocation in a hard timeout, because the bare
    # TCP probe doesn't catch "reachable-but-hung server" (in which case
    # lmutil blocks for ~30s, freezing the entire agent loop). We run lmutil
    # in a background job and either wait for it or kill it.
    param(
        [Parameter(Mandatory)][string]$LmutilPath,
        [Parameter(Mandatory)][string[]]$ArgList,
        [int]$TimeoutSeconds = 5
    )
    $job = $null
    try {
        $job = Start-Job -ScriptBlock {
            param($exe, $args)
            & $exe @args 2>&1 | Out-String
        } -ArgumentList $LmutilPath, $ArgList
        if (Wait-Job -Job $job -Timeout $TimeoutSeconds) {
            return ([string](Receive-Job -Job $job -ErrorAction SilentlyContinue))
        }
        Write-AgentLog "lmutil timed out after ${TimeoutSeconds}s (args: $($ArgList -join ' '))" -Level WARN
        return ''
    } catch {
        Write-AgentLog "lmutil job failed: $_" -Level WARN
        return ''
    } finally {
        if ($job) {
            try { Remove-Job -Job $job -Force -ErrorAction SilentlyContinue } catch {}
        }
    }
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
        $output = Invoke-LmutilWithTimeout -LmutilPath $lmutil -ArgList @('lmstat','-f',$Feature,'-c',$licServer) -TimeoutSeconds 5
        if ([string]::IsNullOrWhiteSpace($output)) { return $null }

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

function Get-ExpectedAnsysServer {
    # The expected ansyslmd.ini SERVER= value. Prefer an explicit override in
    # expectedConfig.ansyslmdServer; otherwise derive from licenseServer.
    # Returns '' if neither is set (which means the server check is skipped).
    if ($script:ExpectedConfig.AnsyslmdServer) { return $script:ExpectedConfig.AnsyslmdServer }
    if ($script:LicServerHost -and $script:LicServerPort) {
        return "$($script:LicServerPort)@$($script:LicServerHost)"
    }
    return ''
}

function Test-AnsysConfig {
    # Compares the live workstation config against $script:ExpectedConfig.
    # Returns an array of findings; empty means compliant. Each finding is a
    # hashtable with: key, expected, actual, fixDescription.
    #
    # Parameters exist so tests can point this at fixture paths.
    param(
        [string]$AnsyslmdIniPath  = $script:AnsyslmdIniPath,
        [string]$AnsysUserAppData = $script:AnsysUserAppData
    )
    $findings = @()

    # --- ansyslmd.ini ---
    $expectedServer = Get-ExpectedAnsysServer
    if ($expectedServer) {
        $actualServer = ''
        if (Test-Path -LiteralPath $AnsyslmdIniPath) {
            try {
                foreach ($line in (Get-Content -LiteralPath $AnsyslmdIniPath -ErrorAction Stop)) {
                    if ($line -match '^\s*SERVER\s*=\s*(.+?)\s*$') {
                        $actualServer = $Matches[1]
                        break
                    }
                }
            } catch {
                Write-AgentLog "Failed to read $AnsyslmdIniPath : $_" -Level WARN
            }
        }
        if ($actualServer -ne $expectedServer) {
            $findings += @{
                key             = 'server.ansyslmd_ini'
                expected        = $expectedServer
                actual          = $actualServer
                fixDescription  = "Set $AnsyslmdIniPath to 'SERVER=$expectedServer'"
            }
        }
    }

    # --- forbidden user env vars ---
    foreach ($name in @($script:ExpectedConfig.ForbiddenUserEnvVars)) {
        if ([string]::IsNullOrWhiteSpace($name)) { continue }
        $val = [Environment]::GetEnvironmentVariable($name, 'User')
        if (-not [string]::IsNullOrEmpty($val)) {
            $findings += @{
                key             = "env.$name"
                expected        = '<unset>'
                actual          = $val
                fixDescription  = "Delete user environment variable $name"
            }
        }
    }

    # --- per-app *LicenseOptions.xml across all installed Ansys versions ---
    # Numeric-aware version sort so v100 sorts above v99 in the future. Order
    # doesn't change which versions are checked (we check every one), only
    # the order findings appear in -- but for predictability we use the same
    # helper as the rest of the codebase.
    $reqLO = $script:ExpectedConfig.RequiredLicenseOptions
    if ($reqLO -and $reqLO.Count -gt 0 -and (Test-Path -LiteralPath $AnsysUserAppData)) {
        $versionDirs = @(Get-AnsysVersionDirs -Root $AnsysUserAppData)
        foreach ($v in $versionDirs) {
            foreach ($app in $reqLO.Keys) {
                $expectedName = [string]$reqLO[$app]
                if (-not $expectedName) { continue }
                $xmlPath = Join-Path $v.FullName "$($app)LicenseOptions.xml"
                if (-not (Test-Path -LiteralPath $xmlPath)) { continue }   # app not installed for this version
                $actualName = ''
                try {
                    [xml]$doc = Get-Content -LiteralPath $xmlPath -Raw -ErrorAction Stop
                    $node = $doc.SelectSingleNode("//LicenseInfo[@Active='1']")
                    if ($node) { $actualName = [string]$node.LicenseName }
                } catch {
                    Write-AgentLog "Failed to parse $xmlPath : $_" -Level WARN
                }
                if ($actualName -ne $expectedName) {
                    $findings += @{
                        key             = "licopt.$app.$($v.Name)"
                        expected        = $expectedName
                        actual          = $actualName
                        fixDescription  = "Set $xmlPath active licence to '$expectedName'"
                        xml_path        = $xmlPath
                        app_prefix      = $app
                    }
                }
            }
        }
    }

    return ,$findings
}

function Get-AnsysConfigFindingsHash {
    # Stable SHA1 over the {key,expected,actual} triplets so that a user's
    # "Ignore" choice silences exactly this set of findings, but re-toasts
    # if either the actual or the expected side changes.
    param([Parameter(Mandatory)][AllowEmptyCollection()][array]$Findings)
    if ($Findings.Count -eq 0) { return '' }
    $sorted = $Findings | Sort-Object { $_.key }
    $sb = New-Object System.Text.StringBuilder
    foreach ($f in $sorted) {
        [void]$sb.AppendLine("$($f.key)|$($f.expected)|$($f.actual)")
    }
    $bytes = [System.Text.Encoding]::UTF8.GetBytes($sb.ToString())
    $sha = [System.Security.Cryptography.SHA1]::Create()
    try {
        $hash = $sha.ComputeHash($bytes)
        return -join ($hash | ForEach-Object { $_.ToString('x2') })
    } finally { $sha.Dispose() }
}

function New-AnsysConfigFixBat {
    # Generates a self-contained .bat the user can run as admin to remediate
    # everything in $Findings. Each PowerShell fix is passed via -EncodedCommand
    # (Base64 UTF-16LE) so we sidestep cmd<->PowerShell quoting entirely.
    #
    # The PS payloads are idempotent:
    #   - ansyslmd.ini: parsed line-by-line, only the SERVER= line is rewritten;
    #     DAEMON= / HOST= / comments are preserved. If no SERVER= line exists,
    #     one is appended. Original copied to *.bak-<timestamp> first.
    #   - env vars: reg delete is intrinsically idempotent.
    #   - <App>LicenseOptions.xml: parsed as XML, the active LicenseInfo's
    #     LicenseName attribute is set in place. Other nodes/attributes are
    #     preserved. Original copied to *.bak-<timestamp> first.
    #
    # The .bat self-deletes at the end so it doesn't sit on disk indefinitely.
    param(
        [Parameter(Mandatory)][AllowEmptyCollection()][array]$Findings,
        [Parameter(Mandatory)][string]$OutPath
    )

    # PS-literal-escape: wrap in single quotes, double any embedded singles.
    function Escape-PsSQ([string]$s) {
        if ($null -eq $s) { return "''" }
        return "'" + $s.Replace("'", "''") + "'"
    }

    function ConvertTo-EncodedPsCommand([string]$Code) {
        # PowerShell's -EncodedCommand expects UTF-16LE bytes, then Base64.
        $bytes = [System.Text.Encoding]::Unicode.GetBytes($Code)
        return [Convert]::ToBase64String($bytes)
    }

    $ts = (Get-Date).ToString('yyyyMMdd-HHmmss')

    $lines = @()
    $lines += '@echo off'
    $lines += 'setlocal'
    $lines += 'echo Ansys Elastic Licence Monitor - configuration repair'
    $lines += "echo Applying $($Findings.Count) fix(es)..."
    $lines += 'echo Originals are copied to *.bak-<timestamp> next to each modified file.'
    $lines += 'echo.'
    $lines += 'set FAILED=0'
    $lines += ''

    foreach ($f in $Findings) {
        switch -Wildcard ($f.key) {
            'server.ansyslmd_ini' {
                $iniPath = $script:AnsyslmdIniPath
                $expServer = [string]$f.expected
                # In-place SERVER= rewrite, preserving other lines. Idempotent:
                # running twice yields the same end state.
                $cmd = @"
`$ini = $(Escape-PsSQ $iniPath)
`$exp = $(Escape-PsSQ $expServer)
`$bak = `$ini + '.bak-$ts'
if (Test-Path -LiteralPath `$ini) {
    Copy-Item -LiteralPath `$ini -Destination `$bak -Force -ErrorAction SilentlyContinue
    `$lines = @(Get-Content -LiteralPath `$ini -ErrorAction Stop)
    `$replaced = `$false
    `$out = foreach (`$ln in `$lines) {
        if (`$ln -match '^\s*SERVER\s*=') { `$replaced = `$true; "SERVER=`$exp" } else { `$ln }
    }
    if (-not `$replaced) { `$out += "SERVER=`$exp" }
    Set-Content -LiteralPath `$ini -Value `$out -Encoding ASCII
} else {
    `$parent = Split-Path -Parent `$ini
    if (`$parent -and -not (Test-Path -LiteralPath `$parent)) { New-Item -ItemType Directory -Path `$parent -Force | Out-Null }
    Set-Content -LiteralPath `$ini -Value ("SERVER=`$exp") -Encoding ASCII
}
"@
                $enc = ConvertTo-EncodedPsCommand $cmd
                $lines += "REM Fix: $($f.key)"
                $lines += "powershell.exe -NoProfile -ExecutionPolicy Bypass -EncodedCommand $enc"
                $lines += 'if errorlevel 1 ( echo  FAILED: ansyslmd.ini write && set FAILED=1 ) else echo  OK: ansyslmd.ini'
                $lines += ''
                continue
            }
            'env.*' {
                $name = $f.key.Substring(4)
                $lines += "REM Fix: $($f.key)"
                $lines += "reg delete `"HKCU\Environment`" /v $name /f >nul 2>&1"
                $lines += "if errorlevel 1 ( echo  FAILED: delete env $name && set FAILED=1 ) else echo  OK: cleared env $name"
                $lines += ''
                continue
            }
            'licopt.*' {
                $xmlPath = [string]$f.xml_path
                $expName = [string]$f.expected
                # Parse-and-edit so non-LicenseInfo nodes/attributes are
                # preserved. If no active LicenseInfo exists, one is created.
                $cmd = @"
`$path = $(Escape-PsSQ $xmlPath)
`$exp  = $(Escape-PsSQ $expName)
`$bak  = `$path + '.bak-$ts'
`$parent = Split-Path -Parent `$path
if (`$parent -and -not (Test-Path -LiteralPath `$parent)) { New-Item -ItemType Directory -Path `$parent -Force | Out-Null }
if (Test-Path -LiteralPath `$path) {
    Copy-Item -LiteralPath `$path -Destination `$bak -Force -ErrorAction SilentlyContinue
    try {
        [xml]`$doc = Get-Content -LiteralPath `$path -Raw -ErrorAction Stop
    } catch {
        `$doc = New-Object System.Xml.XmlDocument
        `$null = `$doc.AppendChild(`$doc.CreateElement('Licenses'))
    }
} else {
    `$doc = New-Object System.Xml.XmlDocument
    `$null = `$doc.AppendChild(`$doc.CreateElement('Licenses'))
}
if (-not `$doc.DocumentElement) { `$null = `$doc.AppendChild(`$doc.CreateElement('Licenses')) }
`$active = `$doc.SelectSingleNode("//LicenseInfo[@Active='1']")
if (-not `$active) {
    `$active = `$doc.CreateElement('LicenseInfo')
    `$active.SetAttribute('Active','1')
    `$null = `$doc.DocumentElement.AppendChild(`$active)
}
`$active.SetAttribute('LicenseName', `$exp)
`$doc.Save(`$path)
"@
                $enc = ConvertTo-EncodedPsCommand $cmd
                $lines += "REM Fix: $($f.key)"
                $lines += "powershell.exe -NoProfile -ExecutionPolicy Bypass -EncodedCommand $enc"
                $lines += "if errorlevel 1 ( echo  FAILED: $($f.app_prefix) XML && set FAILED=1 ) else echo  OK: $($f.app_prefix) XML"
                $lines += ''
                continue
            }
            default {
                $lines += "REM Skipping unknown finding key: $($f.key)"
            }
        }
    }

    $lines += 'echo.'
    $lines += 'if "%FAILED%"=="0" ( echo Done. Close and re-open ANSYS for changes to take effect. ) else ( echo Some fixes failed. See messages above. )'
    $lines += 'pause'
    $lines += 'endlocal'
    # Self-delete so the bat does not linger on disk. cmd.exe holds the
    # file open while it runs the current command, so this last line is
    # what removes the artifact -- we use `start "" /b cmd /c del` to detach
    # the delete from the current cmd's open handle.
    $lines += 'start "" /b cmd /c del "%~f0" >nul 2>&1'

    $parent = Split-Path -Parent $OutPath
    if ($parent -and -not (Test-Path -LiteralPath $parent)) {
        New-Item -ItemType Directory -Path $parent -Force | Out-Null
    }
    # CRLF + ASCII so cmd.exe parses cleanly on every Windows locale.
    Set-Content -LiteralPath $OutPath -Value ($lines -join "`r`n") -Encoding ASCII
    return $OutPath
}

function Invoke-AnsysConfigFixLaunch {
    # Launches the generated .bat elevated. UAC prompt is shown to the user.
    # Returns $true if the launch succeeded (user is expected to approve UAC
    # next); $false if launch failed or the user declined elevation.
    param([Parameter(Mandatory)][string]$BatPath)
    if (-not (Test-Path -LiteralPath $BatPath)) {
        Write-AgentLog "Fix bat missing at $BatPath" -Level ERROR
        return $false
    }
    try {
        Start-Process -FilePath 'cmd.exe' -ArgumentList @('/c', "`"$BatPath`"") -Verb RunAs -ErrorAction Stop | Out-Null
        Write-AgentLog "Launched fix bat elevated: $BatPath"
        return $true
    } catch {
        # UAC decline throws System.ComponentModel.Win32Exception "The operation was canceled by the user".
        Write-AgentLog "Fix bat launch failed (likely UAC decline): $_" -Level WARN
        return $false
    }
}

function Show-ConfigMismatchToast {
    # Caller is responsible for Import-Module BurntToast before calling.
    param([Parameter(Mandatory)][int]$FindingCount)
    try {
        $btnFix    = New-BTButton -Content "Fix it"        -Arguments "ansyselastic:fix_config?session=config"    -ActivationType Protocol
        $btnIgnore = New-BTButton -Content "Ignore for now" -Arguments "ansyselastic:ignore_config?session=config" -ActivationType Protocol

        $headerText = New-BTText -Content "ANSYS configuration check"
        $bodyText   = New-BTText -Content "Your ANSYS licence configuration differs from site standard in $FindingCount place(s). This can cause silent elastic-licence consumption (which costs money). Click 'Fix it' to apply the standard (requires admin approval) or 'Ignore for now' to silence this check until something changes."

        $binding = New-BTBinding -Children $headerText, $bodyText
        $visual  = New-BTVisual  -BindingGeneric $binding
        $actions = New-BTAction  -Buttons $btnFix, $btnIgnore
        $audio   = New-BTAudio   -Source 'ms-winsoundevent:Notification.Reminder'
        # Body click routed to fix_config to match the primary button (safer
        # default than ignore_config, since the user can still cancel UAC).
        $content = New-BTContent -Visual $visual -Actions $actions -Audio $audio `
                                 -Launch "ansyselastic:fix_config?session=config" -ActivationType Protocol

        Submit-BTNotification -Content $content -UniqueIdentifier "config-mismatch"
        Write-AgentLog "Config-mismatch toast fired ($FindingCount finding(s))"
    } catch {
        Write-AgentLog "Config-mismatch toast failed: $_" -Level ERROR
    }
}

function Show-ConfigFixLaunchedToast {
    try {
        $headerText = New-BTText -Content "ANSYS configuration repair launched"
        $bodyText   = New-BTText -Content "An admin-elevation prompt should appear. Approve it to apply the fix. Close and re-open ANSYS afterwards for changes to take effect."
        $binding = New-BTBinding -Children $headerText, $bodyText
        $visual  = New-BTVisual  -BindingGeneric $binding
        $content = New-BTContent -Visual $visual
        Submit-BTNotification -Content $content -UniqueIdentifier "config-fix-launched"
    } catch {
        Write-AgentLog "Config-fix-launched toast failed: $_" -Level ERROR
    }
}

function Invoke-ConfigCheckCycle {
    # One-shot check; called at agent startup and from install.ps1. If findings
    # exist and the same finding-set hasn't been previously dismissed, fires
    # the mismatch toast. Mutates $State.config_check; caller is responsible
    # for Save-State afterwards if persistence is desired.
    param(
        [Parameter(Mandatory)][hashtable]$State,
        [ValidateSet('Agent','Install')][string]$RunMode = 'Agent'
    )
    try {
        $findings = Test-AnsysConfig
        if ($null -eq $findings) { $findings = @() }
        if (-not ($State.ContainsKey('config_check'))) {
            $State['config_check'] = @{ last_run_at = ''; ignored_hash = '' }
        }
        $State.config_check.last_run_at = (Get-Date).ToString('o')

        if ($findings.Count -eq 0) {
            Write-AgentLog "Config check ($RunMode): compliant" -Level DEBUG
            return
        }
        $hash = Get-AnsysConfigFindingsHash -Findings $findings
        if ($hash -and $hash -eq [string]$State.config_check.ignored_hash) {
            Write-AgentLog "Config check ($RunMode): $($findings.Count) finding(s) but matching ignored_hash, skipping toast" -Level DEBUG
            return
        }
        Write-AgentLog "Config check ($RunMode): $($findings.Count) finding(s), firing toast"
        foreach ($f in $findings) {
            Write-AgentLog ("  finding key={0} expected='{1}' actual='{2}'" -f $f.key, $f.expected, $f.actual)
        }
        Show-ConfigMismatchToast -FindingCount $findings.Count
    } catch {
        Write-AgentLog "Invoke-ConfigCheckCycle failed: $_" -Level ERROR
    }
}

function Get-AgentVersion {
    # Single source of truth for the agent's version string. Read from the
    # VERSION file next to common.ps1 so installer.iss and the agent can
    # both reference the same value without manual sync.
    if (Test-Path -LiteralPath $script:VersionFilePath) {
        try {
            $v = (Get-Content -LiteralPath $script:VersionFilePath -Raw -ErrorAction Stop).Trim()
            if ($v) { return $v }
        } catch {}
    }
    return 'dev'
}

function Invoke-AgentSelfTest {
    # Cheap startup health check. Returns an array of {key, message} findings;
    # empty means OK. The agent calls this once on startup and fires a single
    # toast if anything looks wrong, so a non-technical user notices when the
    # agent is technically "running" but missing a prerequisite.
    $findings = @()

    # BurntToast: if the caller could get this far, BurntToast loaded (agent.ps1
    # exits otherwise). We re-check Get-Module so install.ps1 can call this too.
    if (-not (Get-Module -ListAvailable -Name BurntToast -ErrorAction SilentlyContinue)) {
        $findings += @{
            key     = 'burnttoast.missing'
            message = "BurntToast PowerShell module not found. Toasts cannot be shown."
        }
    }

    $envInfo = Get-AnsysEnvironment
    if (-not $envInfo.AnsysIncRoot) {
        # Only a problem if the user has expressed an expectation that ANSYS
        # is installed (i.e. configured perpetual or compliance). Otherwise
        # silent -- the agent is harmless on a non-ANSYS machine.
        if ($script:LicServerHost -or $script:ExpectedConfig.AnsyslmdServer -or $script:PerpetualFeatures.Count -gt 0) {
            $findings += @{
                key     = 'ansys.notfound'
                message = "No ANSYS install detected under $($script:AnsysIncRootDefaults -join '; '). Compliance check and perpetual context will be skipped."
            }
        }
    }

    # ACL log dir is created lazily by ANSYS; not having it yet is fine. But
    # if we can't even create our own AppDataDir, the agent is broken.
    try {
        Initialize-AppDataDir
        if (-not (Test-Path -LiteralPath $script:AppDataDir)) {
            $findings += @{
                key     = 'appdata.unwritable'
                message = "Cannot create state directory $script:AppDataDir."
            }
        }
    } catch {
        $findings += @{
            key     = 'appdata.unwritable'
            message = "State directory error: $_"
        }
    }
    return ,$findings
}

function Show-AgentSelfTestToast {
    param(
        [Parameter(Mandatory)][AllowEmptyCollection()][array]$Findings
    )
    if ($Findings.Count -eq 0) { return }
    try {
        $summary = ($Findings | ForEach-Object { $_.message }) -join "  /  "
        $headerText = New-BTText -Content "ANSYS Elastic Licence Monitor - heads up"
        $bodyText   = New-BTText -Content "The agent started but found $($Findings.Count) issue(s) that may stop it working as expected: $summary. See $script:LogFilePath for details."
        $binding = New-BTBinding -Children $headerText, $bodyText
        $visual  = New-BTVisual  -BindingGeneric $binding
        $content = New-BTContent -Visual $visual
        Submit-BTNotification -Content $content -UniqueIdentifier "agent-selftest"
        Write-AgentLog "Self-test toast fired ($($Findings.Count) finding(s))"
    } catch {
        Write-AgentLog "Self-test toast failed: $_" -Level ERROR
    }
}

# Apply config.json overrides at dot-source time so every consumer (agent.ps1,
# test-parser.ps1, test-perpetual.ps1) sees the resolved values without each
# one having to call this explicitly.
Import-AppConfig
