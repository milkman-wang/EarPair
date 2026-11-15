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
; Installs for the current user without administrator rights by default; the first page offers
; "Install for all users" (Program Files, asks for administrator rights). Upgrades, EarPair's own silent
; updates included, keep the mode and folder of the previous install.
PrivilegesRequired=lowest
PrivilegesRequiredOverridesAllowed=dialog commandline
; The app's own settings (update checks, start at login) are per user even in an all-users install
UsedUserAreasWarning=no
DefaultDirName={autopf}\EarPair
; The folder page shows on the first install only. NextButtonClick checks the folder instead of
; Inno's "folder already exists" prompt
DisableDirPage=auto
DirExistsWarning=no
DisableProgramGroupPage=yes
DisableReadyPage=yes
; The update checkbox starts from the current setting, not from the previous install
UsePreviousTasks=no
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
Name: "en"; MessagesFile: "compiler:Default.isl"; InfoBeforeFile: "privacy-en.txt"
; Inno Setup ships no Simplified Chinese: ours only overrides the messages EarPair's setup shows
Name: "zhHans"; MessagesFile: "compiler:Default.isl,ChineseSimplified.isl"; InfoBeforeFile: "privacy-zh-Hans.txt"

[Messages]
; The Install button says it already
ReadyLabel2b=
; Two short pages before installing: how EarPair uses the network, and whether it may check for updates
en.WizardInfoBefore=Privacy
en.InfoBeforeLabel=How EarPair uses the network:
en.InfoBeforeClickLabel=
en.WizardSelectTasks=Updates
en.SelectTasksDesc=
en.SelectTasksLabel2=You can change this later in EarPair's window.
zhHans.WizardInfoBefore=隐私
zhHans.InfoBeforeLabel=EarPair 如何使用网络：
zhHans.InfoBeforeClickLabel=
zhHans.WizardSelectTasks=更新
zhHans.SelectTasksDesc=
zhHans.SelectTasksLabel2=以后可以在 EarPair 的窗口里修改。

[CustomMessages]
en.AutoCheckUpdates=Check for updates automatically
zhHans.AutoCheckUpdates=自动检查更新
en.FolderInUse=This folder already has other files in it. Choose an empty folder, or a new one.
zhHans.FolderInUse=这个文件夹里已经有别的文件。请选一个空文件夹，或者新建一个。
en.FolderNeedsAdmin=Setup can't write to this folder. Choose another one, or run setup again and choose "Install for all users".
zhHans.FolderNeedsAdmin=安装程序没有权限写入这个文件夹。请换一个，或者重新运行安装程序并选择“为所有用户安装”。
en.FolderNotWritable=Setup can't write to this folder. Choose another one.
zhHans.FolderNotWritable=安装程序无法写入这个文件夹。请换一个。

[Tasks]
Name: "autoupdate"; Description: "{cm:AutoCheckUpdates}"

[InstallDelete]
; Upgrades start from an empty folder, so files a newer version no longer ships don't linger. Only in a
; folder that holds EarPair: the folder can be chosen, and must never be someone else's
Type: filesandordirs; Name: "{app}\*"; Check: IsEarPairFolder

[Files]
Source: "{#SourceDir}\*"; DestDir: "{app}"; Flags: ignoreversion recursesubdirs createallsubdirs

[Icons]
Name: "{autoprograms}\EarPair"; Filename: "{app}\EarPair.exe"

[Registry]
; Start at login lives in the Run key (written by the app); remove it with the app
Root: HKCU; Subkey: "Software\Microsoft\Windows\CurrentVersion\Run"; ValueName: "EarPair"; ValueType: none; Flags: uninsdeletevalue dontcreatekey
Root: HKCU; Subkey: "Software\Microsoft\Windows\CurrentVersion\Explorer\StartupApproved\Run"; ValueName: "EarPair"; ValueType: none; Flags: uninsdeletevalue dontcreatekey
; Automatic update checks (read and changed by the app). Only an install you click through sets it:
; EarPair's own silent updates keep whatever was chosen in the app. The first line runs on every install,
; silent ones included, so the uninstaller always removes the key (each install starts from an empty
; folder, which drops the previous uninstall log)
Root: HKCU; Subkey: "Software\EarPair"; ValueType: none; Flags: uninsdeletekey
Root: HKCU; Subkey: "Software\EarPair"; ValueType: dword; ValueName: "AutoCheckUpdates"; ValueData: 1; Tasks: autoupdate; Check: not WizardSilent; Flags: uninsdeletekey
Root: HKCU; Subkey: "Software\EarPair"; ValueType: dword; ValueName: "AutoCheckUpdates"; ValueData: 0; Tasks: not autoupdate; Check: not WizardSilent; Flags: uninsdeletekey

[UninstallDelete]
; Logs and downloaded updates are EarPair's own leftovers; settings.json stays in case EarPair is installed again
Type: filesandordirs; Name: "{localappdata}\EarPair\logs"
Type: filesandordirs; Name: "{localappdata}\EarPair\updates"
; An upgrade empties the folder first, so the new uninstall log doesn't know setup created it: remove it
; here when nothing else is left in it
Type: dirifempty; Name: "{app}"

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

// The update checkbox shows the current setting (on when EarPair has never been set up)
procedure CurPageChanged(CurPageID: Integer);
var
  Value: Cardinal;
begin
  if (CurPageID = wpSelectTasks) and
     RegQueryDWordValue(HKEY_CURRENT_USER, 'Software\EarPair', 'AutoCheckUpdates', Value) then
    WizardForm.TasksList.Checked[0] := Value <> 0;
end;

function IsEarPairFolder(): Boolean;
begin
  Result := FileExists(ExpandConstant('{app}\EarPair.exe'));
end;

// The chosen folder exists and holds files that aren't EarPair's (upgrades empty the folder first)
function HasOtherFiles(Dir: String): Boolean;
var
  FindRec: TFindRec;
begin
  Result := False;
  if not DirExists(Dir) or FileExists(AddBackslash(Dir) + 'EarPair.exe') then
    Exit;
  if FindFirst(AddBackslash(Dir) + '*', FindRec) then
  begin
    try
      repeat
        if (FindRec.Name <> '.') and (FindRec.Name <> '..') then
          Result := True;
      until Result or not FindNext(FindRec);
    finally
      FindClose(FindRec);
    end;
  end;
end;

// Setup can create the folder and write in it. Tries it for real (a folder in C:\ can be made without
// administrator rights, a file there can't), then removes whatever it made
function CanWriteTo(Dir: String): Boolean;
var
  Existing, Parent, Probe: String;
begin
  Result := False;
  Existing := RemoveBackslashUnlessRoot(Dir);
  while not DirExists(Existing) do
  begin
    Parent := ExtractFileDir(Existing);
    if Parent = Existing then
      Exit;
    Existing := Parent;
  end;
  if ForceDirectories(Dir) then
  begin
    Probe := AddBackslash(Dir) + 'EarPair-setup-test.tmp';
    Result := SaveStringToFile(Probe, '', False);
    DeleteFile(Probe);
  end;
  Dir := RemoveBackslashUnlessRoot(Dir);
  while (Length(Dir) > Length(Existing)) and RemoveDir(Dir) do
    Dir := ExtractFileDir(Dir);
end;

function NextButtonClick(CurPageID: Integer): Boolean;
begin
  Result := True;
  if CurPageID <> wpSelectDir then
    Exit;
  if HasOtherFiles(WizardDirValue) then
  begin
    MsgBox(CustomMessage('FolderInUse'), mbError, MB_OK);
    Result := False;
  end
  else if not CanWriteTo(WizardDirValue) then
  begin
    if IsAdminInstallMode then
      MsgBox(CustomMessage('FolderNotWritable'), mbError, MB_OK)
    else
      MsgBox(CustomMessage('FolderNeedsAdmin'), mbError, MB_OK);
    Result := False;
  end;
end;

function InitializeUninstall(): Boolean;
begin
  CloseEarPair();
  Result := True;
end;
