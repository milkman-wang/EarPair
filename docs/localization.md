# Localization

EarPair is in English and Simplified Chinese, and English is used for every other language.

- **Mac:** follows the user's preferred-language list (the first language EarPair supports wins). A per-app language can also be set in System Settings → General → Language & Region.
- **Windows:** follows the Windows display language. `EarPair.exe --lang <culture>` overrides it (useful for screenshots and support).

## Conventions

- **English is the source language.** Strings in code are English; translations live in resource files next to the code that uses them.
- **Same concept, same words** on both platforms: use the glossary below.
- **Mac** follows Apple's style: Title Case for buttons and menu items ("Open EarPair", "Reset Statistics"), sentence case for labels, status text and settings ("Clock drift compensation"). Use the typographic apostrophe (’) and ellipsis (…).
- **Windows** follows Microsoft's style: sentence case everywhere ("Start at login", "Open log folder"). Use the straight apostrophe (') and the ellipsis character (…).
- **Counts:** put the noun in the label and show a bare number ("Packets received: 69,467"), so English needs no plural forms. On the Mac the only keys that aren't English text are `count.packets`, `count.times` and `count.packetLoss`: English shows just the number, Chinese adds 个 or 次.
- **Placeholders** (`%@`, `{0}`) keep their order-independent meaning in both languages; never build a sentence from pieces.
- **Chinese text** keeps the wording the app had before localization: spaces between Chinese and Latin text or digits, full-width punctuation, 你 rather than 您.
- **Not translated:** product names (EarPair, Windows, Mac, AirPods, Bonjour), test output, and the developer tools `earpair-recv` and `earpair-snapshot`.

## Glossary

| 中文 | English |
|---|---|
| 等待连接 | Waiting |
| 正在连接 | Connecting |
| 正在播放 | Playing |
| 待机 | Standby |
| 已停止 | Stopped |
| 正在重新连接 | Reconnecting |
| 已断开 | Disconnected |
| 无法接收 / 无法播放 / 无法发送 | Can’t receive / Can’t play (Mac) · Can't send (Windows) |
| 未发送 | Not sending |
| 正在发送 | Sending |
| 选择 Mac | Choose a Mac |
| 等待 Mac | Waiting for the Mac |
| Mac 正忙 | Mac is busy |
| Mac 没有响应 | Mac isn't responding |
| 连不上 Mac | Can't reach the Mac |
| Mac 上的 EarPair 没有打开 | EarPair isn't open on the Mac |
| Mac 可用后自动继续 | Resumes automatically when the Mac is available |
| 正在播放 X 的声音 | Playing sound from X |
| Mac 上已静音 | Muted on the Mac |
| 找不到声音来源 | No sound source |
| 仍然发送 | Send anyway |
| 重试 | Retry |
| 出错了 | Something went wrong |
| 发送 | Send |
| 发送到 | Send to |
| 开始发送 / 停止发送 | Start sending / Stop sending |
| 声音来源 | Sound source |
| 系统默认 | System default |
| 发送时本机静音 | Mute this PC while sending |
| 开机时启动 | Start at login |
| 输入地址 | Enter address |
| 重新查找 | Search again |
| 没有找到 Mac | No Macs found |
| 打开日志文件夹 | Open log folder |
| 更多 | More |
| 退出（Windows 托盘） / 退出 EarPair（Windows ⋯ 菜单） | Exit / Exit EarPair |
| 输入 Mac 的地址 / 连接 / 取消 | Enter the Mac's address / Connect / Cancel |
| 打开 EarPair / 退出 EarPair（Mac 菜单栏） | Open EarPair / Quit EarPair |
| 概览 / 声音 / 网络 / 连接 | Overview / Sound / Network / Connection |
| 音量 | Volume |
| 音量平衡 | Auto level |
| 目标响度：柔和 / 标准 / 响亮 | Target loudness: Soft / Standard / Loud |
| 当前增益 | Current gain |
| 静音 / 取消静音 | Mute / Unmute |
| 左右（平衡） | Balance |
| 输出 | Output |
| 缓冲 | Buffer |
| 丢包 | Packet loss |
| 收到 | Packets received |
| 卡顿 | Dropouts |
| 迟到 | Late packets |
| 跳过（延迟裁剪） | Latency trims |
| 抖动 | Jitter |
| 码率 | Bitrate |
| 时钟漂移补偿 | Clock drift compensation |
| 时钟偏差 | Clock drift |
| 测量中… | Measuring… |
| 重置统计 | Reset Statistics (Mac) |
| 复制地址 | Copy Address (Mac) |
| 地址 / 端口 / 格式 | Address / Port / Format |
| 已播放 | Time played |
| 单声道 / 立体声 | Mono / Stereo |
| Windows 电脑 | Windows PC |
| 没有输出设备 | No output device |
| 本地网络 | Local network |

## Adding a language

- **Mac:** add `<code>.lproj/Localizable.strings` next to the existing `zh-Hans.lproj` in each target that has one (EarPairCore, EarPairUI), add `<code>.lproj/InfoPlist.strings` under `macos/Resources`, and add the code to `CFBundleLocalizations` in `macos/Resources/Info.plist`. Then run `macos/scripts/check-strings.sh`: it fails when a key has no translation, a translation is unused, placeholders differ, or the languages in those places don't match.
- **Windows:** add `Strings.<culture>.resx` next to each of the three `Strings.resx` (EarPair.Sender.Core, EarPair.Sender, EarPair.App). In EarPair.App's file, set `ControlLanguage` to the tag WinUI should use for its own control texts (for example `ja-JP`), and add that WinUI folder to the keep-list of the `RemoveUnusedLanguages` target in `EarPair.App.csproj`. Then run the self-test, which checks every language it finds.
- Check the result in both apps' preview tools: `earpair-snapshot --lang <code>` on the Mac, `EarPair.exe --demo <state> --lang <culture>` on Windows.
