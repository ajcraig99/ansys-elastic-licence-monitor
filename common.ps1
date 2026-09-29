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

# Cache of the last state JSON written to disk. Save-State compares against this
# and skips the write + atomic rename when nothing changed (steady state at a 10s
# poll is identical iteration-to-iteration), removing most state.json churn.
$script:LastSavedStateJson = $null

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

# Debug-build state. DebugModeEnabled is flipped by config.json (debug.enabled)
# and gates the extra triage affordances: View-triggers / Open-full-log toast
# buttons, raw-line + near-miss logging, and the recent_elastic_lines ring.
# Released builds leave this false and stay silent.
$script:DebugModeEnabled       = $false
$script:DebugRecentLinesCap    = 10
$script:ManualTriggerFlagPath  = Join-Path $script:AppDataDir 'trigger-check.flag'

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

    # Snapshot every overridable var before touching any of them. A terminating
    # error partway through (an unforeseen bad cast, say) would otherwise leave a
    # half-applied, blended config -- host set but port defaulted, everything past
    # the failing field skipped. On any throw we restore the pre-merge values and
    # rethrow, so the caller logs WARN and keeps whatever the prior tier loaded.
    $snapshot = @{
        LicServerHost          = $script:LicServerHost
        LicServerPort          = $script:LicServerPort
        PerpetualFeatures      = $script:PerpetualFeatures
        FeatureDisplayNames    = $script:FeatureDisplayNames
        DetectionProcessName   = $script:DetectionProcessName
        AclLogDir              = $script:AclLogDir
        DebugModeEnabled       = $script:DebugModeEnabled
        AnsyslmdServer         = $script:ExpectedConfig.AnsyslmdServer
        AnsyslmdIniPath        = $script:AnsyslmdIniPath
        AnsysIncRootDefaults   = $script:AnsysIncRootDefaults
        ForbiddenUserEnvVars   = $script:ExpectedConfig.ForbiddenUserEnvVars
        RequiredLicenseOptions = $script:ExpectedConfig.RequiredLicenseOptions
    }
    try {
        if ($cfgProps -contains 'licenseServer' -and $cfg.licenseServer) {
            $lsProps = $cfg.licenseServer.PSObject.Properties.Name
            if ($lsProps -contains 'host' -and $cfg.licenseServer.host) {
                $script:LicServerHost = [string]$cfg.licenseServer.host; $changed = $true
            }
            if ($lsProps -contains 'port' -and $cfg.licenseServer.port) {
                # Non-throwing coercion: a cast like [int]'1055x' is a *terminating*
                # error regardless of $ErrorActionPreference, which (pre-fix) killed
                # the agent at dot-source time on a single bad central-config typo --
                # fleet-wide, since the central config is shared.
                $p = 0
                if ([int]::TryParse([string]$cfg.licenseServer.port, [ref]$p)) {
                    $script:LicServerPort = $p; $changed = $true
                } else {
                    Write-AgentLog "Ignoring non-numeric licenseServer.port '$($cfg.licenseServer.port)'" -Level WARN
                }
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
        if ($cfgProps -contains 'debug' -and $cfg.debug) {
            $dbgProps = $cfg.debug.PSObject.Properties.Name
            if ($dbgProps -contains 'enabled') {
                # [bool] on a string is $true for ANY non-empty string -- so a
                # quoted "false" in JSON would silently enable debug. Compare the
                # text explicitly; only a real boolean or the literal "true"
                # (case-insensitive) turns debug on.
                $dbgVal = $cfg.debug.enabled
                if ($dbgVal -is [bool]) {
                    $script:DebugModeEnabled = $dbgVal
                } else {
                    $script:DebugModeEnabled = (([string]$dbgVal).Trim() -eq 'true')
                }
                $changed = $true
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
    } catch {
        # Roll back to the pre-merge snapshot so a partial failure can't leave a
        # blended config, then rethrow for the caller to log + fall back.
        $script:LicServerHost                         = $snapshot.LicServerHost
        $script:LicServerPort                         = $snapshot.LicServerPort
        $script:PerpetualFeatures                     = $snapshot.PerpetualFeatures
        $script:FeatureDisplayNames                   = $snapshot.FeatureDisplayNames
        $script:DetectionProcessName                  = $snapshot.DetectionProcessName
        $script:AclLogDir                             = $snapshot.AclLogDir
        $script:DebugModeEnabled                      = $snapshot.DebugModeEnabled
        $script:ExpectedConfig.AnsyslmdServer         = $snapshot.AnsyslmdServer
        $script:AnsyslmdIniPath                       = $snapshot.AnsyslmdIniPath
        $script:AnsysIncRootDefaults                  = $snapshot.AnsysIncRootDefaults
        $script:ExpectedConfig.ForbiddenUserEnvVars   = $snapshot.ForbiddenUserEnvVars
        $script:ExpectedConfig.RequiredLicenseOptions = $snapshot.RequiredLicenseOptions
        throw
    }
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
        # Guard like tier 1: a malformed central config (fleet-managed, shared)
        # must never take the agent down -- it logs WARN and falls back to tier 1.
        try {
            $tier2Loaded = Merge-AppConfigJson -Json $tier2Json
        } catch {
            Write-AgentLog "Central config merge failed: $_. Using tier 1." -Level WARN
        }
    }

    Write-AgentLog ("Config load: tier1(config.json)={0} tier2(central)={1} server={2}:{3} perpetualFeatures={4} debug={5}" -f `
        $tier1Loaded, $tier2Loaded, $script:LicServerHost, $script:LicServerPort, ($script:PerpetualFeatures -join ','), $script:DebugModeEnabled) -Level DEBUG
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
                # RawLine is the matched line verbatim. The debug build surfaces
                # this in the View-triggers evidence file so testers can confirm
                # the regex bit on something ANSYS actually wrote, not noise.
                RawLine     = $line
            }
        }
    }
    return $results
}

function Write-DebugEvidenceFile {
    # Writes a human-readable triage file for the "View triggers" debug button.
    # Uses the per-session recent_elastic_lines ring populated by Step-Agent;
    # if the ring is empty (old session, agent restart) falls back to a tail
    # re-scan of the live ACL log. Returns the absolute path of the file.
    param(
        [Parameter(Mandatory)][string]$SessionKey,
        [Parameter(Mandatory)][hashtable]$Session
    )
    Initialize-AppDataDir
    $debugDir = Join-Path $script:AppDataDir 'debug'
    if (-not (Test-Path -LiteralPath $debugDir)) {
        New-Item -ItemType Directory -Path $debugDir -Force | Out-Null
    }
    $ts = (Get-Date).ToString('yyyyMMdd-HHmmss')
    $safeKey = $SessionKey -replace '[^A-Za-z0-9._-]', '_'
    $outPath = Join-Path $debugDir "evidence-$safeKey-$ts.txt"

    $logPath        = if ($Session.ContainsKey('log_path'))         { [string]$Session.log_path }         else { '' }
    $ansysclPid     = if ($Session.ContainsKey('ansyscl_pid'))      { [string]$Session.ansyscl_pid }      else { '' }
    $sessState      = if ($Session.ContainsKey('state'))            { [string]$Session.state }            else { '' }
    $firstSeen      = if ($Session.ContainsKey('first_seen_at'))    { [string]$Session.first_seen_at }    else { '' }
    $firstElastic   = if ($Session.ContainsKey('first_elastic_at')) { [string]$Session.first_elastic_at } else { '' }
    $byteOffset     = if ($Session.ContainsKey('byte_offset'))      { [string]$Session.byte_offset }      else { '' }

    $sb = New-Object System.Text.StringBuilder
    [void]$sb.AppendLine("Ansys Elastic Licence Monitor - debug evidence")
    [void]$sb.AppendLine("Generated:        $(Get-Date -Format 'yyyy-MM-dd HH:mm:ss')")
    [void]$sb.AppendLine("Session key:      $SessionKey")
    [void]$sb.AppendLine("ACL log path:     $logPath")
    [void]$sb.AppendLine("ansyscl PID:      $ansysclPid")
    [void]$sb.AppendLine("Session state:    $sessState")
    [void]$sb.AppendLine("First seen at:    $firstSeen")
    [void]$sb.AppendLine("First elastic at: $firstElastic")
    [void]$sb.AppendLine("Byte offset:      $byteOffset")
    [void]$sb.AppendLine('')
    [void]$sb.AppendLine('Regex used (common.ps1 $ElasticCheckoutPattern):')
    [void]$sb.AppendLine("  $script:ElasticCheckoutPattern")
    [void]$sb.AppendLine('')
    [void]$sb.AppendLine('Currently held elastic features (feature -> first-seen-at):')
    if ($Session.ContainsKey('held_elastic') -and $Session.held_elastic) {
        foreach ($f in @($Session.held_elastic.Keys)) {
            [void]$sb.AppendLine("  $f => $($Session.held_elastic[$f])")
        }
    }
    [void]$sb.AppendLine('')

    $lines = @()
    if ($Session.ContainsKey('recent_elastic_lines') -and $Session.recent_elastic_lines) {
        $lines = @($Session.recent_elastic_lines)
    }
    # Fallback: rescan last 64 KB of the live log if the ring is empty.
    if ($lines.Count -eq 0 -and $logPath -and (Test-Path -LiteralPath $logPath)) {
        try {
            $size = (Get-Item -LiteralPath $logPath).Length
            $off  = [Math]::Max([long]0, $size - 65536)
            $tail = Read-NewLogContent -Path $logPath -Offset $off
            foreach ($m in (Find-ElasticCheckouts -Content $tail.Content)) {
                $lines += @{ kind = 'match'; ts = $m.Timestamp; feature = $m.Feature; user = $m.User; line = $m.RawLine }
            }
        } catch {
            Write-AgentLog "Write-DebugEvidenceFile: tail rescan failed for $logPath : $_" -Level WARN
        }
    }

    [void]$sb.AppendLine("Matched / near-miss lines (most recent last, max $($script:DebugRecentLinesCap)):")
    if ($lines.Count -eq 0) {
        [void]$sb.AppendLine('  (none captured)')
    } else {
        foreach ($e in @($lines | Select-Object -Last $script:DebugRecentLinesCap)) {
            $kind    = if ($e.ContainsKey('kind'))    { [string]$e.kind }    else { '?' }
            $line    = if ($e.ContainsKey('line'))    { [string]$e.line }    else { '' }
            $feature = if ($e.ContainsKey('feature')) { [string]$e.feature } else { '' }
            $user    = if ($e.ContainsKey('user'))    { [string]$e.user }    else { '' }
            [void]$sb.AppendLine("  [$kind] feature=$feature user=$user")
            [void]$sb.AppendLine("    $line")
        }
    }
    [void]$sb.AppendLine('')
    [void]$sb.AppendLine('If this looks like a false positive, attach this file when reporting it.')

    Set-Content -LiteralPath $outPath -Value $sb.ToString() -Encoding UTF8
    return $outPath
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
    $tempPath = "$($script:QueueFilePath).processing"
    try {
        $haveLeftover = Test-Path -LiteralPath $tempPath
        $haveQueue    = Test-Path -LiteralPath $script:QueueFilePath
        if (-not $haveLeftover -and -not $haveQueue) { return @() }

        if ($haveQueue) {
            if ($haveLeftover) {
                # A prior drain crashed after claiming the queue (the rename) but
                # before its events were applied + saved. The old behaviour deleted
                # that leftover unread, silently dropping those clicks. Instead claim
                # the live queue (atomic rename, so concurrent toast-callback writes
                # land in a fresh queue file), fold it onto the leftover, and drain
                # the union.
                $incoming = "$tempPath.incoming"
                Move-Item -Path $script:QueueFilePath -Destination $incoming -Force -ErrorAction Stop
                Get-Content -LiteralPath $incoming -ErrorAction SilentlyContinue |
                    Add-Content -LiteralPath $tempPath -Encoding UTF8 -ErrorAction SilentlyContinue
                Remove-Item -LiteralPath $incoming -Force -ErrorAction SilentlyContinue
            } else {
                # Atomic drain: rename then read.
                Move-Item -Path $script:QueueFilePath -Destination $tempPath -Force -ErrorAction Stop
            }
        }
        # else: only a leftover .processing exists -- drain it as-is.

        $events = @()
        foreach ($line in (Get-Content -LiteralPath $tempPath -ErrorAction SilentlyContinue)) {
            if ([string]::IsNullOrWhiteSpace($line)) { continue }
            try { $events += ($line | ConvertFrom-Json) }
            catch { Write-AgentLog "Bad queue line: $line" -Level WARN }
        }
        Remove-Item -LiteralPath $tempPath -Force -ErrorAction SilentlyContinue
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
                # recent_elastic_lines is the debug-build ring of recent matched
                # + near-miss lines. Always backfilled to an empty array so a
                # state file written by a non-debug build loads cleanly.
                $recentLines = @()
                if ($vProps -contains 'recent_elastic_lines' -and $v.recent_elastic_lines) {
                    foreach ($entry in @($v.recent_elastic_lines)) {
                        $eProps = $entry.PSObject.Properties.Name
                        $recentLines += @{
                            kind    = if ($eProps -contains 'kind')    { [string]$entry.kind }    else { 'match' }
                            ts      = if ($eProps -contains 'ts')      { [string]$entry.ts }      else { '' }
                            feature = if ($eProps -contains 'feature') { [string]$entry.feature } else { '' }
                            user    = if ($eProps -contains 'user')    { [string]$entry.user }    else { '' }
                            line    = if ($eProps -contains 'line')    { [string]$entry.line }    else { '' }
                        }
                    }
                }
                $sessions[$prop.Name] = @{
                    log_path             = if ($vProps -contains 'log_path')         { [string]$v.log_path } else { '' }
                    byte_offset          = if ($vProps -contains 'byte_offset')      { [long]$v.byte_offset } else { 0 }
                    ansyscl_pid          = if ($vProps -contains 'ansyscl_pid')      { [int]$v.ansyscl_pid } else { 0 }
                    first_seen_at        = if ($vProps -contains 'first_seen_at')    { [string]$v.first_seen_at } else { '' }
                    first_elastic_at     = if ($vProps -contains 'first_elastic_at') { [string]$v.first_elastic_at } else { '' }
                    next_prompt_at       = $nextPrompt
                    state                = if ($vProps -contains 'state')            { [string]$v.state } else { 'NEW' }
                    held_elastic         = $heldElastic
                    recent_elastic_lines = $recentLines
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
    $json = $State | ConvertTo-Json -Depth 10
    # Dirty check: skip the disk write + atomic rename when the serialised state
    # is byte-identical to what we last wrote. Save-State runs every loop iteration
    # (and twice on click iterations); in steady state nothing changes, so this
    # elides ~all of the otherwise-continuous state.json writes. A false "dirty"
    # (e.g. a hashtable key reorder) only over-writes; it never under-writes.
    if ($json -eq $script:LastSavedStateJson) { return }
    $tmp = "$($script:StateFilePath).tmp"
    try {
        $json | Set-Content -Path $tmp -Encoding UTF8 -ErrorAction Stop
        Move-Item -LiteralPath $tmp -Destination $script:StateFilePath -Force -ErrorAction Stop
        $script:LastSavedStateJson = $json
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
    # Wraps a single lmutil invocation in a hard timeout, because the bare TCP
    # probe doesn't catch "reachable-but-hung server" (lmutil then blocks ~30s,
    # freezing the entire agent loop). Runs lmutil as a child Process so a timeout
    # can Kill() the exact PID -- the old Start-Job approach left lmutil.exe
    # orphaned (one per timed-out toast) until its own ~30s timeout, because
    # Remove-Job tears down only the job runspace, not its external grandchild.
    param(
        [Parameter(Mandatory)][string]$LmutilPath,
        [Parameter(Mandatory)][string[]]$ArgList,
        [int]$TimeoutSeconds = 5
    )
    $proc = $null
    try {
        # Quote only args that need it; lmstat's args (feature name, port@host)
        # are token-like, so this matches the prior native-call behaviour.
        $quoted = $ArgList | ForEach-Object {
            if ($_ -match '[\s"]') { '"' + ($_ -replace '"', '\"') + '"' } else { $_ }
        }
        $psi = New-Object System.Diagnostics.ProcessStartInfo
        $psi.FileName               = $LmutilPath
        $psi.Arguments              = ($quoted -join ' ')
        $psi.RedirectStandardOutput = $true
        $psi.RedirectStandardError  = $true
        $psi.UseShellExecute        = $false
        $psi.CreateNoWindow         = $true

        $proc = [System.Diagnostics.Process]::Start($psi)
        # Read both streams async before waiting, or a child that fills a pipe
        # buffer would deadlock against WaitForExit.
        $outTask = $proc.StandardOutput.ReadToEndAsync()
        $errTask = $proc.StandardError.ReadToEndAsync()
        if ($proc.WaitForExit($TimeoutSeconds * 1000)) {
            return ([string]($outTask.Result + $errTask.Result))
        }
        Write-AgentLog "lmutil timed out after ${TimeoutSeconds}s (args: $($ArgList -join ' ')); killing pid $($proc.Id)" -Level WARN
        try { $proc.Kill() } catch {}
        return ''
    } catch {
        Write-AgentLog "lmutil invocation failed: $_" -Level WARN
        return ''
    } finally {
        if ($proc) { try { $proc.Dispose() } catch {} }
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
        [string]$AnsyslmdIniPath  = '',
        [string]$AnsysUserAppData = $script:AnsysUserAppData
    )
    $findings = @()

    # Resolve the ini once via the same discovery the rest of the agent uses.
    # The canonical C:\...\Shared Files\licensing\ansyslmd.ini may be absent while
    # a per-version <ver>\Shared Files\Licensing\ansyslmd.ini exists -- if the
    # check reads one file and the fix writes another, the "fix" creates a brand-
    # new canonical file ANSYS never reads (and M1 makes that failure invisible).
    # The resolved path is carried on the finding so the fix-bat writes the same
    # file we inspected. Tests pass an explicit fixture path, which wins.
    if ([string]::IsNullOrWhiteSpace($AnsyslmdIniPath)) {
        $AnsyslmdIniPath = (Get-AnsysEnvironment).AnsyslmdIniPath
        if ([string]::IsNullOrWhiteSpace($AnsyslmdIniPath)) {
            $AnsyslmdIniPath = $script:AnsyslmdIniPath   # canonical default (used to create if nothing exists)
        }
    }

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
                ini_path        = $AnsyslmdIniPath
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
                # $app is interpolated into a path that gets XML-loaded and, when
                # remediating, .Save()-d as admin. Reject anything that isn't a
                # plain prefix so a hostile or typo'd central-config key can't
                # traverse out of the version dir (e.g. '..\..\..\Windows\...').
                if ($app -notmatch '^[A-Za-z0-9_]+$') {
                    Write-AgentLog "Ignoring requiredLicenseOptions key '$app' (must be letters/digits/underscore)" -Level WARN
                    continue
                }
                $expectedName = [string]$reqLO[$app]
                if (-not $expectedName) { continue }
                $xmlPath = Join-Path $v.FullName "$($app)LicenseOptions.xml"
                if (-not (Test-Path -LiteralPath $xmlPath)) { continue }   # app not installed for this version
                $actualName = ''
                try {
                    # DtdProcessing=Prohibit + null resolver: a crafted *LicenseOptions.xml
                    # with a billion-laughs entity expansion would otherwise OOM/hang the
                    # parser. The bare [xml] accelerator processes internal DTD entities.
                    $rdrSettings = New-Object System.Xml.XmlReaderSettings
                    $rdrSettings.DtdProcessing = [System.Xml.DtdProcessing]::Prohibit
                    $rdrSettings.XmlResolver   = $null
                    $doc = New-Object System.Xml.XmlDocument
                    $reader = [System.Xml.XmlReader]::Create($xmlPath, $rdrSettings)
                    try { $doc.Load($reader) } finally { $reader.Dispose() }
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

function Test-SafeFixTargetPath {
    # Defence-in-depth for the one elevated code path. The fix-bat writes to
    # paths that can originate from the central config (a network-share file
    # editable by people other than the workstation user) and it *creates* the
    # target if absent -- so a bad path means an elevated create/overwrite at an
    # attacker- or typo-chosen location. Reject anything that could redirect it:
    #   - empty / whitespace
    #   - any '..' traversal segment
    #   - not a fully-qualified local (C:\...) or UNC (\\server\share\...) path
    # A legitimate ansyslmd.ini / *LicenseOptions.xml target is always a fully-
    # qualified path with no '..', so this never rejects a valid config. It does
    # not defend against a fully-hostile config that also rewrites the expected
    # roots -- the trusted-share assumption covers that residue (see REVIEW M2).
    param([Parameter(Mandatory)][AllowEmptyString()][string]$Path)
    if ([string]::IsNullOrWhiteSpace($Path)) { return $false }
    foreach ($seg in ($Path -split '[\\/]')) {
        if ($seg -eq '..') { return $false }
    }
    # Drive-rooted 'C:\...'/'C:/...' or UNC '\\host\...'. Rejects bare names,
    # relative paths, and drive-relative 'C:foo'.
    if ($Path -notmatch '^[A-Za-z]:[\\/]' -and $Path -notmatch '^[\\/]{2}[^\\/]') { return $false }
    return $true
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
                # M3: write the same file the check inspected (carried on the
                # finding), falling back to canonical only for legacy findings.
                $iniPath = if ($f.ContainsKey('ini_path') -and $f.ini_path) { [string]$f.ini_path } else { $script:AnsyslmdIniPath }
                # M2: this is an elevated write whose target can come from config.
                if (-not (Test-SafeFixTargetPath $iniPath)) {
                    Write-AgentLog "Skipping ansyslmd.ini fix: unsafe target path '$iniPath'" -Level WARN
                    $lines += "REM Skipped $($f.key): unsafe target path '$iniPath'"
                    $lines += ''
                    continue
                }
                $expServer = [string]$f.expected
                # In-place SERVER= rewrite, preserving other lines. Idempotent:
                # running twice yields the same end state. $ErrorActionPreference
                # = Stop + try/catch/exit 1 so a failed write (read-only dir, ACL,
                # or file held open by a running ANSYS) reports FAILED instead of
                # a false "OK" -- Set-Content's failure is otherwise non-terminating.
                $cmd = @"
`$ErrorActionPreference = 'Stop'
try {
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
} catch {
    Write-Error `$_ -ErrorAction Continue
    exit 1
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
                # M2: defence-in-depth on the elevated write target. The app key is
                # already validated in Test-AnsysConfig, but re-check the full path.
                if (-not (Test-SafeFixTargetPath $xmlPath)) {
                    Write-AgentLog "Skipping $($f.key) fix: unsafe target path '$xmlPath'" -Level WARN
                    $lines += "REM Skipped $($f.key): unsafe target path '$xmlPath'"
                    $lines += ''
                    continue
                }
                # Parse-and-edit so non-LicenseInfo nodes/attributes are
                # preserved. If no active LicenseInfo exists, one is created.
                # $ErrorActionPreference=Stop + try/catch/exit 1 surfaces a failed
                # write; DtdProcessing=Prohibit blocks DTD-entity expansion in this
                # elevated parse of a user-controlled file.
                $cmd = @"
`$ErrorActionPreference = 'Stop'
try {
`$path = $(Escape-PsSQ $xmlPath)
`$exp  = $(Escape-PsSQ $expName)
`$bak  = `$path + '.bak-$ts'
`$parent = Split-Path -Parent `$path
if (`$parent -and -not (Test-Path -LiteralPath `$parent)) { New-Item -ItemType Directory -Path `$parent -Force | Out-Null }
`$rdrSettings = New-Object System.Xml.XmlReaderSettings
`$rdrSettings.DtdProcessing = [System.Xml.DtdProcessing]::Prohibit
`$rdrSettings.XmlResolver   = `$null
if (Test-Path -LiteralPath `$path) {
    Copy-Item -LiteralPath `$path -Destination `$bak -Force -ErrorAction SilentlyContinue
    try {
        `$doc = New-Object System.Xml.XmlDocument
        `$reader = [System.Xml.XmlReader]::Create(`$path, `$rdrSettings)
        try { `$doc.Load(`$reader) } finally { `$reader.Dispose() }
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
} catch {
    Write-Error `$_ -ErrorAction Continue
    exit 1
}
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

# The BurntToast version the toast code is tested against. install.ps1 installs
# exactly this version; Import-PinnedBurntToast prefers it so a newer copy on the
# machine (PSGallery latest is 1.x, untested here) is not picked up by default.
$script:BurntToastVersion = '0.8.5'

function Import-PinnedBurntToast {
    # Throws if no BurntToast is available at all; callers handle that.
    $pinned = Get-Module -ListAvailable -Name BurntToast -ErrorAction SilentlyContinue |
        Where-Object { $_.Version -eq [version]$script:BurntToastVersion } | Select-Object -First 1
    if ($pinned) {
        Import-Module $pinned.Path -ErrorAction Stop | Out-Null
        Write-AgentLog "BurntToast $($script:BurntToastVersion) loaded"
    } else {
        Import-Module BurntToast -ErrorAction Stop | Out-Null
        $v = (Get-Module BurntToast).Version
        Write-AgentLog "BurntToast $($script:BurntToastVersion) not installed; loaded untested version $v instead" -Level WARN
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
#
# toast-callback.ps1 sets ANSYS_ELM_SKIP_AUTOCONFIG=1 before dot-sourcing: it
# only needs the queue-write + path/log helpers, and re-reading config.json (and
# possibly a UNC central config) on every single button click is wasted I/O. The
# callback never touches any config-derived var, so skipping the load is safe.
if ($env:ANSYS_ELM_SKIP_AUTOCONFIG -ne '1') {
    Import-AppConfig
}
