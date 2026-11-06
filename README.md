# EarPair

**Two computers. One audio space.**

把 Windows 的声音通过局域网送到 Mac，和 Mac 自己的声音一起从 AirPods 播放。AirPods 只连 Mac；Windows 负责把声音发过来，Mac 把它当成一路普通的播放，由系统混音器和本机声音混在一起。

## 0.2 能做什么

**传声音**

- Windows 系统声音（WASAPI loopback）→ UDP 未压缩 PCM → Mac 播放，和 Mac 本地的声音同时从当前输出设备（比如 AirPods）出来。
- 接收端会重排乱序包；丢包处补静音，前后带淡出淡入，不会爆音；自动补偿两台电脑声卡的时钟差；Wi‑Fi 卡顿后会自动把延迟拉回目标值。
- 音量平衡：按 ITU-R BS.1770 测量响度，把 Windows 的声音自动调到目标响度（柔和 −20 / 标准 −16 / 响亮 −12 LUFS），最多提升 15 dB；输出前有限幅器（−1 dBFS），音量开到 200% 也不会削波。

**Mac（菜单栏 App + 主窗口）**

- 主视觉是一条音频路线：Windows 电脑 → 这台 Mac → AirPods，两端画的是同一条路线、同样的名字和图标。连线怎么画就是什么状态：点线是等待，流动的点线是正在连接，流动的光点是正在出声（亮度跟着音量），灰线是已停止，灰线加 ✕ 是已断开，红线是出错；静音时输出设备上挂一个静音角标。
- Windows 上关掉发送时显示“已停止”，网络断了才显示“已断开”；60 秒后回到等待，占位显示上次连过的电脑。
- 菜单栏面板：路线、音量（100% 处吸附）、静音和音量平衡两个开关、打开窗口 / 退出。没连上时显示本机地址（复制的是 IP）。
- 主窗口（系统设置样式的分组表单）：概览（路线、实时波形、音量、缓冲 / 丢包 / 卡顿）、声音（音量、左右平衡、音量平衡和目标响度、输出设备）、网络（缓冲大小和水位曲线、详细统计、时钟漂移补偿）、连接（本机地址和端口、发送端、Windows 命令行版的命令）。
- 发送端显示名字而不是 IP：优先用 Windows 端报的名字，其次反查主机名；图标按台式机 / 笔记本区分。
- 跟随系统默认输出设备：戴上 / 摘下 AirPods、插拔耳机，界面自动跟着变。
- 在局域网里用 Bonjour 广播自己，Windows 端不用输入 IP。
- 界面跟随系统：macOS 26 起是 Liquid Glass，macOS 14 / 15 上是那个系统的原生样式。

**Windows（WinUI 3 界面版，常驻通知区域）**

- 自动找到局域网里的 Mac（Bonjour），点一下就开始发送；也可以手动输入地址。记住用过的 Mac，Mac 换了 IP 会自动跟上。
- 一页窗口（Mica 背景，跟随深浅色）：主卡片是状态、发送开关和“这台电脑 → Mac → 耳机”路线，和 Mac 用同一套画法（Mac 回传后才画出 Mac 的输出设备）；下面四张设置卡：发送到、声音来源、发送时本机静音、开机时启动。
- 发送时本机静音（默认开）：Windows 自己的喇叭不响；停止、退出、关机或注销时恢复，异常退出后下次启动也会恢复。检测到某个声卡静音后采集不到声音，就自动撤销并记住这个设备。
- 先确认 Mac 在线再开始：用过的 Mac 不在身边时（比如开机自启），只发探测包，不采集、不静音本机，Mac 出现后几秒内自动开始。
- Mac 回传接收状态：正在播放 / 正在连接 / Mac 没有响应 / Mac 正忙（在放别的电脑）/ Mac 上已静音。Mac 走开 10 秒后自动暂停（本机恢复出声、电脑可以睡眠），Mac 回来自动继续。
- 停止时先停采集、再通知 Mac，Mac 那边直接显示“已停止”，不会先闪一下“正在连接”。
- 跟随系统默认输出设备，拔插、换默认设备、改采样率都会自动重启采集；出错按 1、2、5、10 秒退避重试。
- 通知区域图标（未发送 / 发送中 / 有问题，跟随任务栏深浅色）和右键菜单；开机时启动；只运行一个实例；关掉窗口后留在通知区域。
- 日志在 `%LOCALAPPDATA%\EarPair\logs`（保留 7 天），窗口右上角“⋯ → 打开日志文件夹”。
- 自带 .NET 10 运行时和 Windows App SDK：解压就能用，不用装任何东西。

**命令行**：Mac 有 `earpair-recv`，Windows 有 `EarPair.Sender.exe`（单个文件，同样自带运行时），参数和 0.1 兼容。

## 现在的状态

| 部分 | 状态 |
|---|---|
| Mac 接收端（菜单栏 App + 命令行） | 33 个单元测试通过（含 30 分钟时钟漂移模拟、音量平衡、控制包）；真机实测通过（0.1） |
| Windows 界面版（WinUI 3） | 在 Windows 11 ARM64 虚拟机里编译、运行：发现 Mac、先探测再发送、Mac 回传、没有响应 → 自动暂停、停止、注销时恢复本机声音，都按设计工作；12 种状态在浅色、深色下截图检查过 |
| Windows 命令行版 | 自检通过；虚拟机里推流到 Mac：15000 多个包零丢失 |
| 控制包（名字、回传） | C# 发送端 ↔ Swift 接收端互通测试通过 |
| Windows 和 Mac 的声音一起从 AirPods 出来 | **真机实测通过**（0.1） |

## 快速开始

### 1. Mac：构建并打开接收端

需要 macOS 14 以上和 Xcode。

```bash
cd macos
./scripts/build-app.sh
open build/EarPair.app
```

菜单栏会出现一个耳朵图标。第一次运行时 macOS 会问是否允许 EarPair 访问“本地网络”，选**允许**：不允许的话，Windows 端找不到这台 Mac，也收不到回传状态（声音照样能收）。

> 如果 `swift build` 报 llbuild 的 dyld 错误：说明当前选中的“命令行工具”和 SDK 版本对不上。脚本会自动改用 `/Applications` 里的 Xcode，也可以手动 `export DEVELOPER_DIR=/Applications/Xcode-beta.app/Contents/Developer`。
>
> SwiftPM 链接时会把二进制里记录的 SDK 版本写成最低系统版本（14.0），系统看到旧 SDK 就按兼容模式显示旧样式，没有 Liquid Glass。`build-app.sh` 打包时会用 `vtool` 改回实际编译用的 SDK 版本，所以请用这个脚本打包，不要直接拷贝 `swift build` 的产物。

### 2. Windows：运行界面版

把 `EarPair-0.2.0-win-x64.zip`（ARM 电脑用 `win-arm64`）**先解压**到任意位置，运行 `EarPair\EarPair.exe`。列表里点一下你的 Mac 就开始发送。关掉窗口后 EarPair 留在通知区域（任务栏右下角的耳朵图标）继续发送；Windows 11 默认把新图标收在“^”里。

第一次运行时 Windows 可能提示“已保护你的电脑”（还没有代码签名）：点“更多信息”→“仍要运行”。

自己打包（需要 Windows 和 [.NET 10 SDK](https://dotnet.microsoft.com/download/dotnet/10.0)，不需要 Visual Studio）：

```powershell
powershell -ExecutionPolicy Bypass -File windows\build.ps1
```

产物在 `dist\`：两种架构的界面版 zip 和命令行版单文件 exe。打包前会检查发布目录（自带运行时、有 .pri、没有混进 AI 组件），不对就报错。删除 EarPair 之前，先关掉“开机时启动”。

### 3. Windows：命令行版

```powershell
EarPair.Sender.exe 192.168.1.20
```

其他用法：`--list-devices` 列出输出设备，`--device "名称片段"` 采集指定设备，`--help` 查看全部参数。不指定设备时跟随系统默认输出设备。命令行版不做自动发现，也不会静音本机。

## 没有 Windows 也能先测

```bash
cd macos && swift build -c release      # 构建命令行接收端
.build/release/earpair-recv             # 会从 Mac 当前的输出设备出声；加 --null-output 则不出声
```

另开一个终端，发送 440 Hz 测试音，也可以模拟恶劣网络：

```bash
python3 tools/test_sender.py 127.0.0.1
python3 tools/test_sender.py 127.0.0.1 --clock-ppm 200 --jitter-ms 8 --loss 1 --reorder 2
```

自动化测试：

```bash
cd macos && swift test                                  # Mac 端单元测试（加 -c release 更快）
dotnet run --project windows/EarPair.Sender.SelfTest    # Windows 发送端自检（Mac 上也能跑，需要 .NET 10 SDK）
dotnet run --project windows/EarPair.Sender.SelfTest -- hello 127.0.0.1   # 发 HELLO，检查接收端回的 STATUS
tools/e2e.sh                                            # 端到端：真实 UDP，不出声，录音后分析（需要 numpy）
```

`tools/e2e.sh` 跑三轮，每轮约 30 秒：时钟偏差、恶劣网络、C# 发送端 → Swift 接收端。没装 .NET 时跳过最后一轮。

检查界面布局：把菜单栏面板和主窗口渲染成 PNG（等待、连接中、播放中、没声音、静音、已断开、无法接收、无法播放 × 浅色 / 深色）。离屏渲染画不出玻璃效果，所以图里用的是 macOS 14 / 15 的样式，玻璃要看真实窗口。

```bash
cd macos && swift run -c release earpair-snapshot /tmp/earpair-snapshots
```

Windows 界面版的 Debug 构建带一个演示模式，不采集、不连网，用假数据把 12 种状态画出来，方便截图检查：

```powershell
dotnet build windows\EarPair.App -c Debug -r win-x64 -p:Platform=x64
windows\EarPair.App\bin\x64\Debug\net10.0-windows10.0.26100.0\win-x64\EarPair.exe --demo playing --theme dark
```

状态有 `pick` `off` `connecting` `playing` `muted` `legacy` `noresponse` `waiting` `busy` `nosource` `failed` `postmute`。

图标由 `tools/make-icons.swift` 生成（Windows 的 .ico 和托盘图标、Mac 的 .icns）。

## 测试结果

- **Mac 单元测试 33 个全部通过**：
  - 协议测试向量；乱序、丢包、迟到、重复；切换发送端；欠载后恢复；音量和静音；变速插值精度。
  - 音量平衡：−30 dBFS 的安静正弦被提升到 −16 LUFS（增益约 +14 dB），响的信号被压低，静音时增益保持不动，关掉时信号不变；200% 音量下限幅器把峰值压在 −1 dBFS 以内；左右平衡。
  - 控制包：BYE、HELLO 测试向量逐字节一致；长度、版本、类型不对的包丢掉；HELLO 立即回 STATUS、之后每秒一次、6 秒后停；对正在播的发送端回 playing、对另一台电脑回 busy 和正在播的名字；BYE 立即结束当前流，之后同一路流迟到的包都忽略，换新流照常开始；超时断开不算停止；kind 字段往返编解码，不认识的值当作未知。
  - 发送端时钟快 / 慢 200 ppm，各连续播放 30 分钟：零欠载，缓冲始终在 56–64 ms（目标 60），偏差估计误差小于 3 ppm。
  - 1% 丢包 + 2% 乱序；每 20 秒卡顿 40 ms：都没有欠载。卡顿 150 ms：欠载一次后恢复，延迟回到目标。
- **端到端（真实 UDP，本机回环，每轮 25 秒）**：两端时钟相差 300 ppm 零丢包零欠载；8 ms 抖动 + 1% 丢包 + 2% 乱序时故意丢的包全部被正确统计、没有爆音；C# 打包代码 → Swift 接收端 5000 包零丢失。
- **Windows 自检全部通过**（.NET 10.0.403，Mac 上也能跑）：打包、格式转换、命令行参数、控制包（两个测试向量和 Swift 端一致、kind 和 headphones、STATUS 解析、坏包丢弃）。
- **Windows 11 ARM64 虚拟机（Parallels）**：
  - 界面版从零开始：Bonjour 列出 Mac → 点选 → “正在播放”；接收端收到 15366 包，丢包 0。
  - 停掉接收端：约 3 秒后显示“Mac 没有响应”，10 秒后自动暂停为“等待 Mac”，本机静音同时撤销。
  - 单实例：再次打开 EarPair 只会唤出已有的窗口。
  - 先探测：Mac 端接收程序没开时启动，只显示“等待 Mac”，不采集、不静音本机；打开接收程序后约 3 秒自动开始，“正在播放”。
  - 关掉发送开关：Mac 端直接变成“已停止”，BYE 之后迟到的包为 0（先停采集再发 BYE）。
  - 模拟注销（给通知区域窗口发 WM_ENDSESSION）：立即停止发送、恢复本机静音，Mac 端显示“已停止”。
  - 关掉窗口后进程留在通知区域；标题栏只有“⋯”按钮那一块可以点，其余部分可以拖动窗口（用 WM_NCHITTEST 逐层核对）。
  - 虚拟机的虚拟声卡时钟偏差大（约 +300 ppm）、抖动约 8 ms，接收端偶尔欠载；真机上不是这样（见下）。

## 真机实测（0.1，2026-11-06）

Windows 电脑（输出设备 48 kHz 立体声）→ 局域网 → MacBook Air（Wi‑Fi）→ AirPods Pro。

- 命令行接收端连续跑了约 5.8 分钟，中间手动重启过一次发送端：收到 69467 包，丢包 0、迟到 0，播放中没有欠载，缓冲稳定在 56–62 ms。两台电脑的时钟偏差最后估计为 −1 ppm 左右。
- 菜单栏 App 接收后输出到 AirPods Pro。Mac 上同时放声音时，两边的声音都能听到，听感连续。

## 延迟预期

AirPods 自身约 130–180 ms，加上 60 ms 缓冲和约 20 ms 采集 / 输出，总共约 0.2–0.3 秒。听音乐、提示音没问题；**在 Windows 上看视频会明显口型不同步**：Mac 自己的播放器会补偿蓝牙延迟，Windows 上的播放器不知道多了这段延迟。

## 项目结构

```
protocol/audio-packet.md     音频包 v1（含测试向量）
protocol/control-packet.md   控制包 v1：名字和设备类型、接收状态回传、停止通知（含测试向量）
macos/                       Swift Package（macOS 14+）
  Sources/EarPairCore/       接收核心：包解析、乱序 / 丢包处理、缓冲、时钟漂移补偿、音量平衡、限幅、UDP 收发、
                             控制包、Bonjour 广播、输出设备监听、AVAudioEngine 输出
  Sources/EarPairUI/         菜单栏面板和主窗口（SwiftUI）
  Sources/EarPair/           菜单栏 App 入口
  Sources/earpair-recv/      命令行接收端
  Sources/earpair-snapshot/  把界面渲染成 PNG，检查布局
  Tests/EarPairCoreTests/    单元测试和长时间模拟
  scripts/build-app.sh       打包 EarPair.app
windows/                     .NET 10
  EarPair.Sender.Core/       发送引擎：WASAPI 采集、格式转换、打包、UDP 收发、控制包、本机静音
  EarPair.App/               WinUI 3 界面版（Windows App SDK 2.6，非打包、自包含）
  EarPair.Sender/            命令行版
  EarPair.Sender.SelfTest/   自检（不需要 Windows 和声卡）
  build.ps1                  打包两种架构的 zip 和单文件 exe
tools/                       测试发送端、录音分析、端到端测试、图标生成
```

## 已知限制

- 没有加密和认证：同一网络里的设备都能往接收端发包、冒充名字。接收端会锁定当前发送端，但这挡不住伪造。配对码和包签名还没做。
- 只能采集整个输出设备（系统全部声音），按 App 采集要等 0.3。
- 发送期间 Windows 不会自动睡眠（静音保活在一直播放静音）；Mac 走开后界面版会自动暂停，那时就可以睡眠了。命令行版用 `--no-keepalive` 可以关掉保活。
- 按 Windows 的音量键会顺手取消静音（系统行为），这时本机喇叭会响；在 EarPair 里关掉再打开发送开关即可重新静音。loopback 取的是音量调节之前的声音，Windows 的音量大小不影响 Mac 听到的音量，音量在 Mac 上调。
- Mac App 用本机临时签名，macOS 的“本地网络”权限按签名识别 App，每次重新构建后要重新允许一次。有 Apple 开发者证书的话：`SIGN_IDENTITY="Apple Development: …" ./scripts/build-app.sh`。
- Windows 版还没有代码签名，第一次运行会有 SmartScreen 提示。
- Windows 界面版只在 Windows 11 ARM64 虚拟机里实际跑过：arm64 包完整测过，x64 包在同一台虚拟机里以 x64 模拟方式启动过，还没在 x64 真机上跑过。
- Mac 界面只在 macOS 27 上实际看过；macOS 14 / 15 只验证了能编译（新系统的 API 都做了版本判断），样式还没在这两个系统上实际看过。
- 如果在控制中心里给 EarPair 打开了“空间化立体声”，系统会再处理一遍它的声音。做 0.4 的空间音频之前，建议对 EarPair 关掉这个选项。
- 主窗口里的“时钟偏差”开播后约 1 分钟才稳定，之前显示“测量中”。

## 路线图

- **0.3 多应用**：Windows 按进程采集（NAudio 3），Mac 端用 Core Audio process tap 接管本地 App 的声音；按“最近在哪台电脑上操作”自动调整两边音量。
- **稳定性**（穿插进行）：配对码和包签名、Opus 编码、自适应缓冲、代码签名和安装包。
- **0.4 屏幕空间音频**：把 Windows 的声音放到它屏幕的方向；用 AirPods 的头部朝向判断你在看哪块屏幕。
