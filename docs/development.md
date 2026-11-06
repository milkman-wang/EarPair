# Development

**English** | [简体中文](development.zh-CN.md)

How to build EarPair from source, run the tests, and find your way around the code. For installing and using EarPair, see the [README](../README.md).

## How it works

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

- **Audio**: uncompressed 16-bit stereo PCM, 240 frames per packet (5 ms at 48 kHz), about 1.6 Mbit/s. Format and test vectors: [protocol/audio-packet.md](../protocol/audio-packet.md).
- **Receiver**: puts packets back in order, fills gaps with silence, fading out and back in around them (no clicks), keeps a 60 ms buffer, resamples to absorb the clock difference between the two sound cards, and pulls latency back after Wi‑Fi hiccups. Playback goes through AVAudioEngine, so macOS mixes it with the Mac's own audio.
- **Control channel** on the same port: HELLO (sender name and device type), STATUS once per second (playing, busy, muted, output device), BYE when the sender stops, with the reason (stopped, network or audio device). After a network drop the PC keeps probing and the Mac keeps pinging the PC for a minute, so the stream comes back as soon as the network does. Spec: [protocol/control-packet.md](../protocol/control-packet.md).
- **Discovery**: the Mac advertises `_earpair._udp` over Bonjour; Windows finds it with the DNS-SD support built into Windows.

## Repository layout

```
protocol/                   audio and control packet specs, with test vectors
macos/                      Swift package (macOS 14+)
  Sources/EarPairCore/      receiver core: packets, buffering, drift, leveling, UDP, Bonjour, output
  Sources/EarPairUI/        menu bar panel, main window and notifications (SwiftUI)
  Sources/EarPair/          app entry point
  Sources/earpair-recv/     command-line receiver
  Sources/earpair-snapshot/ renders the UI to PNG files
  Tests/EarPairCoreTests/   unit tests and long-running simulations
  scripts/build-app.sh      builds EarPair.app
windows/                    .NET 10
  EarPair.Sender.Core/      capture, conversion, packets, UDP, control packets, local mute
  EarPair.App/              WinUI 3 tray app (Windows App SDK 2.6, unpackaged, self-contained)
  EarPair.Sender/           command-line sender
  EarPair.Sender.SelfTest/  self-test (runs on macOS too)
  build.ps1                 packages the zips and single-file executables
tools/                      test sender, recording analysis, end-to-end test, icon generator
docs/                       this page and README images
```

## Building

### Mac

Requires Xcode 26 or later, which runs on macOS 15.6 or later. The app itself runs on macOS 14 and up; building with the macOS 26 SDK turns on Liquid Glass on macOS 26 and later.

```bash
cd macos
./scripts/build-app.sh        # → macos/build/EarPair.app
```

- Always package with this script rather than copying the `swift build` output. SwiftPM records the minimum macOS version as the SDK version, which makes macOS run the app in compatibility mode (old style, no Liquid Glass); the script stamps the real SDK version with `vtool`.
- The app is ad-hoc signed by default. macOS identifies apps by signature for the Local Network permission, so every rebuild asks again. With an Apple Development certificate: `SIGN_IDENTITY="Apple Development: …" ./scripts/build-app.sh`.
- If `swift build` fails with an llbuild / dyld error, the selected Command Line Tools don't match the SDK. The script switches to the Xcode in `/Applications` automatically, or set `DEVELOPER_DIR` yourself.

### Windows

Requires Windows 10 (version 2004) or later and the [.NET 10 SDK](https://dotnet.microsoft.com/download/dotnet/10.0). Visual Studio is not needed.

```powershell
powershell -ExecutionPolicy Bypass -File windows\build.ps1
```

This writes `EarPair-<version>-win-x64.zip`, `…-win-arm64.zip` and the single-file command-line senders to `dist\`. The zips include the .NET runtime and the Windows App SDK. Before zipping, the script checks the publish folder (runtime included, `.pri` present, no stray AI components) and fails if something is off.

## Testing

```bash
swift test --package-path macos                           # Mac unit tests (add -c release to run faster)
dotnet run --project windows/EarPair.Sender.SelfTest      # Windows sender self-test; runs on macOS too
dotnet run --project windows/EarPair.Sender.SelfTest -- hello 127.0.0.1   # HELLO → STATUS round trip with a receiver
tools/e2e.sh                                              # end to end over real UDP, recorded and analyzed (needs numpy)
```

- The unit tests include 30-minute clock-drift simulations (±200 ppm), packet loss and reordering, loudness leveling and the limiter, and the control packets (byte-exact test vectors shared with the C# side).
- `tools/e2e.sh` runs three rounds of about 30 seconds: clock drift, a bad network, and the C# packet code feeding the Swift receiver. The last round is skipped without .NET.

No Windows machine at hand? Run the receiver and the Python test sender on the Mac, both from the repo root:

```bash
swift build --package-path macos -c release
macos/.build/release/earpair-recv               # plays through the current output; add --null-output for silence
python3 tools/test_sender.py 127.0.0.1          # in another terminal: a 440 Hz tone
python3 tools/test_sender.py 127.0.0.1 --clock-ppm 200 --jitter-ms 8 --loss 1 --reorder 2
```

### Checking the UI

- Mac: `swift run --package-path macos -c release earpair-snapshot <folder>` renders the menu bar panel and the window's overview in every state, plus the other window pages while waiting and playing, in light and dark. Offscreen rendering can't draw Liquid Glass, so these use the macOS 14/15 style. With `--readme` before the folder, it renders the Mac screenshots in `docs/images`.
- Windows: Debug builds have a demo mode that draws each state from fake data, with no capture and no network:

  ```powershell
  dotnet build windows\EarPair.App -c Debug -r win-x64 -p:Platform=x64
  windows\EarPair.App\bin\x64\Debug\net10.0-windows10.0.26100.0\win-x64\EarPair.exe --demo playing --theme dark
  ```

  States: `pick` `off` `connecting` `playing` `muted` `legacy` `noresponse` `waiting` `busy` `nosource` `failed` `postmute`.

Icons are generated by `tools/make-icons.swift` (Windows `.ico` and tray icons, Mac `.icns`).

## Command-line tools

```
earpair-recv [--port N] [--buffer-ms N] [--duration S] [--stats S] [--no-drift] [--null-output [--record PATH]]
EarPair.Sender.exe <Mac IP> [--port N] [--device "name"] [--list-devices] [--frames N] [--no-keepalive]
```

The command-line sender doesn't discover Macs and doesn't mute the PC's speakers. Without `--device` it follows the system default output.

## Logs

- Mac: `log stream --level info --predicate 'subsystem == "app.earpair"'` (Bonjour, UDP, notifications and reopen events).
- Windows: `%LOCALAPPDATA%\EarPair\logs`, kept for 7 days. In the window: **⋯ → 打开日志文件夹** (open log folder).

## Known limitations

- No encryption or authentication: anything on the network can send audio to the receiver. A pairing code and signed packets are planned.
- Captures the whole output device. Per-app capture is planned for 0.3.
- Windows doesn't sleep while sending, because the sender keeps a silent stream playing so capture never stalls. When a Mac that has been answering goes quiet for 10 seconds, both the app and the CLI pause (and the PC can sleep) until it's back; the CLI can also drop the silent stream with `--no-keepalive`.
- Pressing the Windows volume keys unmutes the PC's speakers (system behavior). Turn sending off and on again to mute them. Loopback capture is taken before the Windows volume, so set the volume on the Mac.
- Neither app is code-signed yet: macOS asks for Local Network permission after each rebuild, and Windows SmartScreen warns on first run.
- If "Spatialize Stereo" is turned on for EarPair in Control Center, macOS processes its audio again. Turn it off for now.
- The clock-drift figure in the main window settles about a minute after playback starts.

## Tested on

- MacBook Air (Apple silicon), macOS 27.3, with AirPods Pro.
- Windows 11 ARM64 in Parallels: the full app (arm64 package); the x64 package launched under emulation.
- A real Windows PC with the 0.1 command-line sender: about 6 minutes, 69,467 packets, none lost.
- The macOS 14 and 15 styles have only been checked in offscreen renders.
