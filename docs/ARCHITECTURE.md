# Architecture

The technical context behind *Ansys Elastic Licence Monitor*: what the agent detects, why detection has to live on the workstation rather than the licence server, the dead ends investigated and ruled out, and the contracts between moving parts.

If you are forking this for a different site, this is the document to read first.

---

## 1. The problem

ANSYS workstations typically draw on two licence pools:

- **Perpetual / FlexLM (FNP).** Local FlexNet server you own. Concurrent-user model, fixed cost.
- **Elastic / web-elastic / LaaS.** Ansys cloud, pay-as-you-go in AEUs (Ansys Elastic Units) per hour of use.

When a perpetual feature is unavailable (held by another user, not in your perpetual pool, or the local server is unreachable), the client silently falls back to elastic. **The user is given no indication.** Workbench, Mechanical, Discovery, and Fluent all behave the same way — a paid feature is checked out from the cloud, billed per hour, and surfaces nowhere in the UI.

The result is invisible AEU spend that only becomes visible on the next monthly invoice from your reseller. This agent re-introduces the missing friction: a Windows toast appears when an elastic feature is checked out, and reappears periodically until the user acknowledges it or closes ANSYS.

---

## 2. The detection signal

**Every Workbench session spawns its own `ansyscl.exe`** (Ansys Client Licensing) which writes a per-session log file. This log is the authoritative record of what the session checked out and from where.

### Log file location

```
%LOCALAPPDATA%\Temp\.ansys\ansyscl.<HOSTNAME>.<PID1>.<PID2>.log
```

`PID1` is the parent Workbench process (`AnsysFWW.exe`). `PID2` appears to be a session correlation ID. One log file per Workbench session.

### Log file format (from the file's own header)

```
TIMESTAMP    ACTION    FEATURE    REVISION (BUILD DATE)    A/B/C/D    PID:MPID:APP:USER@HOST:PLATFORM:DISPLAY

A = number of licenses requested by this ACTION
B = number of licenses used by this USER
C = number of licenses used by all users
D = number of licenses available in the local license pool
```

### The `(elastic)` tag

**Elastic checkouts are explicitly tagged in the log.** Compare:

```
2026/05/08 13:10:11    CHECKOUT    mech_1    25.1 (2024.1030)    1/1/1/1   13164:35872:MECH:user@HOST:1:console
2026/05/08 13:10:28    CHECKOUT    rdpara (elastic)    25.1 (2024.1030)    1/1/1/1   13164:35872:PARTMGR:user@HOST:1:console
2026/05/08 13:23:58    SPLIT_CHECKOUT    anshpc (elastic)    25.1 (2024.1030)    4/4/4/4   44116:35872:ANSYS:user@HOST:1:console
```

`mech_1` (perpetual) carries no tag. `rdpara` and `anshpc` (elastic) are explicitly tagged. Detection reduces to a regex problem.

### Validated regex (Python form)

```python
import re

ELASTIC_CHECKOUT = re.compile(
    r'^(?P<ts>\d{4}/\d{2}/\d{2} \d{2}:\d{2}:\d{2})\s+'
    r'(?P<action>CHECKOUT|SPLIT_CHECKOUT|CHECKIN)\s+'
    r'(?P<feature>\S+)\s+\(elastic\)\s+'
    r'.*?(?P<a>\d+)/(?P<b>\d+)/(?P<c>\d+)/(?P<d>\d+)\s+'
    r'\d+:\d+:[^:]+:(?P<user>[^@]+)@(?P<host>\S+)'
)
```

### Validated regex (PowerShell form, what the agent actually uses)

```powershell
$pattern = '^(?<ts>\d{4}/\d{2}/\d{2} \d{2}:\d{2}:\d{2})\s+' +
           '(?<action>CHECKOUT|SPLIT_CHECKOUT|CHECKIN)\s+' +
           '(?<feature>\S+)\s+\(elastic\)\s+' +
           '.*?(?<a>\d+)/(?<b>\d+)/(?<c>\d+)/(?<d>\d+)\s+' +
           '\d+:\d+:[^:]+:(?<user>[^@]+)@(?<host>\S+)'
```

The two are equivalent. If you change one, change both, then run `test-parser.ps1`.

### Process tree

```
AnsysFWW.exe (Workbench Framework)         <- session root
├── ansyscl.exe (Ansys Client Licensing)   <- writes the log
├── AnsysWBU.exe (Mechanical)               <- per-app
└── ANSYS.exe -dis -np 8 -p mech_1 (x8)    <- solver processes (distributed)
```

`ansyscl.exe` is launched with `-log <path>` visible in `Win32_Process.CommandLine`. The agent enumerates ansyscl.exe processes by name and parses `-log` to deterministically locate the active log file. No directory polling required.

---

## 3. Why server-side detection is impossible

`ansyscl.exe` talks to FlexLM (perpetual) and the Ansys cloud (elastic) directly. **The local FlexLM server has no visibility into elastic checkouts.** Server-side aggregation of the local FlexLM debug log will only ever show you perpetual activity. There is no `lmstat`-equivalent for elastic.

Detection must be workstation-side. Detection of *embedded* feature checkouts (e.g. `anshpc` triggered by clicking Solve with >4 cores in the middle of an existing Mechanical session) similarly cannot be intercepted at app launch — the elastic feature is pulled mid-session by the solver, well after Workbench started.

---

## 4. Architecture

```
[at user logon]
   │
   ▼
[Scheduled Task: At Logon, current user, hidden window]
   │
   ▼
[agent.ps1 main loop, every $PollIntervalSeconds]
   │
   ├── enumerate ansyscl.exe via Win32_Process; parse -log <path>
   ├── for each active session: tail the ACL log incrementally (byte-offset state)
   ├── match the elastic regex; update per-session held_elastic set
   ├── if any feature held >= $ElasticDetectionThresholdSec and state==NEW: fire toast 1
   ├── if state==NOTIFIED and timer expired: fire toast 2; re-arm
   ├── drain toast-queue.jsonl from URL-protocol callbacks; apply state changes
   └── save state.json
```

Session key: `<host>.<pid1>.<pid2>` from the ACL log filename. Persists across agent restarts.

### State machine

| State | Entry condition | Exits to |
|---|---|---|
| `NEW` | session detected | `NOTIFIED` (sustained-elastic threshold reached) |
| `NOTIFIED` | toast 1 fired | `NOTIFIED` (timer re-arm), `SUPPRESSED` (suppress/accept), removed (ansyscl.exe exits) |
| `SUPPRESSED` | "Don't bug me this session" or "Accept" clicked | only by removal |

`held_elastic` is a per-session map of `feature -> ISO8601 timestamp the agent first saw the checkout`. Updated on every `CHECKOUT`/`SPLIT_CHECKOUT` (add) and `CHECKIN` (remove). The threshold gate (`ElasticDetectionThresholdSec`, default 30s) uses the oldest entry's age to decide whether to fire toast 1 — this filters transient features like `rdpara` that check out for a few seconds on Workbench open and release before the user could meaningfully act on them.

### Toast click chain

BurntToast buttons can only invoke `-ActivationType Protocol` URLs, which means the click handler must be a registered Windows URL-scheme handler, not in-process code. The chain:

1. Toast button click triggers `ansyselastic:<action>?session=<urlencoded-key>`
2. Windows looks up `HKCU:\Software\Classes\ansyselastic\shell\open\command`
3. Launches `wscript.exe "<install>\toast-callback.vbs" "<url>"` (wscript runs the .vbs without a window)
4. The .vbs uses `Shell.Run` with `showWindow=0` to spawn `powershell.exe ... toast-callback.ps1 <url>` invisibly
5. PowerShell parses the URL, writes a JSONL line to `toast-queue.jsonl`
6. Agent main loop drains the queue on the next iteration and applies the action to session state

The .vbs shim exists to avoid the brief console flash that `powershell.exe -WindowStyle Hidden` still produces on click. The queue file exists because the click handler runs in a transient process and cannot mutate the long-running agent's in-memory state directly.

### Configuration

Two-tier config load at agent startup:

1. **Bundled `config.json`** next to `common.ps1` — the always-present defaults shipped with the installer. Empty out of the box; detection works without it.
2. **Central config** at a URL or path read from `config-source.txt` — optional, set during install via the wizard. Layered over tier 1 (any field present wins).

The central source is intended for fleet deployments where you'd rather edit one file on Egnyte / SharePoint / a network share than maintain `config.json` on every workstation. If the central source is unreachable or malformed, the agent logs WARN and uses tier 1 — detection always works.

There is no auto-refresh during the agent loop; central config is read once at startup. To propagate a change, users restart the scheduled task (or their machines). See README "Configuration" for the key reference and the install-time wizard.

---

## 5. Dead ends — don't repeat these

The most useful section for forkers. Each item below was investigated and ruled out during the original build. Future contributors should not re-investigate any of these.

### 5.1 No public Ansys Licensing Portal API

`licensing.ansys.com` has no documented REST API, no OAuth flow, no webhooks. The portal is a JavaScript SPA backed by undocumented HTTP endpoints that could be reverse-engineered, but doing so is fragile and likely outside the licensing T&Cs. Don't pursue it.

### 5.2 15-minute lag in portal data

Even if a portal API existed, Ansys explicitly state: *"It takes approximately 15 minutes for usage logs to be displayed in the Ansys Licensing Portal."* That rules out the portal as a real-time signal anyway.

### 5.3 `ansysli_util -liusage` does not work in 2021 R1+

In Ansys 2021 R1+ the standalone `ansysli_server` daemon was replaced with `ansyscl.exe` running as a child of each application process. `ansysli_util -liusage` returns "Unable to retrieve usage" because it tries to query a daemon that does not exist. Do not build anything that depends on `ansysli_util -liusage`.

### 5.4 Launcher-wrapper friction approach

Idea: replace Start Menu shortcuts with a wrapper that pops "this costs money" before launching the real .exe. **Rejected** because elastic features are checked out *mid-session*. A user opens Workbench (free), launches Mechanical (free perpetual `mech_1`), then clicks Solve with 8 cores — `anshpc (elastic)` is pulled mid-session by the solver. There is no app launch to intercept. Wrappers would only catch a small fraction of cases.

### 5.5 `ANSYSLI_CLIENT_IDLE_TIMEOUT` environment variable

This appears in the ACL log header as `INFO ANSYSLI_CLIENT_IDLE_TIMEOUT=0` and looks like a configurable client setting. **It is not.** It is informational only. The actual Ansys idle timeout is:
- A server-side feature configured via `ansyslmd.opt` options file
- Requires a `TIMEOUT` increment in the licence file (purchased separately, contact your Ansys account manager)
- Has a hardcoded minimum effective duration of 75 minutes (900s heartbeat + 3600s minimum timeout)
- Only supported by specific Ansys products
- May or may not work on elastic features (unconfirmed by Ansys docs at time of writing)

If your site has the TIMEOUT increment, that is a complementary fix for overnight burn — independent of this agent.

### 5.6 Cost data is not in the local logs

The ACL log records *what* was checked out (`anshpc (elastic)` x4) but not *how much* it cost. AEU consumption rates per feature live in an Ansys consumption rate table that is updated periodically. Real-time cost annotation in toasts requires:
1. Manual ingestion of the consumption rate table (one-off, then maintained per release)
2. Your contracted $/AEU rate
3. A mapping from ACL log feature names to rate-table feature names

This is intentionally out of scope for the agent itself. A reasonable longer-term path is to reconcile the agent's elastic-event log against the licensing portal's Summary Statements report (24-hour lag, but authoritative cost).

### 5.7 lmgrd debug log is not persistent by default

There is no `license.log` actively being written to disk on a default Ansys License Manager install. The file exists conceptually inside lmgrd's memory and is materialised on demand via the License Management Center web UI. Backups exist in `logs_backup\` from prior service stop events. Persistent debug logging requires the `-l <path>` argument to `lmgrd.exe` (set in the service ImagePath). The agent does not depend on this.

### 5.8 Workstation FlexNet debug log path

There is no separate FlexNet debug log on the workstation. The ACL log (`%LOCALAPPDATA%\Temp\.ansys\ansyscl.*.log`) is the only client-side log of licensing activity. `lmutil` exists on the workstation but only queries server state, not client transactions.

---

## 6. Architectural constraints worth knowing

- **Elastic traffic bypasses the local server.** Server-side detection of elastic is impossible.
- **Embedded feature checkouts cannot be intercepted at launch.** Elastic features get pulled mid-session by user actions inside the running ANSYS app.
- **Zero-friction install required.** This is a per-user agent and must deploy without admin rights, manual config, or admin tickets. The current implementation registers a per-user scheduled task at `LogonType Interactive, RunLevel Limited` — toasts only render in an interactive desktop session, so a SYSTEM-level service would silently fail to notify.
- **Idle timeout might be unavailable for elastic.** Even if your contract includes the TIMEOUT increment, it may only apply to perpetual features. The agent design does not assume idle timeout will solve overnight elastic burn.

---

## 7. Glossary

- **ACL** — Ansys Common Licensing. The 2021R1+ replacement for the Licensing Interconnect. Runs as a child process (`ansyscl.exe`) of each Ansys application session.
- **AEU** — Ansys Elastic Unit. The pre-paid currency for elastic licensing. Consumed at feature-specific rates per hour.
- **CLS** — Cloud License Server. The Ansys-hosted server that issues elastic licences.
- **CLSID** — Cloud License Server ID. Unique identifier for a customer's CLS account.
- **FlexLM / FlexNet Publisher** — The third-party licence-management framework Ansys uses for perpetual licensing.
- **LMC** — License Management Center. The Tomcat-hosted web UI (port 1084) on the licence server for admin tasks.
- **lmgrd** — FlexNet's licence manager daemon.
- **ansyslmd** — Ansys's vendor daemon, child of lmgrd, handles Ansys-specific licence requests.
- **Perpetual / FlexLM / FNP** — Local, owned licences. Concurrent-user model.
- **Elastic / web-elastic / LaaS** — Cloud, pay-as-you-go licences. Per-hour AEU consumption.
- **TIMEOUT increment** — A licence-file feature that enables idle timeout. Purchased separately from Ansys.
