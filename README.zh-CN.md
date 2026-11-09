<p align="center">
  <img src="docs/images/icon.png" width="128" alt="EarPair 图标">
</p>

<h1 align="center">EarPair</h1>

<p align="center">用 Mac 上的 AirPods 听 Windows 电脑的声音。</p>

<p align="center">
  <a href="https://github.com/milkman-wang/EarPair/releases/latest"><img src="https://img.shields.io/github/v/release/milkman-wang/EarPair" alt="最新版本"></a>
  <img src="https://img.shields.io/badge/macOS-14%2B-000000?logo=apple" alt="macOS 14+">
  <img src="https://img.shields.io/badge/Windows-10%202004%2B-0078D4?logo=windows" alt="Windows 10 2004+">
</p>

<p align="center"><a href="README.md">English</a> | <b>简体中文</b></p>

<p align="center">
  <picture>
    <source media="(prefers-color-scheme: dark)" srcset="docs/images/zh-CN/mac-window-dark.png">
    <img src="docs/images/zh-CN/mac-window-light.png" width="780" alt="Mac 上的 EarPair：Windows 电脑的声音经 Mac 从 AirPods Pro 播放">
  </picture>
</p>

EarPair 把 Windows 电脑的声音经局域网传到 Mac，与 Mac 自己的声音混合后从 Mac 当前的输出设备（AirPods、耳机或扬声器）播放，耳机无需在两台电脑之间切换。无需账号，不经云端，不收集数据。

## 功能

| 功能 | 作用 | 注意 |
|---|---|---|
| **自动发现** | Windows 端列出局域网内所有运行 EarPair 的 Mac（Bonjour）。 | Bonjour 不跨网段、访客网络和 VPN，这些情况请用 **输入地址**。 |
| **声音采集** | 采集电脑上除 EarPair 外所有 App 的声音，取自电脑音量和静音之前（进程 loopback）。 | 只想采集某个输出设备时，在 **声音来源** 里选择。不支持进程 loopback 的 Windows 版本始终按输出设备采集。 |
| **发送时本机静音** | 发送期间让电脑的扬声器静音，停止后恢复。 | 按 Windows 音量键会取消静音。少数声卡静音后无法采集，EarPair 会取消该设备的静音并提示。 |
| **音量平衡**（Mac） | 把电脑声音的响度稳定在目标值（ITU‑R BS.1770）。 | 目标在 **声音 → 目标响度** 中设置。需要原始音量时请关闭。 |
| **抗网络抖动**（Mac） | 重排迟到的包，对丢失的包做淡入淡出，补偿两台电脑的时钟差，并按近期网络状况自动设定缓冲（20–150 ms）。 | 在 **网络** 页关闭 **自动缓冲** 可改用固定缓冲。 |
| **待机** | 电脑静音 3 秒后停止传输音频，只保持握手；一有声音立即恢复。 | 待机中的电脑仍占用 Mac。 |
| **单路播放**（Mac） | Mac 同一时间只播放一台电脑。其他电脑显示 **Mac 正忙** 和正在播放的电脑名。 | Mac 空闲后自动开始。 |
| **连接通知**（Mac） | 电脑连上、停止或网络断开时通知；断线后自动重连。 | 需要允许通知。 |
| **空间音频**（Mac） | 配合支持头部追踪的 AirPods，电脑的声音来自电脑屏幕方向，Mac 的声音来自 Mac 屏幕方向，转头时位置不变；没在看的那一边音量降低。 | 在 **空间音频** 页面对两块屏幕各设置一次。**Mac 自己的声音也跟着转** 需要 macOS 14.2 或以上。 |
| **自动更新** | 两端都从 GitHub Releases 检查新版本（Mac 启动时及每 6 小时，Windows 启动后不久及每 12 小时），一键安装。 | 只获取最新版本号。Mac 版需放在可写入的文件夹中，例如“应用程序”。 |
| **后台运行** | Mac 上在菜单栏，Windows 上在通知区域；Windows 可 **开机时启动**。 | 发送期间电脑不会睡眠；Mac 连续 10 秒联系不上时暂停发送。 |

<p align="center">
  <picture>
    <source media="(prefers-color-scheme: dark)" srcset="docs/images/zh-CN/mac-menu-dark.png">
    <img src="docs/images/zh-CN/mac-menu-light.png" height="200" alt="Mac 菜单栏里的 EarPair 面板">
  </picture>
  &nbsp;&nbsp;
  <picture>
    <source media="(prefers-color-scheme: dark)" srcset="docs/images/zh-CN/windows-card-dark.png">
    <img src="docs/images/zh-CN/windows-card-light.png" height="200" alt="Windows 上的 EarPair，正在发送到 MacBook Air">
  </picture>
</p>

## 系统要求

| | Mac | 电脑 |
|---|---|---|
| **系统** | macOS 14 或以上 | Windows 10 2004 或以上、Windows 11 |
| **处理器** | Apple 芯片或 Intel | x64 或 Arm64 |
| **网络** | 与电脑在同一局域网 | 播放时约 1.6 Mbit/s |
| **空间音频** | 支持头部追踪的 AirPods 或 Beats | — |

两端界面跟随系统语言：简体中文或英文。

## 安装

1. **Mac**：从 [Releases](https://github.com/milkman-wang/EarPair/releases/latest) 下载 `EarPair-<版本>-macos-universal.dmg`，把 **EarPair** 拖进 **应用程序** 后从那里打开。询问本地网络权限时点 **允许**。
2. **电脑**：下载 `EarPair-<版本>-win-x64-setup.exe`（Arm 电脑用 `win-arm64`）并运行。安装到当前用户，无需管理员权限。
3. 在电脑上点一下你的 Mac。

### 权限与首次运行提示

| 提示 | 平台 | 用途 | 拒绝后 |
|---|---|---|---|
| 本地网络 | Mac | 被发现、接收声音 | **系统设置 → 隐私与安全性 → 本地网络** |
| 通知 | Mac | 连接通知 | 可选 |
| 运动数据 | Mac | 空间音频 | **空间音频** 页点 **打开系统设置** |
| 系统录音 | Mac 14.2+ | **Mac 自己的声音也跟着转** | 只有电脑的声音参与定位；**空间音频** 页点 **打开系统设置** |
| “Apple 无法验证 EarPair” | Mac | 未签名 | **系统设置 → 隐私与安全性 → 仍要打开** |
| “Windows 已保护你的电脑” | 电脑 | 安装程序未签名 | **更多信息 → 仍要运行** |

> [!IMPORTANT]
> 目前没有代码签名。macOS 会把每个新版本当成新 App，每次更新后都要重新允许本地网络权限。

## 安全与隐私

- 声音未加密传输，Mac 接受同一网络内任何设备发来的声音。请只在信任的网络中使用。
- 唯一的外网请求是向 GitHub Releases API 检查更新。

## 常见问题

### 电脑上找不到 Mac

1. 确认 Mac 上的 EarPair 正在运行：菜单栏里有耳朵图标。
2. 两台电脑连同一个网络、同一网段。访客网络和开启了 AP 隔离（客户端隔离）的路由器会阻断设备之间的通信。
3. Windows 网络设为 **专用网络**：**设置 → 网络和 Internet → WLAN 或以太网 → 网络配置文件类型**。
4. 断开两台电脑上的 VPN。
5. Mac 上在 **系统设置 → 隐私与安全性 → 本地网络** 里打开 EarPair。如果开了 macOS 防火墙，允许 EarPair 接收传入连接。
6. 仍然找不到时，在电脑上点 **输入地址**，填 Mac 的 IP（等待连接时显示在菜单栏面板里，也可以在 **连接** 页查看）。EarPair 使用 UDP 端口 47800。

### 其他问题

| 现象 | 原因与解决 |
|---|---|
| **Mac 上的 EarPair 没有打开** | Mac 能连通，但 47800 端口没有程序监听。在 Mac 上打开 EarPair。 |
| **连不上 Mac** | 数据包到不了 Mac，按上一节逐项检查。Mac 恢复可达后自动继续发送。 |
| **等待 Mac**，但 Mac 上的 EarPair 已打开 | Mac 的回应到不了电脑，常见原因是电脑上的防火墙。点 **仍然发送**。 |
| **Mac 正忙** | 另一台电脑正在往这台 Mac 播放。在那台电脑上停止发送。 |
| **找不到声音来源** | Windows 没有可用的输出设备。连接或启用一个，或在 **声音来源** 里换一个。 |
| Mac 显示 **无法接收** | 47800 端口被其他程序占用，例如另一个 EarPair 或 `earpair-recv`。退出该程序。 |
| Mac 显示 **无法播放** | 没有可用的输出设备。在 **系统设置 → 声音 → 输出** 里选择一个。 |
| 电脑显示 **正在播放**，但听不到 | 检查 Mac 菜单栏面板里的 **静音** 和音量，以及 Mac 的输出设备。 |
| 爆音或断续 | Wi‑Fi 信号差。改用 5 GHz 或有线，并在 Mac 的 **网络** 页查看 **丢包**。关闭 **自动缓冲** 时可选更大的缓冲。 |
| 电脑扬声器又响了 | 按了 Windows 音量键。把发送关掉再打开。 |
| 空间音频打不开 | 给 Mac 连上支持头部追踪的 AirPods，并允许使用运动数据（**空间音频** 页点 **打开系统设置**）。 |
| 空间音频听起来被处理了两次 | 在控制中心里为 EarPair 关闭 **空间化立体声**。 |
| 声音位置不对 | 面向 Mac 点 **对准 Mac**，或点 **重新设置…**。 |
| 菜单栏里没有耳朵图标 | macOS 26 及以上：**系统设置 → 菜单栏 → 允许在菜单栏显示**，打开 EarPair。 |
| Mac 上没有通知 | **系统设置 → 通知 → EarPair → 允许通知**。 |
| Mac 更新失败：“没法替换这个文件夹里的自己” | 把 EarPair 移到 **应用程序**，不要从磁盘映像或受保护的文件夹运行。 |
| Mac 更新后用不了 | 重新允许本地网络权限。 |
| 电脑更新失败 | 点 **打开下载页**，手动运行新版安装程序。 |

### 日志

- **Windows**：**⋯ → 打开日志文件夹**（`%LOCALAPPDATA%\EarPair\logs`，保留 7 天）。
- **Mac**：`log stream --level info --predicate 'subsystem == "app.earpair"'`

反馈问题时请附上 EarPair、Windows 和 macOS 的版本，以及相关日志。

## 工作原理

Windows 端采集电脑的声音，以不压缩的 16 位立体声 PCM、每包 5 ms 经 UDP 发给 Mac。Mac 缓冲音频流，补偿丢包和时钟漂移，经 AVAudioEngine 播放，由 macOS 与其他声音混合。同一端口上的控制通道传递名称、状态和待机信息。详见 [docs/development.zh-CN.md](docs/development.zh-CN.md)、[音频包](protocol/audio-packet.md)、[控制包](protocol/control-packet.md)。

## 从源码构建

| 平台 | 命令 | 需要 |
|---|---|---|
| Mac | `macos/scripts/build-app.sh` | Xcode 26 或以上 |
| Windows | `powershell -ExecutionPolicy Bypass -File windows\build.ps1` | [.NET 10 SDK](https://dotnet.microsoft.com/download/dotnet/10.0)；打安装包需要 [Inno Setup 6](https://jrsoftware.org/isinfo.php)（没装时打 zip） |

产物在 `macos/build/` 和 `dist\`。测试、工具和目录结构见 [docs/development.zh-CN.md](docs/development.zh-CN.md)。

## 路线图

- 选择要发送的电脑 App
- 配对与加密
- 代码签名与公证
