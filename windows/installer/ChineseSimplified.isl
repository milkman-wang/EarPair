; Simplified Chinese for the EarPair installer. Loaded on top of Default.isl
; (MessagesFile: "compiler:Default.isl,ChineseSimplified.isl"), so it only lists the messages
; that can show up with EarPair's one-page setup and its uninstaller; anything else stays English.
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
