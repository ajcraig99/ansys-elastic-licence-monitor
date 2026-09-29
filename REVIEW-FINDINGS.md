# Code review findings — implementation handoff

**Date of review:** 2026-06-12
**Scope:** Full source review of the Ansys Elastic Licence Monitor agent (`common.ps1`, `agent.ps1`, `toast-callback.ps1/.vbs`, `install.ps1`, `uninstall.ps1`, `installer.iss`, test scripts, configs, docs).
**Status:** Review only — no code was changed. This file is the work list for the next agent.

## How to use this document

Each finding has: severity, location, the problem, and a concrete fix. **Line numbers are as of the review and will drift as you edit — confirm by reading the file before each change.** Implement in the "recommended order" at the bottom; it is sequenced by impact-per-effort.

After each change, re-run the offline tests and the syntax pass (from `CLAUDE.md`):

```powershell
powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\test-all.ps1
```

Do not regress these constraints (from `CLAUDE.md`):
- Keep `toast-callback.ps1` tiny (see L6) and only writing to the queue — never call BurntToast from it.
- `Register-ToastProtocol` must stay HKCU (no admin).
- Don't replace `Read-ToastQueue`'s atomic rename-then-read drain with read-then-truncate.
- Keep the PowerShell and Python regex copies in `docs/ARCHITECTURE.md` in sync if you touch the elastic regex.
- Forced array semantics (`@(...)`) at every `.Count`/index site are required under `Set-StrictMode 3.0` — don't drop them.

---

## HIGH

### H1 — Malformed central config crashes the agent at startup (breaks documented graceful-fallback)

**Location:** `common.ps1` — `Import-AppConfig` call site (~277-281); throw originates in `Merge-AppConfigJson` (~194-196).

**Problem:** `Import-AppConfig` wraps the tier-1 (bundled) merge in try/catch but the tier-2 (central) merge is unguarded:

```powershell
$tier2Json = Get-CentralConfigText
$tier2Loaded = $false
if ($null -ne $tier2Json) {
    $tier2Loaded = Merge-AppConfigJson -Json $tier2Json   # <-- not guarded
}
```

Inside `Merge-AppConfigJson`, the port uses a hard cast:

```powershell
$script:LicServerPort = [int]$cfg.licenseServer.port
```

A non-numeric port in the central config (e.g. `"port": "1055x"`, `"port": "1,055"`) raises a terminating `PSInvalidCastException`. **Cast exceptions are terminating regardless of `$ErrorActionPreference`**, so it propagates out of `Merge-AppConfigJson` → `Import-AppConfig` (runs at dot-source time, end of `common.ps1`) → the dot-source in `agent.ps1` (no surrounding try/catch) → the agent dies at startup. Because the central config is fleet-managed, one typo takes down every workstation pointed at it. The same throw also silently kills `toast-callback.ps1` on every click (it dot-sources `common.ps1` too).

This violates `docs/ARCHITECTURE.md` and `README.md`, which both promise that a malformed central source logs WARN and falls back to tier 1.

**Secondary defect (fix at the same time):** `Merge-AppConfigJson` mutates `$script:` vars incrementally with no rollback, so even on the caught tier-1 path a bad port leaves a half-applied config (host set, port defaulted, everything after the `licenseServer` block skipped).

**Fix:**
1. Guard the tier-2 call like tier-1:

```powershell
if ($null -ne $tier2Json) {
    try { $tier2Loaded = Merge-AppConfigJson -Json $tier2Json }
    catch { Write-AgentLog "Central config merge failed: $_. Using tier 1." -Level WARN }
}
```

2. Make the port coercion non-throwing:

```powershell
if ($lsProps -contains 'port' -and $cfg.licenseServer.port) {
    $p = 0
    if ([int]::TryParse([string]$cfg.licenseServer.port, [ref]$p)) {
        $script:LicServerPort = $p; $changed = $true
    } else {
        Write-AgentLog "Ignoring non-numeric licenseServer.port '$($cfg.licenseServer.port)'" -Level WARN
    }
}
```

3. (Recommended) Compute fields into locals and assign to `$script:` vars only after all parsing succeeds, so a partial failure can't leave a blended config.

**Verification:** Add a fixture with `"port": "abc"` and confirm `Import-AppConfig` logs WARN and leaves prior values intact rather than throwing. Consider extending `test-configcheck.ps1` (or a new `test-config.ps1`) to cover this.

---

## MEDIUM

### M1 — The elevated fix-bat reports "OK" even when the `ansyslmd.ini` write fails

**Location:** `common.ps1` — `New-AnsysConfigFixBat`, ini payload + errorlevel check (~1037-1059).

**Problem:** The bat checks success with `if errorlevel 1` after each `powershell.exe -EncodedCommand`. The ini-rewrite payload never sets `$ErrorActionPreference = 'Stop'` and only puts `-ErrorAction Stop` on `Get-Content` (the read), not on `Set-Content` (the write). A failed write — the likely failure, since the file is under `C:\Program Files\ANSYS Inc\Shared Files\licensing\` and may be read-only, ACL-restricted even when elevated, or held open by a running ANSYS — is **non-terminating**, so `powershell.exe` exits 0 and the bat prints `OK: ansyslmd.ini`. The user believes the config was repaired when it wasn't and keeps burning elastic.

The XML payload ends in `$doc.Save()` (a .NET call that throws → exit 1 → detected), so the two remediation paths report errors inconsistently.

**Fix:** Prepend `$ErrorActionPreference = 'Stop'` to each generated payload and wrap the body so a failure sets a non-zero exit code. For the ini payload (and mirror for the XML payload):

```powershell
$ErrorActionPreference = 'Stop'
try {
    # ... existing payload body ...
} catch {
    Write-Error $_
    exit 1
}
```

Note: the payloads are here-strings with backtick-escaped `$`; keep the escaping consistent when editing.

**Verification:** `test-configcheck.ps1` already decodes the `-EncodedCommand` payloads — extend it to assert each decoded payload contains `$ErrorActionPreference = 'Stop'` and an `exit 1` path.

### M2 — Config-sourced values flow unvalidated into the elevated remediation bat (arbitrary elevated write target)

**Location:** `common.ps1` — XML path build (~940) and bat XML payload (~1077); ini path (~1033); server string via `Get-ExpectedAnsysServer` (~869) used at (~909).

**Problem:** The fix-bat is the only privileged action in an otherwise no-admin agent, and several of its target paths come from the central config (a network-share file) with no validation:

- `expectedConfig.ansyslmdIniPath` becomes `$iniPath` in the bat; the payload **creates the file if absent**, so a central config can direct an elevated create/overwrite at an arbitrary path with semi-controlled `SERVER=…` content.
- `requiredLicenseOptions` **keys** (`$app`) are interpolated into `Join-Path $v.FullName "$($app)LicenseOptions.xml"`. A key containing `..\` traverses out of the version dir; the path is then `[xml]`-loaded and `.Save()`-d **as admin**, overwriting an existing file with XML.

`Escape-PsSQ` correctly prevents PowerShell *string* injection (verified — leave it as is) but does nothing about path traversal or a hostile target path. Exploitation needs write access to the config share plus a user approving UAC, so the trusted-share assumption is the mitigation — but this is an elevated path fed by a file editable by people other than the machine's user.

**Fix:** Validate before use, in `Test-AnsysConfig`/`New-AnsysConfigFixBat`:
- `$app` keys: reject anything not matching `^[A-Za-z0-9_]+$`.
- `ansyslmdIniPath`: reject paths containing `..`; ideally require it to resolve under a `…\ANSYS Inc\…` root (or an explicit allowlist).
- Normalize/resolve all bat target paths and confirm they sit under expected roots before emitting fix commands; log and skip findings that fail validation.

### M3 — Compliance check and fix can target a different `ansyslmd.ini` than ANSYS actually uses

**Location:** `common.ps1` — `Test-AnsysConfig` default param (~883), `Get-AnsysEnvironment` discovery (~407-417), bat ini path (~1033).

**Problem:** `Test-AnsysConfig` and the fix-bat both key off `$script:AnsyslmdIniPath` (canonical `C:\Program Files\ANSYS Inc\Shared Files\licensing\ansyslmd.ini`). But `Get-AnsysEnvironment` independently *discovers* a per-version `…\v<NNN>\Shared Files\Licensing\ansyslmd.ini` when the canonical path is absent. On a machine where the canonical file doesn't exist, the check reads `''`, reports a finding, and the bat **creates a new canonical file** while the per-version file ANSYS may actually read is untouched — so the "fix" changes nothing ANSYS reads (and M1 makes that invisible).

**Fix:** Resolve the ini once via `Get-AnsysEnvironment().AnsyslmdIniPath`, have `Test-AnsysConfig` use that resolved path, and carry it on the emitted finding (e.g. an `ini_path` field) so the bat writes the same file that was inspected. (Mirrors how `licopt.*` findings already carry `xml_path`.)

### M4 — `[xml]` parsing of user-controlled `*LicenseOptions.xml` without DTD hardening

**Location:** `common.ps1` — `Test-AnsysConfig` (~944, unprivileged, every check cycle) and bat XML payload (~1085, elevated).

**Problem:** `[xml]$doc = Get-Content …` uses default `XmlDocument` settings, which still process internal DTD entities. A crafted `*LicenseOptions.xml` with a billion-laughs entity expansion can OOM/hang the parser (the `try/catch` won't cleanly recover an OOM). External-entity file disclosure is largely mitigated on modern .NET Framework (XmlResolver defaults to null), so realistic impact is DoS, mostly self-targeted — but one of the two parse sites runs elevated, so harden it.

**Fix:** Replace the bare `[xml]` accelerator with an `XmlReader` configured to refuse DTDs, in both sites:

```powershell
$settings = New-Object System.Xml.XmlReaderSettings
$settings.DtdProcessing = [System.Xml.DtdProcessing]::Prohibit
$settings.XmlResolver = $null
$doc = New-Object System.Xml.XmlDocument
$reader = [System.Xml.XmlReader]::Create($xmlPath, $settings)
try { $doc.Load($reader) } finally { $reader.Dispose() }
```

(In the bat's here-string payload, remember to backtick-escape `$`.)

---

## LOW

### L1 — `$matches` local variable shadows the automatic `$Matches`
**Location:** `agent.ps1` — assigned ~358, read ~378, with a `-match` at ~389 in the same block (debug path).
`$matches = Find-ElasticCheckouts …` writes PowerShell's automatic `$Matches` (names are case-insensitive). It's safe today only because every read happens before the `-match` at ~389 overwrites it — a fragile invariant. Rename the local to `$elasticMatches` (update the two `foreach ($m in $matches)` reads too).

### L2 — Toast clicks can be lost in a narrow crash window
**Location:** `common.ps1` — `Read-ToastQueue` (~615).
The drain deletes any leftover `*.processing` file at the *start* of a drain. If the agent crashes after the rename but before events are applied/saved, those events are discarded on next run. Window is tiny and recoverable by re-clicking. Safer pattern: if a `.processing` file already exists at drain start, process it instead of deleting it.

### L3 — No single-instance guard
**Location:** `agent.ps1` main loop; task settings in `install.ps1` (~180-186).
Nothing stops two agents running at once (task `-RestartCount 3` overlap, or a manual run beside the task). Two loops draining the same queue and writing `state.json` would double-toast and clobber state. Acquire a named mutex at startup (e.g. `Global\AnsysElasticLicenceMonitor` or a CurrentUser-scoped name) and exit if already held.

### L4 — `[bool]$cfg.debug.enabled` treats the string `"false"` as true
**Location:** `common.ps1` (~225).
`[bool]"false"` is `$true` (non-empty string). Proper JSON (`false`) is fine; a quoted `"false"` silently enables debug. Coerce explicitly (compare against `$true`/`'true'`, or guard the value).

### L5 — Orphaned `lmutil.exe` on timeout
**Location:** `common.ps1` — `Invoke-LmutilWithTimeout` (~797-808).
On `Wait-Job` timeout, `Remove-Job -Force` stops the job runspace but may leave the external `lmutil.exe` child running until its own ~30s timeout — one orphan per timed-out toast. Track and kill the child PID, or run lmutil via `System.Diagnostics.Process` with an explicit `Kill()` on timeout.

### L6 — `toast-callback.ps1` does more than the "tiny callback" intent
**Location:** `toast-callback.ps1` (~11) → `Import-AppConfig` at end of `common.ps1` (~1314).
Dot-sourcing `common.ps1` runs `Import-AppConfig` on every button click, re-reading `config.json` and the central config (possibly a UNC/network read). It only needs `Write-ToastQueueEntry` plus path/log helpers. Options: split the queue-write helper + path vars into a tiny shared file the callback dot-sources, or guard `Import-AppConfig` so it's skipped when invoked from the callback. Keep the callback minimal per `CLAUDE.md`.

### L7 — Doc/behavior mismatches and redundant I/O (minor)
- `README.md` (~169) says "5 MB, 1 backup"; `Write-AgentLog` (`common.ps1` ~110-124) keeps **3** rotations. Make them agree.
- `Save-State` runs every loop iteration (`agent.ps1` ~476) regardless of change, and twice on click iterations (~284 + ~476). At a 10s poll that's ~8,600 writes/day of usually-unchanged state. A dirty-flag (only save when state actually changed) removes most of it. Minor, but it's continuous I/O.

---

## Recommended implementation order

1. **H1** — guard tier-2 merge + non-throwing coercion. Only finding that takes the agent down; fleet-wide; lowest effort.
2. **M1** — make the fix-bat detect write failures (`$ErrorActionPreference='Stop'` + try/catch/`exit 1`). A remediation tool reporting false success defeats the product's purpose.
3. **M2** — validate config-sourced paths/keys before they reach the elevated bat (the one privileged path, fed by a shared file).
4. **M3** — unify ini-path resolution between the check and the fix.
5. **M4** — harden `[xml]` parsing (DtdProcessing=Prohibit) at both sites.
6. **L1–L7** — opportunistic cleanups; L1 (rename `$matches`) and L4 (`[bool]`) are quick and worth doing alongside H1/M-series since they touch the same files.

## Overall assessment (context for the implementer)

The codebase is carefully built and defensively minded — atomic state writes, EOF-start to avoid retroactive toasts, allowlisted URL-protocol surface, correct single-quote escaping in the bat, numeric version sorting, hard timeouts on lmutil/TCP/BurntToast-install, forward-tolerant state loading. The findings cluster around the two riskiest areas: **config ingestion** (externally-controlled central-config file) and the **one elevated code path** (the fix-bat). Those are exactly where the extra robustness pays off, so prioritize H1/M1/M2.
