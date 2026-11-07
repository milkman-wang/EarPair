; EarPair installer (Inno Setup 6). build.ps1 compiles it once per runtime:
;   ISCC /DAppVersion=0.2.0 /DArch=win-x64 /DSourceDir=<publish folder> /DOutputDir=<dist> EarPair.iss
; Installs for the current user only (no administrator rights) into %LOCALAPPDATA%\Programs\EarPair,
; adds a Start menu shortcut and an uninstaller, and follows the Windows display language
; (English or Simplified Chinese, like the app).

#ifndef AppVersion
  #error Pass /DAppVersion=<version>
#endif
#ifndef Arch
  #error Pass /DArch=win-x64 or /DArch=win-arm64
#endif
#ifndef SourceDir
  #error Pass /DSourceDir=<publish folder>
#endif
#ifndef OutputDir
  #define OutputDir "."
#endif

#if Arch == "win-arm64"
  #define Architectures "arm64"
#elif Arch == "win-x64"
  #define Architectures "x64compatible"
#else
  #error Arch must be win-x64 or win-arm64
#endif

[Setup]
; Never change AppId: upgrades and the uninstaller find the installed copy by it
AppId={{6C1B2E6A-6F4D-4C4B-9E4E-3E5A0B7D2F11}
AppName=EarPair
AppVersion={#AppVersion}
AppVerName=EarPair {#AppVersion}
AppPublisherURL=https://github.com/milkman-wang/EarPair
VersionInfoVersion={#AppVersion}
PrivilegesRequired=lowest
DefaultDirName={autopf}\EarPair
DisableDirPage=yes
DisableProgramGroupPage=yes
DisableReadyPage=yes
ArchitecturesAllowed={#Architectures}
ArchitecturesInstallIn64BitMode={#Architectures}
MinVersion=10.0.19041
; EarPair keeps running in the notification area after its window closes. PrepareToInstall closes it
; itself (quickly, and without the "applications are using files" page); the Restart Manager stays as a
; fallback for anything else holding the files.
CloseApplications=force
RestartApplications=no
SetupIconFile={#SourcePath}..\EarPair.App\Assets\EarPair.ico
UninstallDisplayIcon={app}\EarPair.exe
UninstallDisplayName=EarPair
WizardStyle=modern
ShowLanguageDialog=no
Compression=lzma2/max
SolidCompression=yes
OutputDir={#OutputDir}
OutputBaseFilename=EarPair-{#AppVersion}-{#Arch}-setup

[Languages]
Name: "en"; MessagesFile: "compiler:Default.isl"
; Inno Setup ships no Simplified Chinese: ours only overrides the messages EarPair's setup shows
Name: "zhHans"; MessagesFile: "compiler:Default.isl,ChineseSimplified.isl"

[Messages]
; The Install button says it already
ReadyLabel2b=

[InstallDelete]
; Upgrades start from an empty folder, so files a newer version no longer ships don't linger
Type: filesandordirs; Name: "{app}\*"

[Files]
Source: "{#SourceDir}\*"; DestDir: "{app}"; Flags: ignoreversion recursesubdirs createallsubdirs

[Icons]
Name: "{autoprograms}\EarPair"; Filename: "{app}\EarPair.exe"

[Registry]
; Start at login lives in the Run key (written by the app); remove it with the app
Root: HKCU; Subkey: "Software\Microsoft\Windows\CurrentVersion\Run"; ValueName: "EarPair"; ValueType: none; Flags: uninsdeletevalue dontcreatekey
Root: HKCU; Subkey: "Software\Microsoft\Windows\CurrentVersion\Explorer\StartupApproved\Run"; ValueName: "EarPair"; ValueType: none; Flags: uninsdeletevalue dontcreatekey

[Run]
Filename: "{app}\EarPair.exe"; Description: "{cm:LaunchProgram,EarPair}"; Flags: nowait postinstall skipifsilent
; Silent installs (EarPair's own updater passes /SILENT /RELAUNCH=1) start EarPair again when it was
; running before, so an update picks up where it left off
Filename: "{app}\EarPair.exe"; Flags: nowait; Check: RelaunchAfterSilentInstall

[Code]
const
  WM_QUERYENDSESSION = $0011;
  WM_ENDSESSION = $0016;
  ENDSESSION_CLOSEAPP = 1;

var
  EarPairWasRunning: Boolean;

// EarPair keeps running in the notification area. Ask it to quit the way the Restart Manager does:
// it stops sending, unmutes the PC's speakers and exits (0.2.1 and earlier only stop and stay open).
// Wait up to 3 seconds for its tray window to go, then end the process so its files can be replaced.
procedure CloseEarPair();
var
  Wnd: HWND;
  I, ResultCode: Integer;
begin
  Wnd := FindWindowByClassName('EarPairTrayWindow');
  if Wnd = 0 then
    Exit;
  Log('EarPair is running: asking it to close');
  SendMessage(Wnd, WM_QUERYENDSESSION, 0, ENDSESSION_CLOSEAPP);
  SendMessage(Wnd, WM_ENDSESSION, 1, ENDSESSION_CLOSEAPP);
  for I := 1 to 30 do
  begin
    if FindWindowByClassName('EarPairTrayWindow') = 0 then
      Break;
    Sleep(100);
  end;
  if FindWindowByClassName('EarPairTrayWindow') = 0 then
    Log('EarPair closed')
  else
    Log('EarPair is still running after 3 seconds');
  // Also ends a process that is still on its way out, or a second copy
  Exec(ExpandConstant('{sys}\taskkill.exe'), '/F /IM EarPair.exe', '', SW_HIDE, ewWaitUntilTerminated, ResultCode);
  Log(Format('taskkill: %d', [ResultCode]));
  // Give Windows a moment to release the files
  Sleep(500);
end;

// Before the Restart Manager looks for programs using the files: close EarPair ourselves, so setup
// neither shows the "close applications" page nor waits for EarPair to time out
function PrepareToInstall(var NeedsRestart: Boolean): String;
begin
  EarPairWasRunning := FindWindowByClassName('EarPairTrayWindow') <> 0;
  CloseEarPair();
  Result := '';
end;

function RelaunchAfterSilentInstall(): Boolean;
begin
  Result := WizardSilent() and (EarPairWasRunning or (ExpandConstant('{param:relaunch|0}') = '1'));
end;

function InitializeUninstall(): Boolean;
begin
  CloseEarPair();
  Result := True;
end;
