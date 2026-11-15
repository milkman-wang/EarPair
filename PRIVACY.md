# Privacy policy

[中文](#隐私政策)

EarPair has no account, no analytics and no crash reporting. It talks to two kinds of computers.

**The Mac you choose.** The Windows app finds Macs on your local network with Bonjour (mDNS) and sends the PC's sound, its name and the sending status only to the Mac you pick. The Mac app answers with its name, output device and playback status. This traffic stays on your local network. Audio is not encrypted, so use EarPair on networks you trust.

**GitHub, for updates.** Unless you turn it off, both apps ask the GitHub Releases API (`api.github.com`) for the latest version: the Mac app at launch and every 6 hours, the Windows app shortly after it starts and every 12 hours. The request carries no information about you or your PC beyond what any web request does: GitHub sees your IP address and a user agent. An update is downloaded from GitHub only when you choose to install it. GitHub's handling of this data is described in the [GitHub General Privacy Statement](https://docs.github.com/site-policy/privacy-policies/github-general-privacy-statement).

To turn automatic update checks off:

- **Windows:** clear **Check for updates automatically** during setup, or switch it off in EarPair's window.
- **Mac:** switch off **Check for updates automatically** on the **Connection** page.

You can still check by hand from the **⋯** menu on Windows or **Check for Updates…** in the Mac menu bar panel.

**On your computer.** Settings and logs stay on your computer: `%LOCALAPPDATA%\EarPair` on Windows, the app's preferences and the unified log (subsystem `app.earpair`) on the Mac. Nothing is sent anywhere else.

---

# 隐私政策

EarPair 没有账号，不做统计，也不上传崩溃报告。它只和两类电脑通信。

**你选的那台 Mac。** Windows 端用 Bonjour（mDNS）在局域网里查找 Mac，只把电脑的声音、电脑名和发送状态发给你选的那台 Mac；Mac 端回复它的名字、输出设备和播放状态。这些数据只在你的局域网里传输。声音没有加密，请只在信任的网络里使用。

**GitHub，用来检查更新。** 除非你关掉，两端都会向 GitHub Releases API（`api.github.com`）查询最新版本：Mac 端在启动时及每 6 小时一次，Windows 端在启动后不久及每 12 小时一次。和访问任何网站一样，GitHub 能看到你的 IP 地址和客户端标识，请求里没有关于你或你电脑的其他信息。只有你选择安装更新时，才会从 GitHub 下载新版本。GitHub 如何处理这些数据，见 [GitHub 隐私声明](https://docs.github.com/site-policy/privacy-policies/github-general-privacy-statement)。

关掉自动检查更新：

- **Windows**：安装时取消勾选 **自动检查更新**，或在 EarPair 窗口里关掉它。
- **Mac**：在 **连接** 页关掉 **自动检查更新**。

关掉后仍可以手动检查：Windows 在 **⋯** 菜单里，Mac 在菜单栏面板的 **检查更新…**。

**你的电脑上。** 设置和日志只保存在你的电脑上：Windows 在 `%LOCALAPPDATA%\EarPair`，Mac 在 App 的偏好设置和系统日志（子系统 `app.earpair`）里，不会发往别处。
