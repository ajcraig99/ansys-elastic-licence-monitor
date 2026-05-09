; Inno Setup script for Ansys Elastic Licence Monitor.
; Compile with: ISCC.exe installer.iss   (output -> dist\AnsysElasticLicenceMonitor-Setup.exe)
;
; To pre-fill the "Central config location" wizard prompt for an internal build,
; either:
;
;   1. Drop a build-config.iss file (gitignored) next to installer.iss containing:
;        #define DefaultConfigSource "G:\path\to\config.json"
;      Then run: ISCC.exe installer.iss
;
;   2. Pass on the ISCC command line:
;        ISCC.exe /DDefaultConfigSource="\\fileserver\share\config.json" installer.iss
;
; The default value is baked into the .exe but is NOT in the public source.
; Public builds (no build-config.iss, no /D switch) ship with an empty default.
;
; This wrapper is a thin file-delivery + invocation shell over install.ps1 /
; uninstall.ps1, which remain the canonical install logic. The .exe is currently
; UNSIGNED -- testers will see SmartScreen "Windows protected your PC"; tell
; them to click "More info" -> "Run anyway".

#if FileExists("build-config.iss")
  #include "build-config.iss"
#endif

#ifndef DefaultConfigSource
  #define DefaultConfigSource ""
#endif

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

[Code]
var
  ConfigSourcePage: TInputQueryWizardPage;
  BrowseButton: TButton;

procedure BrowseButtonClick(Sender: TObject);
var
  Path: string;
  Lower: string;
begin
  Path := Trim(ConfigSourcePage.Values[0]);
  // Don't pre-populate the dialog if the current value is a URL --
  // the file picker can't navigate there and would just confuse Windows.
  Lower := LowerCase(Path);
  if (Pos('http://', Lower) = 1) or (Pos('https://', Lower) = 1) then
    Path := '';
  if GetOpenFileName(
       'Select central config file',
       Path,
       '',
       'JSON files (*.json)|*.json|All files (*.*)|*.*',
       'json') then
    ConfigSourcePage.Values[0] := Path;
end;

procedure InitializeWizard();
var
  EditWidth: Integer;
  ButtonWidth: Integer;
  Gap: Integer;
begin
  ConfigSourcePage := CreateInputQueryPage(
    wpSelectTasks,
    'Central configuration source',
    'Where should the agent fetch its site-specific configuration from?',
    'Optional. Enter a URL or path to a JSON file containing site-specific overrides ' +
    '(licence server, perpetual feature list, display names). The agent reads this ' +
    'once at startup, falling back to the bundled defaults on failure.' + #13#10 + #13#10 +
    'Supported formats:' + #13#10 +
    '  - HTTPS URL:    https://example.com/config.json' + #13#10 +
    '  - Mapped drive: Z:\share\config.json' + #13#10 +
    '  - UNC path:     \\fileserver\share\config.json' + #13#10 +
    '  - Local file:   C:\path\config.json' + #13#10 + #13#10 +
    'Click Browse to pick a file; for a URL, just type or paste it. Leave blank ' +
    'to use bundled defaults only.');
  ConfigSourcePage.Add('Config source (optional):', False);
  ConfigSourcePage.Values[0] := '{#DefaultConfigSource}';

  // Add a Browse button to the right of the edit. The text field still works
  // for URLs (which a file picker can't navigate), so the button is a
  // convenience for the local/UNC/mapped-drive case, not the only path in.
  ButtonWidth := ScaleX(75);
  Gap := ScaleX(8);
  EditWidth := ConfigSourcePage.Edits[0].Width - ButtonWidth - Gap;

  BrowseButton := TButton.Create(ConfigSourcePage);
  BrowseButton.Parent  := ConfigSourcePage.Surface;
  BrowseButton.Caption := 'Browse...';
  BrowseButton.Width   := ButtonWidth;
  BrowseButton.Height  := ScaleY(23);
  BrowseButton.Top     := ConfigSourcePage.Edits[0].Top - ScaleY(1);
  BrowseButton.Left    := ConfigSourcePage.Edits[0].Left + EditWidth + Gap;
  BrowseButton.OnClick := @BrowseButtonClick;

  ConfigSourcePage.Edits[0].Width := EditWidth;
end;

procedure CurStepChanged(CurStep: TSetupStep);
var
  ConfigSource: string;
  SourceFilePath: string;
begin
  if CurStep = ssPostInstall then
  begin
    ConfigSource := Trim(ConfigSourcePage.Values[0]);
    SourceFilePath := ExpandConstant('{app}\config-source.txt');
    // Always write the file (possibly empty) so a re-install with a cleared
    // value reliably wipes a previous setting.
    SaveStringToFile(SourceFilePath, ConfigSource, False);
  end;
end;
