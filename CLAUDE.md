# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## What this project is

A Windows workstation agent that detects ANSYS **elastic** licence checkouts in real time and shows toast notifications so users know they are consuming paid AEUs. Elastic licensing is invisible to the user by default — the agent re-introduces friction so consumption becomes intentional.

The repo contains only the workstation agent (PowerShell + BurntToast). There is no central API, server-side aggregator, or messaging integration in scope here.

Read `docs/ARCHITECTURE.md` before doing anything non-trivial. Its "Dead ends" section lists approaches that were investigated and ruled out (no portal API, `ansysli_util` deprecated, launcher-wrapper approach rejected, etc.) — do not re-investigate them. `README.md` is the user-facing pitch (install, config, troubleshooting) — useful when a change affects what an end-user sees.

## Commands

```powershell
# Run all offline tests (syntax + parser + configcheck). Add -IncludePerpetual
# to also hit the live licence server.
powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\test-all.ps1

# Individual tests:
powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\test-parser.ps1
powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\test-configcheck.ps1
powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\test-perpetual.ps1

# Show status (version, discovered ANSYS install, task state) and exit
powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\agent.ps1 -Status

# Syntax-check every .ps1 without executing it
$files = @('agent.ps1','common.ps1','install.ps1','uninstall.ps1','test-parser.ps1','test-perpetual.ps1','test-configcheck.ps1','toast-callback.ps1')
foreach ($f in $files) {
    $errs = $null; $tokens = $null
    [void][System.Management.Automation.Language.Parser]::ParseFile((Resolve-Path $f), [ref]$tokens, [ref]$errs)
    if ($errs.Count -eq 0) { "$f : OK" } else { "$f : $($errs.Count) error(s)"; $errs | % { "  $($_.Message) (line $($_.Extent.StartLineNumber))" } }
}

# Install (copies to %LOCALAPPDATA%\AnsysElasticLicenceMonitor, registers AtLogon scheduled task, starts now)
powershell.exe -ExecutionPolicy Bypass -File .\install.ps1

# Uninstall (stops task, kills running agent, removes ansyselastic: protocol, removes install dir)
powershell.exe -ExecutionPolicy Bypass -File .\uninstall.ps1

# Run agent in foreground for development (uses the in-repo files, not the installed copy)
powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\agent.ps1 -PollIntervalSeconds 5 -EscalationMinutes 60

# Watch live agent log when installed
Get-Content "$env:LOCALAPPDATA\AnsysElasticLicenceMonitor\agent.log" -Tail 50 -Wait

# Build the Inno Setup installer (output: dist\AnsysElasticLicenceMonitor-Setup.exe)
# Public build:
ISCC.exe installer.iss
# Internal build with a baked-in default central-config source (value not committed):
ISCC.exe /DDefaultConfigSource="\\fileserver\share\config.json" installer.iss
```

There is no test framework. The runnable tests are:
- `test-all.ps1` — aggregator: syntax-checks every `.ps1`, then runs the offline tests in fresh PowerShell sessions. The primary entry point during dev.
- `test-parser.ps1` — regex coverage against `sample-acl-log.log`. Run after any change to `Find-ElasticCheckouts` or `$ElasticCheckoutPattern` in `common.ps1`.
- `test-configcheck.ps1` — fixture-based assertions for `Test-AnsysConfig`, `Get-AnsysConfigFindingsHash`, and `New-AnsysConfigFixBat`. No ANSYS install needed; runs anywhere PowerShell does.
- `test-perpetual.ps1` — calls `lmutil lmstat` against the configured licence server. Skip in dev environments that can't reach it.

## Architecture

The agent is one long-running PowerShell loop launched at logon by a per-user scheduled task. State lives in `%LOCALAPPDATA%\AnsysElasticLicenceMonitor\` (`agent.log`, `state.json`, `toast-queue.jsonl`, `config.json`). All persistent paths are defined as `$script:` vars at the top of `common.ps1` — change them there, not inline.

**Detection signal.** Every Workbench session spawns its own `ansyscl.exe` which writes to `%LOCALAPPDATA%\Temp\.ansys\ansyscl.<HOST>.<PID1>.<PID2>.log`. Elastic checkouts are tagged `(elastic)` in that log; perpetual ones are not. That tag is the entire detection mechanism — see `docs/ARCHITECTURE.md` for why server-side detection is impossible.

**Per-iteration flow** (`Step-Agent` in `agent.ps1`):
1. Drain `toast-queue.jsonl` and apply button-click effects to in-memory state.
2. `Get-ActiveAnsysclSessions` enumerates `Win32_Process` for `ansyscl.exe` and parses the `-log <path>` argument out of the command line. The session key is `<host>.<pid1>.<pid2>` derived from the log filename.
3. New sessions start at **EOF** (current file size as byte offset) so existing log content does not retroactively trigger toasts.
4. Sessions whose `ansyscl.exe` is gone are removed.
5. For each active session, `Read-NewLogContent` reads from the saved byte offset to EOF using `FileShare::ReadWrite` (ANSYS keeps the log open). If offset > file length, the file was rotated/truncated and we restart at 0.
6. The first elastic match in `NEW` state fires Toast 1 (`Show-FirstElasticToast`) and moves the session to `NOTIFIED`. Toast 2 (`Show-EscalationToast`) fires every `EscalationMinutes` (default 60) thereafter until the session ends or the user clicks "Don't bug me this session".

**Toast button → agent feedback loop.** BurntToast buttons can only fire `-ActivationType Protocol` URLs. The agent registers `ansyselastic:` as a custom URL protocol under `HKCU:\Software\Classes\ansyselastic`; the registry command points at `wscript.exe toast-callback.vbs <url>`, and the .vbs in turn spawns `toast-callback.ps1` with `showWindow=0` to suppress the console flash that `powershell.exe -WindowStyle Hidden` still produces. Button clicks invoke `ansyselastic:<action>?session=<key>`; the .ps1 callback writes one JSONL line to `toast-queue.jsonl`; the next agent loop iteration drains the queue. This decoupling exists because the toast click handler runs in a separate transient PowerShell process — it cannot mutate the agent's in-memory state directly. If you change the URL scheme, update **all four** of: `Show-*Toast` (writers), `toast-callback.ps1` (parser), `toast-callback.vbs` (launcher passthrough), and `Register-ToastProtocol` in `common.ps1` (registrar).

**Session state machine:** `NEW` → (first elastic match) → `NOTIFIED` → (button: `suppress`) → `SUPPRESSED`. `accept` and `snooze` (body-click on escalation toast) only push `next_prompt_at` forward; they do not change state. State persists across agent restarts via `state.json`.

**Compliance check (second job).** Alongside elastic detection, the agent runs `Invoke-ConfigCheckCycle` once per loop iteration (gated by `configCheck.intervalMinutes`, default 60) to verify the workstation's static ANSYS configuration matches what site policy expects. `Test-AnsysConfig` produces a list of findings by comparing three sources against `$script:ExpectedConfig` (populated from `config.json`'s `configCheck` block): (1) the `SERVER=` line in `%TEMP%\..\Ansys Inc\Shared Files\Licensing\ansyslmd.ini`, (2) forbidden HKCU `Environment` variables (e.g. `ANSYSLI_SERVERS`, `ANSYSLMD_LICENSE_FILE`), (3) the active product in each `%APPDATA%\Ansys\v<NNN>\MechanicalLicenseOptions.xml`. Findings are hashed (`Get-AnsysConfigFindingsHash`) and compared against `state.json`'s `configCheckIgnoredHash` so the user can dismiss a specific set of findings and not get re-prompted until something changes. On a non-empty, non-ignored result, `Show-ConfigMismatchToast` fires with a "Fix it" button → `ansyselastic:configfix` → `Invoke-AnsysConfigFixLaunch` writes a base64-encoded `.bat` (via `New-AnsysConfigFixBat`) and prompts the user with UAC. The `.bat` uses `-EncodedCommand` to avoid quoting hell when editing XML/INI from a batch context. The compliance toast and `configfix` action share the same protocol pipeline as elastic toasts — if you add new URL actions, route them through `toast-callback.ps1` the same way.

**Configuration model.** Two-tier load in `Import-AppConfig` (called at dot-source time): (1) bundled `config.json` next to `common.ps1`, (2) optional central config from a *local filesystem path* (incl. UNC/mapped drive) read from `config-source.txt`. HTTPS was removed — it confused non-technical users in the wizard and added a MITM surface for no gain. Tier 2 layers over tier 1 — any field present centrally wins. If tier 2 is absent, unreachable, malformed, or over 1 MB the agent logs WARN and uses tier 1. Detection works regardless of either; only the perpetual-context enrichment in toast 1 needs `licenseServer.host`/`port` and `perpetualFeatures` set. The installer wizard prompts for the central source; pass `/DDefaultConfigSource="..."` to ISCC to pre-fill that prompt for an internal build (the value bakes into the .exe but is not in source).

**Future-proofing.** Discovery of ANSYS-internals lives in two helpers: `Get-AnsysVersionDirs` (numeric-sorted enumeration of `v*` directories — so `v100` outranks `v99` once that day arrives), and `Get-AnsysEnvironment` (single hashtable of every discovered path: install root, lmutil, ansyslmd.ini, version dirs, lmutil chosen across all versions until one works). Everything version-coupled flows through one of those. The detection couplings (`ansyscl.exe` process name, ACL log directory, ansyslmd.ini path, install root list) are also overridable in `config.json` so a future ANSYS rename/relocate is a config edit, not a code release.

**Code conventions.** `common.ps1` and `agent.ps1` set `Set-StrictMode -Version 3.0`. Forced array semantics (`@(...)`) are used at every site that takes `.Count` or indexes into a function result, because PowerShell auto-unwraps single-element pipelines under strict mode otherwise. Don't drop the wrap when refactoring.

**Install model.** The scheduled task runs `powershell.exe -File "$InstallDir\agent.ps1"` at user logon under `LogonType Interactive, RunLevel Limited` — toasts only render in an interactive desktop session, so SYSTEM/highest-privilege would silently fail to notify. `ExecutionTimeLimit` is `[TimeSpan]::Zero` (no limit) because this is a long-running poll loop, not a batch job.

## Things to know before editing

- The elastic regex (`$ElasticCheckoutPattern` in `common.ps1`) is validated against real ACL logs — see `docs/ARCHITECTURE.md` for the canonical version. Keep the PowerShell and Python copies in the architecture doc in sync if you change it.
- Do **not** call BurntToast from `toast-callback.ps1` — the callback must stay tiny because it spawns on every button click. It only writes to the queue.
- `Register-ToastProtocol` writes to `HKCU` (current-user hive) so install does not need admin rights. Keep it that way.
- `Read-ToastQueue` does an atomic rename-then-read drain. Don't replace it with a simpler "read then truncate" — that races with `toast-callback.ps1` writes.
- Avoid adding logic that reads from `Win32_Process.CommandLine` for non-`ansyscl.exe` processes — it is slow and the architecture doc rules out launcher-wrapper approaches for good reasons.
- The agent is licensed GPL v3 (see `LICENSE`). New source files should carry the standard SPDX header used by the existing files.
