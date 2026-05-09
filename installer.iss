; Inno Setup script for Ansys Elastic Licence Monitor.
; Compile with: ISCC.exe installer.iss   (output -> dist\AnsysElasticLicenceMonitor-Setup.exe)
;
; This wrapper is a thin file-delivery + invocation shell over install.ps1 /
; uninstall.ps1, which remain the canonical install logic. The .exe is currently
; UNSIGNED -- testers will see SmartScreen "Windows protected your PC"; tell
; them to click "More info" -> "Run anyway".

[Setup]
; AppId is fixed forever -- changing it breaks upgrade detection on installed machines.
AppId={{FD570A3F-0D93-4A09-BACD-F5F99D919EBB}
AppName=Ansys Elastic Licence Monitor
AppVersion=1.0.0
AppPublisher=Arron Craig
AppPublisherURL=
AppSupportURL=
DefaultDirName={localappdata}\AnsysElasticLicenceMonitor
DefaultGroupName=AnsysElasticLicenceMonitor
DisableProgramGroupPage=yes
DisableDirPage=yes
DisableReadyPage=no
PrivilegesRequired=lowest
OutputDir=dist
OutputBaseFilename=AnsysElasticLicenceMonitor-Setup
Compression=lzma2
SolidCompression=yes
WizardStyle=modern
Uninstallable=yes
UsePreviousAppDir=yes
; CloseApplications=yes makes Inno detect file locks on agent.ps1 (running under
; powershell.exe) during upgrade and prompt the user. The standard upgrade path
; (Inno auto-invokes prior uninstaller, which kills the agent) usually beats it
; to the punch, but this is the belt-and-braces fallback for direct overwrites.
CloseApplications=yes
RestartApplications=no

[Files]
Source: "agent.ps1";          DestDir: "{app}"; Flags: ignoreversion
Source: "common.ps1";         DestDir: "{app}"; Flags: ignoreversion
Source: "install.ps1";        DestDir: "{app}"; Flags: ignoreversion
Source: "uninstall.ps1";      DestDir: "{app}"; Flags: ignoreversion
Source: "toast-callback.ps1"; DestDir: "{app}"; Flags: ignoreversion
Source: "toast-callback.vbs"; DestDir: "{app}"; Flags: ignoreversion
Source: "LICENSE";            DestDir: "{app}"; Flags: ignoreversion
; config.json: onlyifdoesntexist preserves admin/user edits across upgrades.
; A reinstall over the top will NOT clobber a customised config. To force
; replacement, uninstall first (which wipes {app}) then re-run setup.
Source: "config.json";        DestDir: "{app}"; Flags: onlyifdoesntexist

[Messages]
; Override the default "Setup has finished installing X. Click Finish." with
; something that confirms the agent is actually running and tells the user
; where to look. Heading is the big text at the top of the finish page;
; FinishedLabel is the body text below it.
FinishedHeadingLabel=Ansys Elastic Licence Monitor is running
FinishedLabel=The agent is now watching for ANSYS elastic licence checkouts. The next time you launch Workbench, Mechanical, or Discovery and a paid elastic feature is checked out, a Windows toast notification will appear.%n%nLogs: %localappdata%\AnsysElasticLicenceMonitor\agent.log%nConfig: %localappdata%\AnsysElasticLicenceMonitor\config.json%nUninstall: Settings -> Apps -> Ansys Elastic Licence Monitor

[Run]
; install.ps1 detects that source-dir == install-dir and skips its own copy
; step, then proceeds to install BurntToast, register the scheduled task,
; register the ansyselastic: protocol, and start the agent.
Filename: "powershell.exe"; \
  Parameters: "-NoProfile -ExecutionPolicy Bypass -File ""{app}\install.ps1"""; \
  Flags: runhidden waituntilterminated; \
  StatusMsg: "Registering scheduled task and starting agent..."

[UninstallRun]
; uninstall.ps1 -SkipDirRemoval kills the agent, unregisters the task and
; the URL protocol, but leaves {app} for Inno to wipe via [UninstallDelete].
Filename: "powershell.exe"; \
  Parameters: "-NoProfile -ExecutionPolicy Bypass -File ""{app}\uninstall.ps1"" -SkipDirRemoval"; \
  Flags: runhidden waituntilterminated; \
  RunOnceId: "AnsysElasticLicenceMonitorUninstall"

[UninstallDelete]
; Wipe agent.log, state.json, toast-queue.jsonl, and any rotated log backups
; that Inno did not put there itself.
Type: filesandordirs; Name: "{app}"
