# 开发

[English](development.md) | **简体中文**

从源码构建 EarPair、跑测试、了解代码结构。安装和使用请看 [README](../README.zh-CN.md)。

## 工作原理

```
 Windows PC                                          Mac
┌──────────────────────────┐   UDP 47800    ┌──────────────────────────────────┐
│ WASAPI loopback capture  │  audio (EARP)  │ reorder, conceal losses          │
│ 16-bit stereo PCM        │ ─────────────▶ │ 60 ms jitter buffer, drift fix   │
│ 5 ms packets             │                │ loudness leveling, limiter       │
│                          │ ◀───────────── │ AVAudioEngine → system mixer     │
│ tray app / CLI sender    │  status (EARC) │ → AirPods (or any output)        │
└──────────────────────────┘                └──────────────────────────────────┘
          ▲                                                │
          └──────── Bonjour discovery (_earpair._udp) ─────┘
```

- **音频**：不压缩的 16 位立体声 PCM，每包 240 帧（48 kHz 下 5 ms），约 1.6 Mbit/s。格式和测试向量见 [protocol/audio-packet.md](../protocol/audio-packet.md)。
- **接收端**：把乱序的包排好，丢包的地方补上静音，前后各做一次很短的淡出淡入（不会爆音），保持 60 ms 缓冲，通过变速重采样补偿两块声卡的时钟差，Wi‑Fi 卡顿后把延迟拉回来。用 AVAudioEngine 播放，由 macOS 把它和 Mac 自己的声音混在一起。
- **控制通道**（同一个端口）：HELLO（电脑名和设备类型；电脑没有声音、暂停发音频包时带上待机标记）、每秒一次的 STATUS（正在播放、正忙、静音、输出设备）、停止时的 BYE（带上原因：手动停止、网络、音频设备）。网络断开后，电脑会一直探测 Mac，Mac 也会在一分钟内不断联系电脑，网络一恢复就自动接上。见 [protocol/control-packet.md](../protocol/control-packet.md)。
- **自动发现**：Mac 用 Bonjour 广播 `_earpair._udp`，Windows 用系统自带的 DNS-SD 找到它。

## 目录结构

```
protocol/                   音频包、控制包的格式和测试向量
macos/                      Swift Package（macOS 14+）
  Sources/EarPairCore/      接收核心：包、缓冲、时钟漂移、音量平衡、UDP、Bonjour、输出
  Sources/EarPairUI/        菜单栏面板、主窗口和通知（SwiftUI）
  Sources/EarPair/          App 入口
  Sources/earpair-recv/     命令行接收端
  Sources/earpair-snapshot/ 把界面渲染成 PNG
  Tests/EarPairCoreTests/   单元测试和长时间模拟
  scripts/build-app.sh      打包 EarPair.app
windows/                    .NET 10
  EarPair.Sender.Core/      采集、格式转换、打包、UDP、控制包、本机静音
  EarPair.App/              WinUI 3 托盘 App（Windows App SDK 2.6，非打包、自包含）
  EarPair.Sender/           命令行版
  EarPair.Sender.SelfTest/  自检（Mac 上也能跑）
  build.ps1                 打包 zip 和单文件 exe
tools/                      测试发送端、录音分析、端到端测试、图标生成
docs/                       本页和 README 用的图片
```

## 构建

### Mac

需要 Xcode 26 或以上（它要求 macOS 15.6 或以上）。App 本身能在 macOS 14 及以上运行；用 macOS 26 SDK 构建，在 macOS 26 及以上才有 Liquid Glass。

```bash
cd macos
./scripts/build-app.sh        # → macos/build/EarPair.app
```

- 请用这个脚本打包，不要直接拷贝 `swift build` 的产物。SwiftPM 会把最低系统版本写成 SDK 版本，macOS 看到后会按兼容模式显示旧样式（没有 Liquid Glass）；脚本会用 `vtool` 改回实际的 SDK 版本。
- 默认是本机临时签名。macOS 按签名识别 App 的“本地网络”权限，所以每次重新构建后都要再允许一次。有 Apple 开发者证书的话：`SIGN_IDENTITY="Apple Development: …" ./scripts/build-app.sh`。
- 如果 `swift build` 报 llbuild / dyld 错误，是当前选中的命令行工具和 SDK 对不上。脚本会自动改用 `/Applications` 里的 Xcode，也可以自己设 `DEVELOPER_DIR`。

### Windows

需要 Windows 10（2004 版）或以上和 [.NET 10 SDK](https://dotnet.microsoft.com/download/dotnet/10.0)，不需要 Visual Studio。

```powershell
powershell -ExecutionPolicy Bypass -File windows\build.ps1
```

产物在 `dist\`：`EarPair-<版本>-win-x64.zip`、`…-win-arm64.zip` 和命令行版单文件 exe。zip 里自带 .NET 运行时和 Windows App SDK。打包前脚本会检查发布目录（自带运行时、有 `.pri`、没有混进 AI 组件），不对就报错。

## 测试

```bash
swift test --package-path macos                           # Mac 单元测试（加 -c release 更快）
dotnet run --project windows/EarPair.Sender.SelfTest      # Windows 发送端自检，Mac 上也能跑
dotnet run --project windows/EarPair.Sender.SelfTest -- hello 127.0.0.1   # 发 HELLO，检查接收端回的 STATUS
tools/e2e.sh                                              # 端到端：真实 UDP，录音后分析（需要 numpy）
```

- 单元测试包括 30 分钟时钟漂移模拟（±200 ppm）、丢包和乱序、音量平衡和限幅、控制包（和 C# 端共用逐字节一致的测试向量）。
- `tools/e2e.sh` 跑三轮，每轮约 30 秒：时钟偏差、恶劣网络、C# 打包代码 → Swift 接收端。没装 .NET 时跳过最后一轮。

手边没有 Windows？在 Mac 上跑接收端和 Python 测试发送端，都在仓库根目录下运行：

```bash
swift build --package-path macos -c release
macos/.build/release/earpair-recv               # 从当前输出设备出声；加 --null-output 不出声
python3 tools/test_sender.py 127.0.0.1          # 另开一个终端：440 Hz 测试音
python3 tools/test_sender.py 127.0.0.1 --clock-ppm 200 --jitter-ms 8 --loss 1 --reorder 2
```

### 检查界面

- Mac：`swift run --package-path macos -c release earpair-snapshot <目录>` 把菜单栏面板和主窗口概览页在各种状态下渲染成 PNG，主窗口其他各页只渲染等待和播放两种状态，浅色、深色各一份。离屏渲染画不出 Liquid Glass，所以用的是 macOS 14/15 的样式。在目录前加 `--readme`，渲染的是 `docs/images` 里 Mac 的截图。
- Windows：Debug 构建有演示模式，不采集、不连网，用假数据画出各种状态：

  ```powershell
  dotnet build windows\EarPair.App -c Debug -r win-x64 -p:Platform=x64
  windows\EarPair.App\bin\x64\Debug\net10.0-windows10.0.26100.0\win-x64\EarPair.exe --demo playing --theme dark
  ```

  状态有 `pick` `off` `connecting` `playing` `standby` `muted` `legacy` `noresponse` `waiting` `busy` `nosource` `failed` `postmute`。

图标由 `tools/make-icons.swift` 生成（Windows 的 `.ico` 和托盘图标、Mac 的 `.icns`）。

## 命令行工具

```
earpair-recv [--port N] [--buffer-ms N] [--duration S] [--stats S] [--no-drift] [--null-output [--record PATH]]
EarPair.Sender.exe <Mac 的 IP> [--port N] [--device "名称"] [--list-devices] [--frames N] [--no-keepalive]
```

命令行版不会自动发现 Mac，也不会静音本机。不加 `--device` 时跟随系统默认输出设备。

## 日志

- Mac：`log stream --level info --predicate 'subsystem == "app.earpair"'`（Bonjour、UDP、通知和“重新打开”事件）。
- Windows：`%LOCALAPPDATA%\EarPair\logs`，保留 7 天。窗口里：**⋯ → 打开日志文件夹**。

## 已知限制

- 没有加密和认证：同一网络里的设备都能往接收端发声音。配对码和包签名在计划中。
- 只能采集整个输出设备。按 App 采集计划在 0.3。
- 发送期间 Windows 不会自动睡眠：发送端一直在播放静音，保证采集不中断。之前有回应的 Mac 连续 10 秒没有回应时，界面版和命令行版都会暂停（这时电脑可以睡眠），Mac 回来后自动继续；命令行版还可以用 `--no-keepalive` 关掉静音保活。
- 按 Windows 的音量键会取消本机静音（系统行为）。把发送开关关掉再打开即可重新静音。loopback 采集的是调音量之前的声音，所以音量请在 Mac 上调。
- 两边都还没有代码签名：Mac 每次重新构建后要重新允许“本地网络”，Windows 第一次运行时 SmartScreen 会提示。
- 如果在控制中心里给 EarPair 打开了“空间化立体声”，macOS 会再处理一遍它的声音，暂时建议关掉。
- 主窗口里的时钟偏差在开始播放约 1 分钟后才稳定。

## 测试环境

- MacBook Air（Apple 芯片），macOS 27.3，AirPods Pro。
- Parallels 里的 Windows 11 ARM64：完整测过界面版（arm64 包）；x64 包以模拟方式启动过。
- 一台真实的 Windows 电脑，用 0.1 的命令行版：约 6 分钟，69,467 个包，零丢包。
- macOS 14 和 15 的样式只在离屏渲染里看过。
