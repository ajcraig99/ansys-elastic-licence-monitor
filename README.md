# Ansys Elastic Licence Monitor

A Windows workstation agent that detects ANSYS **elastic** licence checkouts in real time and shows escalating Windows toast notifications. It exists because elastic licensing is invisible to the user by default — Workbench, Mechanical, Discovery and Fluent will silently fall back to paid cloud licences whenever a perpetual feature is unavailable. The agent re-introduces the missing friction.

For the technical background — why workstation-side detection, what the regex matches, the various dead ends investigated and ruled out — see [`docs/ARCHITECTURE.md`](docs/ARCHITECTURE.md).

## Status

V1 functional. Tested live against ANSYS Discovery and ANSYS Workbench. Detection, threshold gating, toast firing, click handling, and perpetual-context enrichment all confirmed working.

Currently distributed unsigned — first run hits Windows SmartScreen ("Windows protected your PC" → More info → Run anyway). Code signing is on the roadmap.

## Files

| File | Purpose |
|---|---|
| `agent.ps1` | Main loop, state machine, toast firing |
| `common.ps1` | Shared paths, regex, logging, state IO, lmutil parsing, URL-protocol registration, config loader |
| `config.json` | Site-specific overrides (licence server, perpetual feature list, display names). Read by `common.ps1` at dot-source time, falls back to empty defaults if missing or malformed. |
| `toast-callback.ps1` | Parses `ansyselastic:` URL, writes click event to queue file |
| `toast-callback.vbs` | Hidden launcher for `toast-callback.ps1` (avoids console flash) |
| `install.ps1` | Copies files to `%LOCALAPPDATA%\AnsysElasticLicenceMonitor\`, installs BurntToast, registers scheduled task + URL protocol, starts the task. Skips its own copy step when invoked from inside the install dir (the Inno post-install path). `config.json` is copy-only-if-absent so admin edits survive re-install. |
| `uninstall.ps1` | Reverses install (task, registry, install dir). `-SkipDirRemoval` skips the dir wipe so Inno can own it during installer-driven uninstall. Leaves BurntToast module in place. |
| `installer.iss` | Inno Setup 6 script that builds `dist\AnsysElasticLicenceMonitor-Setup.exe`. Bundles the agent files, runs `install.ps1` post-install, runs `uninstall.ps1 -SkipDirRemoval` on uninstall. |
| `sample-acl-log.log` | Fixture for offline regex test (4 elastic events + 4 perpetual events) |
| `test-parser.ps1` | Validates regex against fixture |
| `test-perpetual.ps1` | Probes lmutil + perpetual context parser for each feature |
| `docs/ARCHITECTURE.md` | Detection signal, agent design, dead ends, glossary |

## Architecture in 12 lines

```
[user logs on]
   │
   ▼
[Scheduled Task: At Logon, current user, hidden window]
   │
   ▼
[agent.ps1 main loop, every $PollIntervalSeconds]
   ├── enumerate ansyscl.exe via Win32_Process, parse -log <path>
   ├── for each active session: tail ACL log incrementally (byte-offset state)
   ├── match elastic regex; update per-session held_elastic set
   ├── if any feature held >= $ElasticDetectionThresholdSec and state==NEW: fire toast 1
   ├── if state==NOTIFIED and timer expired: fire toast 2; re-arm
   ├── drain toast-queue.jsonl from URL-protocol callbacks; apply state changes
   └── save state.json
```

Session key: `<host>.<pid1>.<pid2>` from ACL log filename `ansyscl.<host>.<pid1>.<pid2>.log`. Full architecture, dead ends, and glossary in [`docs/ARCHITECTURE.md`](docs/ARCHITECTURE.md).

### State machine

| From | Trigger | To | Effect |
|---|---|---|---|
| NEW | feature held continuously >= threshold | NOTIFIED | Fire toast 1 |
| NOTIFIED | `next_prompt_at` elapsed, still elastic | NOTIFIED | Fire toast 2, re-arm timer |
| NOTIFIED | "Don't bug me this session" click on toast 1 | SUPPRESSED | – |
| NOTIFIED | "Accept" click on toast 2 | SUPPRESSED | – |
| NOTIFIED | Body click on toast 2 (snooze) | NOTIFIED | `next_prompt_at` = now + 5 min |
| any | `ansyscl.exe` exits | (removed) | Session deleted from state |

`held_elastic` is a per-session map of `feature -> ISO8601 timestamp the agent first observed the checkout`. The threshold gate uses the oldest entry's age to decide whether to fire toast 1 — this filters transient features like `rdpara` that check out for a few seconds on Workbench open and release before any user could meaningfully act on them.

## Parameters (`agent.ps1`)

| Parameter | Default | Description |
|---|---|---|
| `-PollIntervalSeconds` | 10 | Main loop interval |
| `-EscalationMinutes` | 60 | Time between toast 1 and toast 2, and between re-prompts |
| `-ElasticDetectionThresholdSec` | 30 | Minimum continuous hold time before firing toast 1. Don't drop below ~30s — `rdpara` would fire spurious toasts. |

For aggressive testing: `-PollIntervalSeconds 5 -EscalationMinutes 1 -ElasticDetectionThresholdSec 30`.

## Configuration

Detection works without any configuration — the `(elastic)` tag in the ACL log is universal. The perpetual-context enrichment in toast 1 (the *"Perpetual Mechanical Pro is held by [user]"* variant, useful so users know they could have waited rather than gone elastic) requires you to point the agent at your FlexLM server. Edit `%LOCALAPPDATA%\AnsysElasticLicenceMonitor\config.json` post-install:

```json
{
  "licenseServer": {
    "host": "your-licence-server.example.local",
    "port": 1055
  },
  "perpetualFeatures": ["mech_1", "advanced_meshing", "dsdxm"],
  "featureDisplayNames": {
    "mech_1": "Mechanical Pro",
    "advanced_meshing": "Advanced Meshing",
    "dsdxm": "DesignXplorer"
  }
}
```

Key reference:

| Key | Default | Notes |
|---|---|---|
| `licenseServer.host` | `""` (empty, enrichment disabled) | Your local FlexLM perpetual server |
| `licenseServer.port` | `0` (empty, enrichment disabled) | FlexLM port (typically 1055) |
| `perpetualFeatures` | `[]` (empty, enrichment disabled) | ACL feature names eligible for the "held by [user]" enrichment. Without these, those features still trigger detection toasts but lose the per-user context. |
| `featureDisplayNames` | `{}` | Friendly names shown in toasts. Falls back to raw feature name if not in map. |

The installer ships `config.json` with `onlyifdoesntexist`, so admin edits survive in-place reinstalls. To force a config reset: uninstall (which wipes the install dir) then reinstall, or delete the file before reinstalling.

### Central config (multi-machine deployments)

For fleet deployments where you'd rather not hand-edit `config.json` on every machine, the installer wizard prompts for an optional **central config location**. Anything you enter is saved to `config-source.txt` next to `common.ps1`; the agent reads from that location at startup and layers it over the bundled `config.json` (any field present centrally wins).

Supported source formats:

| Form | Example | Notes |
|---|---|---|
| HTTPS URL | `https://files.example.com/share/config.json` | Public/anonymous endpoints work directly. Auth-protected endpoints require the URL itself to embed access (e.g. SharePoint shared link, Egnyte share link). |
| Mapped drive | `Z:\share\config.json` | Resolved in the user's logon session. If the drive isn't mapped yet at agent startup (rare race), enrichment uses bundled defaults until next startup. |
| UNC path | `\\fileserver\share\config.json` | Integrated AD auth. |
| Local file | `C:\path\config.json` | Mostly for testing. |
| *(blank)* | | Use bundled `config.json` only. |

**Refresh cadence**: agent startup. To propagate a central-config change, users restart their machines (or the scheduled task — `Stop-ScheduledTask 'Ansys Elastic Licence Monitor' ; Start-ScheduledTask 'Ansys Elastic Licence Monitor'`).

**On fetch failure** (network down, file removed, malformed JSON): the agent logs a WARN to `agent.log` and uses bundled defaults — detection still works, just without the perpetual-context enrichment until the central source is reachable again.

### Pre-filling the wizard for an internal build

If you want your team's installer to default to a specific central source so users just click Next, pass `/DDefaultConfigSource="..."` on the ISCC command line:

```powershell
& "$env:LOCALAPPDATA\Programs\Inno Setup 6\ISCC.exe" /DDefaultConfigSource="\\fileserver\share\config.json" .\installer.iss
```

The default value is baked into your built `.exe` but is **not** in the public source code. Public builds (no `/D` switch) ship with an empty default. To avoid having to remember the flag, drop the value into a gitignored file (`build-config.iss` is ignored by default) and `#include` it from your local `installer.iss` if you want — anything outside the tracked source stays private.

## Paths

| Path | Purpose |
|---|---|
| `%LOCALAPPDATA%\AnsysElasticLicenceMonitor\` | Install root |
| `%LOCALAPPDATA%\AnsysElasticLicenceMonitor\agent.log` | Rotating log (5 MB, 1 backup) |
| `%LOCALAPPDATA%\AnsysElasticLicenceMonitor\state.json` | Persisted session state |
| `%LOCALAPPDATA%\AnsysElasticLicenceMonitor\config.json` | Site overrides. Preserved across in-place reinstalls. |
| `%LOCALAPPDATA%\AnsysElasticLicenceMonitor\toast-queue.jsonl` | Click events from toast button presses |
| `HKCU:\Software\Classes\ansyselastic` | URL protocol registration for toast button activation |
| `%LOCALAPPDATA%\Temp\.ansys\ansyscl.<host>.<pid1>.<pid2>.log` | The ACL log files we tail (written by ANSYS) |
| `C:\Program Files\ANSYS Inc\v<NN>\licensingclient\winx64\lmutil.exe` | FlexLM utility, autodetected (newest installed version) |

Scheduled task name: `Ansys Elastic Licence Monitor`.

## Toast UX

**Toast 1** (first sustained elastic checkout per session):

- Title: `ANSYS Elastic Licensing`
- Body, default: *"You are now using paid ANSYS elastic licensing for {DisplayName}. Reminder in {EscalationMinutes} min if still active."*
- Body, perpetual unreachable: *"ANSYS licence server unreachable. You are now using paid elastic for {DisplayName}."*
- Body, perpetual held by others: *"Perpetual {DisplayName} held by {user1, user2}. You are now using paid elastic instead."*
- Buttons: `Got it`, `Don't bug me this session`
- Audio: `ms-winsoundevent:Notification.Reminder`
- Body click: same as `Got it` (no state change)

**Toast 2** (escalation, fires every `EscalationMinutes` after toast 1 until accepted, suppressed, or session ends):

- Title: `ANSYS Elastic Licensing - action needed`
- Body: *"ANSYS elastic licensing has been in use for {EscalationMinutes} min. Click Accept to acknowledge, or close ANSYS to stop billing."*
- Button: `Accept - keep using elastic`
- Audio: `ms-winsoundevent:Notification.Looping.Alarm2` (loops while toast on screen)
- Scenario: `Reminder` (sticky in Action Center, does not auto-dismiss)
- Body click: snooze 5 min (not full session silence)

## Toast click handling

Toast button click triggers the custom URL `ansyselastic:<action>?session=<urlencoded-key>`. Resolution chain:

1. Windows looks up `ansyselastic:` in `HKCU:\Software\Classes\ansyselastic\shell\open\command`
2. Launches `wscript.exe "<install>\toast-callback.vbs" "<url>"` (wscript.exe is windowless)
3. The .vbs uses `Shell.Run` with `showWindow=0` to spawn `powershell.exe ... toast-callback.ps1 <url>` invisibly
4. PowerShell parses URL, writes a JSONL line to `toast-queue.jsonl`
5. Agent main loop drains queue on next iteration, applies action to session state

The .vbs shim exists to avoid the brief console flash that `powershell.exe -WindowStyle Hidden` still produces.

| Action | Source | Effect |
|---|---|---|
| `got_it` | Toast 1 button or body | Log only, no state change |
| `suppress` | Toast 1 button | state -> SUPPRESSED |
| `accept` | Toast 2 button | state -> SUPPRESSED |
| `snooze` | Toast 2 body click | `next_prompt_at` = now + 5 min |

## Install / uninstall

Two paths — the .exe installer for end users, the raw .ps1 for development.

### End-user path (Inno Setup .exe)

Hand the user `dist\AnsysElasticLicenceMonitor-Setup.exe` (built per "Building the installer" below). Double-click. The installer is currently **unsigned**, so Windows SmartScreen will pop up — click **More info → Run anyway**. No admin prompt; this is a per-user install. After it finishes the agent is already running.

To uninstall: Settings → Apps → "Ansys Elastic Licence Monitor" → Uninstall. Or `appwiz.cpl`.

### Dev path (raw scripts)

```powershell
powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\install.ps1
```

`install.ps1`:

1. Creates `%LOCALAPPDATA%\AnsysElasticLicenceMonitor\`
2. Copies the agent files from the source folder
3. Installs BurntToast (PowerShell Gallery, CurrentUser scope, no admin needed)
4. Registers scheduled task: At Logon, current user, hidden window, restart on failure
5. Registers `ansyselastic:` URL protocol in HKCU
6. Starts the task immediately so the user does not have to log out / back in

`uninstall.ps1`:

1. Stops and unregisters the scheduled task
2. Kills any running `agent.ps1` instances
3. Removes the `ansyselastic:` registry key
4. Removes the install directory (logs and state) — unless `-SkipDirRemoval` is set, in which case the caller (Inno) is expected to do it
5. Leaves the BurntToast module installed

## Building the installer

Requires [Inno Setup 6](https://jrsoftware.org/isdl.php) on the build machine. Easiest install: `winget install JRSoftware.InnoSetup` (per-user; ISCC ends up at `%LOCALAPPDATA%\Programs\Inno Setup 6\ISCC.exe`).

```powershell
& "$env:LOCALAPPDATA\Programs\Inno Setup 6\ISCC.exe" .\installer.iss
```

Output: `.\dist\AnsysElasticLicenceMonitor-Setup.exe` (~2 MB). Bump `AppVersion` in `installer.iss` for each release; **do not change `AppId`** (that GUID identifies the app for upgrade detection on installed machines forever).

## Testing without installing

```powershell
# 1. Regex against the fixture
powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\test-parser.ps1

# 2. lmutil + perpetual context parsing against your live licence server
#    (requires a configured config.json pointing at your FlexLM server)
powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\test-perpetual.ps1

# 3. Run the agent in the foreground (Ctrl+C to stop)
powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\agent.ps1 `
    -PollIntervalSeconds 5 -EscalationMinutes 1 -ElasticDetectionThresholdSec 30

# 4. In another window, tail the agent log
Get-Content "$env:LOCALAPPDATA\AnsysElasticLicenceMonitor\agent.log" -Wait -Tail 30

# 5. Open ANSYS Discovery (or Workbench and run a Solve with >4 cores).
#    Within ~threshold seconds of the first sustained elastic checkout, toast 1 fires.
#    1 minute later, toast 2 fires (sticky reminder with Accept).
```

For a clean test (wipes prior state):

```powershell
Remove-Item "$env:LOCALAPPDATA\AnsysElasticLicenceMonitor\state.json" -ErrorAction SilentlyContinue
```

## Roadmap

| Item | Notes |
|---|---|
| Code signing | First-launch SmartScreen friction is the biggest UX issue. EV cert + signtool integration in the build. |
| BurntToast offline bundle | `install.ps1` still pulls BurntToast from PSGallery. For locked-down or offline machines, bundle the module locally and have install.ps1 prefer the local copy. |
| Periodic central-config refresh | Currently startup-only. If users complain about restart-to-see-config-change being slow, add an N-hour refresh loop in `agent.ps1`. |
| Cost annotation in toasts | Requires the ANSYS consumption rate table (AEU/hr per feature) plus your $/AEU contracted figure plus a name mapping from ACL feature names to rate-table feature names. |
| Hero image / colour emoji in toasts | BurntToast supports `New-BTImage` for hero images. Text styling is locked by Windows but emoji ship their own colour. |
| WPF dialog as toast 2 alternative | If toast prominence proves insufficient. Real window, any colour, can take focus. ~50 lines. |

## Known limitations

- BurntToast `-OnActivatedAction` is unreliable across BurntToast versions. We use protocol activation via `ansyselastic:` URLs instead, which works on every version that supports `New-BTButton -ActivationType Protocol`.
- ACL log discovery uses `Get-CimInstance Win32_Process` filtered to `ansyscl.exe`. If ANSYS ever renames or relocates this client, the regex in `Get-ActiveAnsysclSessions` (in `common.ps1`) will need updating.
- The agent does not capture pre-existing elastic checkouts from sessions running at the time of first install — by design, retroactive toast-bombing is worse UX. Closing and reopening the ANSYS app gets the agent into the cold path.
- Multiple concurrent ANSYS sessions on the same machine each get their own session key and independent state machine. Tested with one session; multi-session behaviour is correct by design.

## Licence

Copyright (c) 2026 Arron Craig.

This program is free software: you can redistribute it and/or modify it under the terms of the **GNU General Public License v3** as published by the Free Software Foundation, either version 3 of the License, or (at your option) any later version. See [`LICENSE`](LICENSE) for the full text.

This program is distributed in the hope that it will be useful, but **WITHOUT ANY WARRANTY**; without even the implied warranty of merchantability or fitness for a particular purpose.

ANSYS, Workbench, Mechanical, Discovery, Fluent, and related product names are trademarks of Ansys, Inc. This project is not affiliated with, endorsed by, or connected to Ansys, Inc. — it is an independent third-party tool.
