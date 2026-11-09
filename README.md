<p align="center">
  <img src="docs/images/icon.png" width="128" alt="EarPair icon">
</p>

<h1 align="center">EarPair</h1>

<p align="center">Hear your Windows PC through the AirPods on your Mac.</p>

<p align="center">
  <a href="https://github.com/milkman-wang/EarPair/releases/latest"><img src="https://img.shields.io/github/v/release/milkman-wang/EarPair" alt="Latest release"></a>
  <img src="https://img.shields.io/badge/macOS-14%2B-000000?logo=apple" alt="macOS 14+">
  <img src="https://img.shields.io/badge/Windows-10%202004%2B-0078D4?logo=windows" alt="Windows 10 2004+">
</p>

<p align="center"><b>English</b> | <a href="README.zh-CN.md">简体中文</a></p>

<p align="center">
  <picture>
    <source media="(prefers-color-scheme: dark)" srcset="docs/images/mac-window-dark.png">
    <img src="docs/images/mac-window-light.png" width="780" alt="EarPair on the Mac: sound from a Windows PC plays through the Mac to AirPods Pro">
  </picture>
</p>

EarPair streams a Windows PC's audio to a Mac over the local network. The Mac mixes it with its own sound and plays both through its current output (AirPods, headphones or speakers), so the headphones never switch between computers. No account, no cloud service, no telemetry.

## Features

| Feature | What it does | Notes |
|---|---|---|
| **Discovery** | The Windows app lists every Mac running EarPair on the local network (Bonjour). | Bonjour doesn't cross subnets, guest networks or VPNs. Use **Enter address** there. |
| **Capture** | Captures every app on the PC except EarPair, before the PC's own volume and mute (process loopback). | To capture a single output device instead, pick it under **Sound source**. Windows builds without process loopback always capture an output device. |
| **Mute this PC while sending** | Silences the PC's speakers while sending and restores them when sending stops. | The Windows volume keys unmute them. A few sound cards can't be captured while muted; EarPair then unmutes that device and says so. |
| **Auto level** (Mac) | Holds the PC's loudness at a steady target (ITU‑R BS.1770). | Target under **Sound → Target loudness**. Turn it off when exact levels matter. |
| **Network resilience** (Mac) | Reorders late packets, fades over lost ones, compensates the clock difference between the two machines and sizes the buffer from recent network conditions (20–150 ms). | Turn off **Auto buffer** on the **Network** page to set a fixed buffer. |
| **Standby** | After 3 s of silence the PC stops streaming and keeps only a handshake. Sound resumes as soon as something plays. | A PC in standby still holds the Mac. |
| **One PC at a time** (Mac) | The Mac plays one PC. Other PCs show **Mac is busy** and the name of the one playing. | They start automatically once the Mac is free. |
| **Connection notices** (Mac) | Notifies when a PC connects, stops or drops off the network, and reconnects by itself after a dropout. | Requires notification permission. |
| **Spatial audio** (Mac) | With head-tracking AirPods, the PC's sound comes from the PC's screen and the Mac's from the Mac's, fixed in place as you turn your head. The screen you look away from gets quieter. | Set up once on the **Spatial Audio** page by facing each screen. **Move this Mac's sound too** needs macOS 14.2 or later. |
| **Updates** | Both apps check GitHub Releases (Mac at launch and every 6 h, Windows shortly after start and every 12 h) and install with one click. | Only the latest version number is requested. The Mac app must be in a folder it can write to, such as Applications. |
| **Background operation** | Lives in the Mac menu bar and the Windows notification area. **Start at login** on Windows. | The PC doesn't sleep while sending; sending pauses after the Mac has been unreachable for 10 s. |

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

| | Mac | PC |
|---|---|---|
| **System** | macOS 14 or later | Windows 10 version 2004 or later, Windows 11 |
| **Processor** | Apple silicon or Intel | x64 or Arm64 |
| **Network** | Same local network as the PC | About 1.6 Mbit/s while playing |
| **Spatial audio** | AirPods or Beats with head tracking | — |

Both apps follow the system language: English or Simplified Chinese.

## Installation

1. **Mac:** download `EarPair-<version>-macos-universal.dmg` from [Releases](https://github.com/milkman-wang/EarPair/releases/latest), drag **EarPair** to **Applications** and open it from there. Allow **Local Network** access when asked.
2. **PC:** download `EarPair-<version>-win-x64-setup.exe` (`win-arm64` for Arm PCs) and run it. It installs for the current user, without administrator rights.
3. On the PC, click your Mac in the list.

### Permissions and first-run prompts

| Prompt | Platform | Needed for | If declined |
|---|---|---|---|
| Local Network | Mac | Discovery and receiving audio | **System Settings → Privacy & Security → Local Network** |
| Notifications | Mac | Connection notices | Optional |
| Motion | Mac | Spatial audio | **Open System Settings** on the **Spatial Audio** page |
| System Audio Recording | Mac 14.2+ | **Move this Mac's sound too** | Only the PC's sound is placed; **Open System Settings** on the **Spatial Audio** page |
| "Apple could not verify EarPair" | Mac | Unsigned build | **System Settings → Privacy & Security → Open Anyway** |
| "Windows protected your PC" | PC | Unsigned installer | **More info → Run anyway** |

> [!IMPORTANT]
> Builds aren't code-signed yet. macOS treats every new version as a new app and asks for Local Network access again after each update.

## Security and privacy

- Audio is sent unencrypted, and the Mac accepts audio from any device on the network. Use EarPair only on networks you trust.
- The only internet traffic is the update check against the GitHub Releases API.

## Troubleshooting

### The PC doesn't list the Mac

1. Check that EarPair is running on the Mac: the ear icon is in the menu bar.
2. Put both computers on the same network and subnet. Guest networks and routers with AP or client isolation block traffic between devices.
3. On Windows, set the network profile to **Private**: **Settings → Network & internet → Wi‑Fi or Ethernet → Network profile type**.
4. Disconnect VPNs on both computers.
5. On the Mac, turn on EarPair under **System Settings → Privacy & Security → Local Network**. If the macOS firewall is on, allow incoming connections for EarPair.
6. If the Mac still isn't listed, click **Enter address** on the PC and type the Mac's IP address, shown in the Mac's menu bar panel while it waits and on the **Connection** page. EarPair uses UDP port 47800.

### Other problems

| Symptom | Cause and fix |
|---|---|
| **EarPair isn't open on the Mac** | The Mac is reachable but nothing listens on port 47800. Open EarPair on the Mac. |
| **Can't reach the Mac** | Packets aren't getting through. Work through the list above. Sending resumes when the Mac is reachable again. |
| **Waiting for the Mac**, although EarPair is open on it | The Mac's replies don't reach the PC, often because of a firewall on the PC. Click **Send anyway**. |
| **Mac is busy** | Another PC is playing on the Mac. Stop sending on that PC. |
| **No sound source** | Windows has no active output device. Connect or enable one, or pick another under **Sound source**. |
| Mac shows **Can't receive** | Another program uses port 47800, for example a second copy of EarPair or `earpair-recv`. Quit it. |
| Mac shows **Can't play** | No usable output device. Select one under **System Settings → Sound → Output**. |
| PC shows **Playing**, but nothing is heard | Check **Mute** and the volume in the Mac's menu bar panel, and the Mac's output device. |
| Crackles or dropouts | Weak Wi‑Fi. Use 5 GHz or Ethernet and check **Packet loss** on the Mac's **Network** page. With **Auto buffer** off, choose a larger buffer. |
| The PC's speakers play again | The Windows volume keys unmuted them. Turn sending off and on. |
| Spatial audio can't be turned on | Connect head-tracking AirPods to the Mac and allow motion data (**Open System Settings** on the **Spatial Audio** page). |
| Spatial audio sounds processed twice | Turn off **Spatialize Stereo** for EarPair in Control Center. |
| Sound sits in the wrong place | Face the Mac and click **Center on Mac**, or **Set Up Again…**. |
| No ear icon in the menu bar | macOS 26 and later: **System Settings → Menu Bar → Allow in the Menu Bar**, turn on EarPair. |
| No notifications | **System Settings → Notifications → EarPair → Allow Notifications**. |
| Mac update fails with "can't replace itself" | Move EarPair to **Applications** instead of running it from the disk image or another protected folder. |
| Stopped working after a Mac update | Allow Local Network access again. |
| PC update fails | Click **Open download page** and run the new installer by hand. |

### Logs

- **Windows:** **⋯ → Open log folder** (`%LOCALAPPDATA%\EarPair\logs`, kept for 7 days).
- **Mac:** `log stream --level info --predicate 'subsystem == "app.earpair"'`

When reporting a problem, include the EarPair, Windows and macOS versions and the relevant log.

## How it works

The Windows app captures the PC's audio and sends it to the Mac as uncompressed 16‑bit stereo PCM over UDP, in 5 ms packets. The Mac buffers the stream, conceals losses, corrects clock drift and plays it through AVAudioEngine, so macOS mixes it with everything else. A control channel on the same port carries names, status and standby. Details: [docs/development.md](docs/development.md), [audio packets](protocol/audio-packet.md), [control packets](protocol/control-packet.md).

## Building from source

| Platform | Command | Requires |
|---|---|---|
| Mac | `macos/scripts/build-app.sh` | Xcode 26 or later |
| Windows | `powershell -ExecutionPolicy Bypass -File windows\build.ps1` | [.NET 10 SDK](https://dotnet.microsoft.com/download/dotnet/10.0); [Inno Setup 6](https://jrsoftware.org/isinfo.php) for installers (zips without it) |

Output goes to `macos/build/` and `dist\`. Tests, tools and the project layout: [docs/development.md](docs/development.md).

## Roadmap

- Choose which PC apps to send
- Pairing and encryption
- Signed and notarized builds
