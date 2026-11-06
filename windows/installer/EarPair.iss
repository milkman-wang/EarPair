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
; EarPair keeps running in the notification area after its window closes: close it before replacing files
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

[Code]
const
  WM_QUERYENDSESSION = $0011;
  WM_ENDSESSION = $0016;
  ENDSESSION_CLOSEAPP = 1;

// EarPair keeps running in the notification area, and the uninstaller doesn't close programs by
// itself. Ask it to quit the way Windows does at sign-out (it stops sending and unmutes the PC's
// speakers), then end the process so its files can be removed.
procedure CloseEarPair();
var
  Wnd: HWND;
  ResultCode: Integer;
begin
  Wnd := FindWindowByClassName('EarPairTrayWindow');
  if Wnd = 0 then
    Exit;
  SendMessage(Wnd, WM_QUERYENDSESSION, 0, ENDSESSION_CLOSEAPP);
  SendMessage(Wnd, WM_ENDSESSION, 1, ENDSESSION_CLOSEAPP);
  Exec(ExpandConstant('{sys}\taskkill.exe'), '/F /IM EarPair.exe', '', SW_HIDE, ewWaitUntilTerminated, ResultCode);
  // Give Windows a moment to release the files
  Sleep(1000);
end;

function InitializeUninstall(): Boolean;
begin
  CloseEarPair();
  Result := True;
end;
