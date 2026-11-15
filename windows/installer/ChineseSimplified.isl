; Simplified Chinese for the EarPair installer. Loaded on top of Default.isl
; (MessagesFile: "compiler:Default.isl,ChineseSimplified.isl"), so it only lists the messages
; that can show up with EarPair's setup and its uninstaller; anything else stays English.
; Wording follows docs/localization.md.

[LangOptions]
LanguageName=简体中文
LanguageID=$0804
LanguageCodePage=0

[Messages]
SetupAppTitle=安装
SetupWindowTitle=安装 - %1
UninstallAppTitle=卸载
UninstallAppFullTitle=卸载 %1
WindowsVersionNotSupported=这个程序不支持这台电脑上的 Windows 版本。
OnlyOnTheseArchitectures=这个程序只能装在以下处理器架构的 Windows 上：%n%n%1
SetupAppRunningError=%1 正在运行。%n%n请先退出它，然后点“确定”继续，或点“取消”退出安装。
UninstallAppRunningError=%1 正在运行。%n%n请先退出它，然后点“确定”继续，或点“取消”退出卸载。
ExitSetupTitle=退出安装
ExitSetupMessage=安装还没有完成。现在退出，程序不会被安装。%n%n以后可以再次运行安装程序完成安装。%n%n要退出安装吗？
ButtonBack=< 上一步(&B)
ButtonNext=下一步(&N) >
ButtonInstall=安装(&I)
ButtonOK=确定
ButtonCancel=取消
ButtonYes=是(&Y)
ButtonYesToAll=全部选是(&A)
ButtonNo=否(&N)
ButtonNoToAll=全部选否(&O)
ButtonFinish=完成(&F)
PrivilegesRequiredOverrideTitle=选择安装方式
PrivilegesRequiredOverrideInstruction=为谁安装
PrivilegesRequiredOverrideText1=%1 可以为所有用户安装（需要管理员权限），也可以只为你安装。
PrivilegesRequiredOverrideText2=%1 可以只为你安装，也可以为所有用户安装（需要管理员权限）。
PrivilegesRequiredOverrideAllUsers=为所有用户安装(&A)
PrivilegesRequiredOverrideAllUsersRecommended=为所有用户安装（推荐）(&A)
PrivilegesRequiredOverrideCurrentUser=只为我安装(&M)
PrivilegesRequiredOverrideCurrentUserRecommended=只为我安装（推荐）(&M)
WizardSelectDir=安装位置
SelectDirDesc=要把 [name] 装在哪里？
SelectDirLabel3=[name] 会装到下面这个文件夹。
SelectDirBrowseLabel=点“下一步”继续。要换一个文件夹，点“浏览”。
DiskSpaceGBLabel=至少需要 [gb] GB 可用空间。
DiskSpaceMBLabel=至少需要 [mb] MB 可用空间。
CannotInstallToNetworkDrive=不能安装到网络驱动器。
CannotInstallToUNCPath=不能安装到网络路径（UNC 路径）。
InvalidPath=请输入带盘符的完整路径，例如：%n%nC:\APP%n%n或者这样的网络路径：%n%n\\server\share
InvalidDrive=选择的驱动器或网络共享不存在或无法访问，请换一个。
DiskSpaceWarningTitle=磁盘空间不足
DiskSpaceWarning=安装至少需要 %1 KB 可用空间，但所选驱动器只有 %2 KB。%n%n仍然继续吗？
DirNameTooLong=文件夹名称或路径太长。
InvalidDirName=文件夹名称无效。
BadDirName32=文件夹名称不能包含以下字符：%n%n%1
DirExistsTitle=文件夹已存在
DirExists=文件夹：%n%n%1%n%n已经存在。仍然装到这个文件夹吗？
DirDoesntExistTitle=文件夹不存在
DirDoesntExist=文件夹：%n%n%1%n%n不存在。要新建这个文件夹吗？
ButtonBrowse=浏览(&B)…
ButtonWizardBrowse=浏览(&R)…
ButtonNewFolder=新建文件夹(&M)
BrowseDialogTitle=选择文件夹
BrowseDialogLabel=在下面的列表里选一个文件夹，然后点“确定”。
NewFolderName=新建文件夹
WizardReady=准备安装
ReadyLabel1=即将在这台电脑上安装 [name]。
ReadyLabel2a=点“安装”继续，或点“上一步”查看、修改设置。
WizardPreparing=准备安装
PreparingDesc=正在准备在这台电脑上安装 [name]。
ApplicationsFound=以下程序正在使用需要更新的文件，建议让安装程序自动关闭它们。
ApplicationsFound2=以下程序正在使用需要更新的文件，建议让安装程序自动关闭它们。安装完成后，安装程序会尝试重新打开它们。
CloseApplications=自动关闭这些程序(&A)
DontCloseApplications=不关闭这些程序(&D)
WizardInstalling=正在安装
InstallingLabel=正在这台电脑上安装 [name]，请稍候。
FinishedHeadingLabel=[name] 安装完成
FinishedLabelNoIcons=[name] 已经装好了。
FinishedLabel=[name] 已经装好了，可以从开始菜单打开它。
ClickFinish=点“完成”退出安装。
AbortRetryIgnoreSelectAction=选择操作
AbortRetryIgnoreRetry=重试(&T)
AbortRetryIgnoreIgnore=忽略错误并继续(&I)
AbortRetryIgnoreCancel=取消安装
StatusClosingApplications=正在关闭程序…
StatusCreateDirs=正在创建文件夹…
StatusExtractFiles=正在解压文件…
StatusCreateIcons=正在创建快捷方式…
StatusCreateRegistryEntries=正在写入注册表…
StatusSavingUninstall=正在保存卸载信息…
StatusRunProgram=正在完成安装…
StatusRestartingApplications=正在重新打开程序…
StatusRollback=正在撤销更改…
ConfirmUninstall=确定要从这台电脑上彻底删除 %1 吗？
UninstallStatusLabel=正在从这台电脑上删除 %1，请稍候。
UninstalledAll=%1 已从这台电脑上删除。
UninstalledMost=%1 卸载完成。%n%n有些内容没能删除，可以手动删除。
UninstalledAndNeedsRestart=要完成 %1 的卸载，需要重新启动电脑。%n%n现在重新启动吗？
StatusUninstalling=正在卸载 %1…

[CustomMessages]
NameAndVersion=%1 版本 %2
UninstallProgram=卸载 %1
LaunchProgram=打开 %1
