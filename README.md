# EarPair

**Two computers. One audio space.**

把 Windows 的声音通过局域网送到 Mac，和 Mac 自己的声音一起从 AirPods 播放。AirPods 只连 Mac；Windows 负责把声音发过来，Mac 把它当成一路普通的播放，由系统混音器和本机声音混在一起。

## 0.1 能做什么

- Windows 系统声音（WASAPI loopback）→ UDP 未压缩 PCM → Mac 播放，和 Mac 本地的声音同时从当前输出设备（比如 AirPods）出来。
- Mac 菜单栏 App：单独调 Windows 声音的音量 / 静音，选缓冲大小，看连接状态和统计（丢包、迟到、欠载、时钟偏差、网络抖动、码率）。
- 接收端会重排乱序包；丢包处补静音，前后带淡出淡入，不会爆音；自动补偿两台电脑声卡的时钟差；Wi‑Fi 卡顿后会自动把延迟拉回目标值。

## 现在的状态

| 部分 | 状态 |
|---|---|
| Mac 接收端（菜单栏 App + 命令行工具） | 19 个单元测试通过（含 30 分钟时钟漂移模拟），本机端到端测试通过，真机实测通过 |
| Windows 发送端（C# / .NET 8 / NAudio） | 自检 18 项通过；真机实测通过：WASAPI 采集、静音保活、打包发送都正常 |
| Windows 和 Mac 的声音一起从 AirPods 出来 | **真机实测通过**，这是 0.1 的完成标志 |
| Windows 静音后还能不能采集 | 还没测，取决于声卡驱动 |

## 快速开始

### 1. Mac：构建并打开接收端

需要 macOS 14 以上和 Xcode。

```bash
cd macos
./scripts/build-app.sh
open build/EarPair.app
```

菜单栏会出现一个耳朵图标，点开能看到本机的局域网 IP。第一次收到 Windows 发来的声音时，macOS 可能会问是否允许 EarPair 访问"本地网络"，选允许。

> 如果 `swift build` 报 llbuild 的 dyld 错误：说明当前选中的"命令行工具"和 SDK 版本对不上。脚本会自动改用 `/Applications` 里的 Xcode，也可以手动 `export DEVELOPER_DIR=/Applications/Xcode-beta.app/Contents/Developer`。

### 2. Windows：运行发送端

需要 [.NET 8 SDK](https://dotnet.microsoft.com/download/dotnet/8.0)。把 IP 换成 Mac 菜单里显示的地址：

```powershell
cd windows\EarPair.Sender
dotnet run -c Release -- 192.168.1.20
```

其他用法：`--list-devices` 列出输出设备，`--device "名称片段"` 采集指定设备，`--help` 查看全部参数。

出问题时可以先跑自检（不需要声卡）：`dotnet run --project windows\EarPair.Sender.SelfTest`。

想要单个 exe：

```powershell
dotnet publish -c Release -r win-x64 -p:PublishSingleFile=true --self-contained false
```

### 3. 别让 Windows 自己也出声

声音发给 Mac 的同时，Windows 本机的音箱照样会响。0.1 的建议：

1. 先试：Windows 音量开到 100%，然后点**静音**。很多声卡上，静音不影响 loopback 采集，Mac 那边照样有声音。
2. 如果静音后 Mac 那边也没声音了（取决于声卡驱动）：把 Windows 的默认输出设成一个虚拟声卡（比如 VB-CABLE），或者一个没接音箱的输出口，再用 `--device` 指定它。

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
dotnet run --project windows/EarPair.Sender.SelfTest    # Windows 发送端自检（Mac 上也能跑）
tools/e2e.sh                                            # 端到端：真实 UDP，不出声，录音后分析（需要 numpy）
```

`tools/e2e.sh` 跑三轮，每轮约 30 秒：时钟偏差、恶劣网络、C# 发送端 → Swift 接收端。没装 .NET 时跳过最后一轮。

## 测试结果（本机，2026-11-05）

- **单元测试 19 个全部通过**：
  - 协议测试向量；乱序、丢包、迟到、重复；切换发送端；欠载后恢复；音量和静音；变速插值精度。
  - 发送端时钟快 / 慢 200 ppm，各连续播放 30 分钟：零欠载，缓冲始终在 56–64 ms（目标 60），偏差估计误差小于 3 ppm。
  - 1% 丢包 + 2% 乱序；每 20 秒卡顿 40 ms：都没有欠载。卡顿 150 ms：欠载一次后恢复，延迟回到目标。
- **端到端（真实 UDP，本机回环，每轮 25 秒）**：
  - 两端时钟相差 300 ppm：零丢包、零欠载，录音里的正弦完全连续。
  - 8 ms 抖动 + 1% 丢包 + 2% 乱序：故意丢的 46 个包全部被正确统计，乱序包全部重排，没有爆音；每个丢包处是一段 5 ms、带淡入淡出的静音。
  - C# 发送端的格式转换和打包代码（模拟 WASAPI 的浮点数据）→ Swift 接收端：5000 包零丢失，录音完全连续，说明两边的包格式一致。
- **Windows 发送端自检 18 项全部通过**（.NET 8.0.427，在 Mac 上运行）。

## 真机实测（2026-11-06）

Windows 电脑（输出设备 48 kHz 立体声）→ 局域网 → MacBook Air（Wi‑Fi）→ AirPods Pro。

- 命令行接收端连续跑了约 5.8 分钟，中间手动重启过一次发送端：收到 69467 包，丢包 0、迟到 0，播放中没有欠载，缓冲稳定在 56–62 ms。两台电脑的时钟偏差最后估计为 −1 ppm 左右。
- 菜单栏 App 接收后输出到 AirPods Pro。Mac 上同时放声音时，两边的声音都能听到，听感连续。

## 延迟预期

AirPods 自身约 130–180 ms，加上 60 ms 缓冲和约 20 ms 采集 / 输出，总共约 0.2–0.3 秒。听音乐、提示音没问题；**在 Windows 上看视频会明显口型不同步**：Mac 自己的播放器会补偿蓝牙延迟，Windows 上的播放器不知道多了这段延迟。

## 项目结构

```
protocol/audio-packet.md   包格式 v1（含测试向量）
macos/                     Swift Package（macOS 14+）
  Sources/EarPairCore/     接收核心：包解析、乱序 / 丢包处理、缓冲、时钟漂移补偿、UDP 接收、AVAudioEngine 输出
  Sources/EarPair/         菜单栏 App（SwiftUI）
  Sources/earpair-recv/    命令行接收端（调试、无界面运行、测试）
  Tests/EarPairCoreTests/  单元测试和长时间模拟
  scripts/build-app.sh     打包 EarPair.app
windows/EarPair.Sender/    Windows 发送端（C# / .NET 8 / NAudio 2.2.1）
windows/EarPair.Sender.SelfTest/  发送端自检（不需要 Windows 和声卡）
tools/                     测试发送端、录音分析、端到端测试脚本
```

## 已知限制

- Windows 发送端的 WASAPI 采集和静音保活还没在真机上跑过（Mac 上只能编译，不能运行这部分）。
- 没有加密和认证：同一网络里的设备都能往接收端发包。接收端会锁定当前发送端，但这挡不住伪造。计划在 0.2 加配对码和包签名。
- 只能采集整个输出设备（系统全部声音），按 App 采集要等 0.3。
- Windows 端的"静音保活"会让 Windows 在发送期间不自动睡眠；用 `--no-keepalive` 可以关掉，代价是 Windows 没声音时 Mac 端会显示断开。
- Mac App 用本机临时签名。macOS 的"本地网络"权限按签名识别 App，重新构建后可能要重新授权。有 Apple 开发者证书的话：`SIGN_IDENTITY="Apple Development: …" ./scripts/build-app.sh`。
- 如果在控制中心里给 EarPair 打开了"空间化立体声"，系统会再处理一遍它的声音。做 0.4 的空间音频之前，建议对 EarPair 关掉这个选项。
- 菜单里的"时钟偏差"开播后约 1 分钟才稳定，之前显示"测量中"。实测中，音频输出刚打开时这个估计值会先冲到约 +200 ppm，大约 1 分钟后回到真实值。对听感没有影响（相当于播放速度快了万分之二），0.2 里再优化。

## 路线图

- **0.2 稳定性**：Opus 编码、自适应缓冲、配对码和包签名、断线重连、接收端回传统计。
- **0.3 多应用**：Windows 按进程采集（NAudio 3 已支持），Mac 端用 Core Audio process tap 接管本地 App 的声音；按"最近在哪台电脑上操作"自动调整两边音量。
- **0.4 屏幕空间音频**：把 Windows 的声音放到它屏幕的方向；用 AirPods 的头部朝向判断你在看哪块屏幕。
