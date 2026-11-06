<p align="center">
  <img src="docs/images/icon.png" width="128" alt="EarPair icon">
</p>

<h1 align="center">EarPair</h1>

<p align="center">Hear your Windows PC through the AirPods on your Mac.</p>

<p align="center"><b>English</b> | <a href="README.zh-CN.md">简体中文</a></p>

<p align="center">
  <picture>
    <source media="(prefers-color-scheme: dark)" srcset="docs/images/mac-window-dark.png">
    <img src="docs/images/mac-window-light.png" width="780" alt="EarPair on the Mac: sound from a Windows PC plays through the Mac to AirPods Pro">
  </picture>
</p>

Your AirPods stay connected to your Mac. EarPair sends your Windows PC's sound over your local network, and the Mac plays it together with its own audio. No Bluetooth switching, no extra cables, and your audio never leaves your network: no account, no cloud, no telemetry.

## Features

- **Both computers in one pair of headphones.** The PC plays alongside the Mac, through whatever the Mac is using: AirPods, speakers or headphones.
- **Finds your Mac by itself.** The Windows app lists the Macs on your network. Click one to start, no IP address needed.
- **Even loudness.** Auto-leveling keeps quiet and loud PC audio at a steady volume.
- **A quiet PC.** Mutes the PC's own speakers while sending and turns them back on when you stop.
- **Rides out Wi‑Fi hiccups.** Lost or late packets and clock drift between the two machines don't cause clicks or a growing delay.
- **Tells a stop from a dropout.** The Mac shows a notification when a PC connects or stops sending. If the network drops instead, the notification says so and EarPair reconnects by itself.
- **Stays out of the way.** It lives in the Mac's menu bar and in the Windows notification area, and can start with Windows.
- **Nothing to install on Windows.** Unzip and run; the .NET runtime is included.

<p align="center">
  <picture>
    <source media="(prefers-color-scheme: dark)" srcset="docs/images/mac-menu-dark.png">
    <img src="docs/images/mac-menu-light.png" height="200" alt="EarPair's menu bar panel on the Mac">
  </picture>
  &nbsp;&nbsp;
  <picture>
    <source media="(prefers-color-scheme: dark)" srcset="docs/images/windows-card-dark.png">
    <img src="docs/images/windows-card-light.png" height="200" alt="EarPair on Windows, sending to a MacBook Air">
  </picture>
</p>

## Requirements

- **Mac:** macOS 14 or later (Liquid Glass on macOS 26 and later)
- **PC:** Windows 10 (version 2004) or Windows 11, x64 or Arm64
- Both on the same local network

The interface is in Simplified Chinese for now. Button names below are quoted as they appear, with an English gloss.

## Getting started

1. **On the Mac,** build and open EarPair (needs Xcode 26 or later, which runs on macOS 15.6 or later):

   ```bash
   git clone https://github.com/milkman-wang/EarPair.git
   cd EarPair/macos && ./scripts/build-app.sh
   open build/EarPair.app
   ```

   An ear appears in the menu bar. When macOS asks whether EarPair may find devices on your local network, click **Allow**: that's how the PC finds the Mac. Allow notifications as well, so you know when a PC connects or drops off. Move `build/EarPair.app` to Applications to keep it.

2. **On the PC,** download `EarPair-0.2.0-win-x64.zip` (`win-arm64` for Arm PCs) from [Releases](https://github.com/milkman-wang/EarPair/releases/latest), unzip it anywhere and run `EarPair\EarPair.exe`.

3. **Click your Mac** in the list. The PC's sound now plays on the Mac, and the PC's speakers stay quiet until you stop.

Closing the window keeps EarPair running in the notification area (Windows 11 may tuck the icon under **^**). Turn on **开机时启动** (start at login) to have it ready after a restart.

> [!NOTE]
> EarPair isn't code-signed yet. The first time you run it, Windows may show **Windows protected your PC**: click **More info → Run anyway**. On the Mac, each rebuild counts as a new app, so macOS asks for local network access again.

## Good to know

- **Latency is about 0.2–0.3 seconds**, AirPods included. Music and notification sounds are fine, but video played on the PC will be out of sync with the picture.
- **The whole PC is captured,** not individual apps. Per-app capture is planned.
- **Use it on networks you trust.** Audio isn't encrypted yet, and anything on the network can send to your Mac.
- **The PC stays awake while sending.** Sending pauses by itself when the Mac goes away and resumes when it's back.
- **Set the volume on the Mac.** The PC's own volume doesn't change what you hear, and the Windows volume keys unmute the PC's speakers; switch sending off and on to mute them again.
- **To remove EarPair from the PC,** turn off **开机时启动** (start at login) first, then delete the folder.

## Troubleshooting

| Problem | What to do |
|---|---|
| The PC doesn't list your Mac | Use the same network on both (not a guest network that keeps devices apart), set the Windows network profile to **Private network**, and turn off any VPN. On the Mac, check **System Settings → Privacy & Security → Local Network**. You can also click **输入地址** (enter address) and type the Mac's IP, shown in the Mac's menu bar panel. |
| No ear in the Mac's menu bar | On macOS 26 and later, open **System Settings → Menu Bar** and turn on EarPair under **Allow in the Menu Bar**. |
| No notifications on the Mac | Open **System Settings → Notifications → EarPair** and turn on **Allow Notifications**. |
| It stopped working after rebuilding the Mac app | Allow local network access for EarPair again, as above. |
| The PC's speakers are playing again | The Windows volume keys unmuted them. Switch sending off and on. |
| Something else | On Windows, open **⋯ → 打开日志文件夹** (open log folder) and look at the latest log. |

## Command-line sender

Prefer a terminal on the PC? The command-line sender is a single file, also on the Releases page:

```powershell
.\EarPair.Sender-0.2.0-win-x64.exe 192.168.1.20
```

It doesn't look for Macs or mute the PC. Run it with `--help` to see the options.

## How it works

The Windows app captures what the PC is playing and streams it to the Mac as uncompressed audio over UDP. The Mac keeps a short buffer, smooths over lost packets and the clock difference between the two machines, and plays the stream like any other app, so macOS mixes it with everything else. The two apps also swap names and status, which is how both can draw the whole route. Packet formats: [audio](protocol/audio-packet.md), [control](protocol/control-packet.md).

## Building from source

- **Mac:** `macos/scripts/build-app.sh` with Xcode 26 or later.
- **Windows:** `powershell -ExecutionPolicy Bypass -File windows\build.ps1` with the [.NET 10 SDK](https://dotnet.microsoft.com/download/dotnet/10.0). No Visual Studio needed; the zips land in `dist\`.

Tests, tools and the project layout are in [docs/development.md](docs/development.md).

## Roadmap

- Choose which PC apps to send
- Pairing, encryption and signed builds
- Spatial audio that places the PC's sound toward its screen
