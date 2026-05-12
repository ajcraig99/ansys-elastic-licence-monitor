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

; Single source of truth for the agent version: VERSION file at repo root.
; Read once at compile time; agent.ps1 / Get-AgentVersion reads it at runtime.
#define VersionFileHandle FileOpen("VERSION")
#define AppVer Trim(FileRead(VersionFileHandle))
#expr FileClose(VersionFileHandle)

[Setup]
; AppId is fixed forever -- changing it breaks upgrade detection on installed machines.
AppId={{FD570A3F-0D93-4A09-BACD-F5F99D919EBB}
AppName=Ansys Elastic Licence Monitor
AppVersion={#AppVer}
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
Source: "VERSION";            DestDir: "{app}"; Flags: ignoreversion
; config.json: onlyifdoesntexist preserves admin/user edits across upgrades.
; A reinstall over the top will NOT clobber a customised config. To force
; replacement, uninstall first (which wipes {app}) then re-run setup.
Source: "config.json";        DestDir: "{app}"; Flags: onlyifdoesntexist

[Messages]
; Override the default "Setup has finished installing X. Click Finish." with
; something that explains what to do, not just that it ran. The headline is
; the big text at the top of the finish page; FinishedLabel is the body.
FinishedHeadingLabel=Ansys Elastic Licence Monitor is running
FinishedLabel=When a paid ANSYS elastic licence is checked out, a Windows toast notification will appear.%n%nWhat to do when you see it:%n  - Close ANSYS to switch back to the perpetual (free) licence, OR%n  - Click "Keep billing me" to continue and accept the cost.%n%nEach hour of elastic use costs money. Closing ANSYS and reopening it is the free option.%n%nLogs: %localappdata%\AnsysElasticLicenceMonitor\agent.log%nUninstall: Settings -> Apps -> Ansys Elastic Licence Monitor

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
begin
  Path := Trim(ConfigSourcePage.Values[0]);
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
  // Local file only. HTTPS support was removed because the wizard prompt
  // confused non-technical users and the http:// fallback added a MITM
  // surface for no real benefit -- a network drive or UNC path works for
  // every fleet deployment.
  ConfigSourcePage := CreateInputQueryPage(
    wpSelectTasks,
    'Central configuration source',
    'Optional. Pick a shared config file your IT team gave you.',
    'If your IT team has provided a shared config file, click Browse to pick it. ' +
    'This lets them update everyone''s licence-server settings from one place.' + #13#10 + #13#10 +
    'If you weren''t given anything, just click Next -- the agent works fine without it. ' +
    'You won''t see the "perpetual is held by [user]" enrichment in the toast, but ' +
    'detection itself is unaffected.' + #13#10 + #13#10 +
    'Examples of valid locations:' + #13#10 +
    '  - Network drive: Z:\share\config.json' + #13#10 +
    '  - UNC path:      \\fileserver\share\config.json' + #13#10 +
    '  - Local file:    C:\path\config.json');
  ConfigSourcePage.Add('Config file (optional):', False);
  ConfigSourcePage.Values[0] := '{#DefaultConfigSource}';

  // Browse button. The text field still accepts UNC/mapped paths directly,
  // but Browse is the path of least resistance for the typical user.
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

function NextButtonClick(CurPageID: Integer): Boolean;
var
  ConfigSource, Lower: string;
begin
  Result := True;
  if CurPageID = ConfigSourcePage.ID then
  begin
    ConfigSource := Trim(ConfigSourcePage.Values[0]);
    if ConfigSource = '' then Exit;
    // Reject HTTP(S) URLs -- they used to be accepted, but the agent no
    // longer supports them. Catch it here rather than silently failing at
    // first run.
    Lower := LowerCase(ConfigSource);
    if (Pos('http://', Lower) = 1) or (Pos('https://', Lower) = 1) then
    begin
      MsgBox('HTTP and HTTPS URLs are no longer supported. ' +
             'Please pick a local file, network drive, or UNC path.' + #13#10 + #13#10 +
             'If you''re not sure what to do, leave the field blank and click Next.',
             mbError, MB_OK);
      Result := False;
    end;
  end;
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
