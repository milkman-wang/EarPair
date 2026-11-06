import AppKit
import EarPairCore
import EarPairUI
import SwiftUI

// 把菜单栏面板和主窗口各页渲染成 PNG，检查各种状态的布局。
// 离屏渲染画不出 Liquid Glass（含玻璃的整块会变成空白），所以这里一律用 macOS 14 / 15 的样式，
// 玻璃效果要看真实窗口。用法：earpair-snapshot [输出目录]

setenv("EARPAIR_LEGACY_STYLE", "1", 1)

let outputDirectory = URL(fileURLWithPath: CommandLine.arguments.dropFirst().first ?? "snapshots", isDirectory: true)
try? FileManager.default.createDirectory(at: outputDirectory, withIntermediateDirectories: true)

let application = NSApplication.shared
application.setActivationPolicy(.prohibited)

let addresses = [LocalAddress(name: "Wi-Fi", address: "192.168.1.199")]

func streaming(_ state: PlaybackState, input: Double, output: Double) -> ReceiverStats {
    var stats = ReceiverStats()
    stats.state = state
    stats.senderAddress = "192.168.1.157"
    stats.format = StreamFormat(sampleRate: 48_000, channels: 2)
    stats.packetsReceived = 69_467
    stats.packetsLost = 3
    stats.bufferedMs = 60.4
    stats.targetMs = 60
    stats.driftPPM = -1
    stats.jitterMs = 5.0
    stats.secondsPlayed = 340
    stats.inputLevelDB = input
    stats.outputLevelDB = output
    stats.loudnessLUFS = -22.1
    stats.levelingGainDB = 6.1
    return stats
}

/// 假的一分钟历史：带一点起伏的声音，中间偶尔丢包
func history(sound: Bool) -> [HistoryPoint] {
    (0..<200).map { i in
        let t = Double(i)
        let level = sound ? -20 + 9 * sin(t / 6) + 5 * sin(t / 1.7) : -120
        return HistoryPoint(id: i * 3, time: Date().addingTimeInterval(Double(i - 199) * 0.3),
                            bufferMs: 60 + 3 * sin(t / 7), jitterMs: 5, inputLevelDB: level,
                            outputLevelDB: level + 6, packetsLost: i == 120 ? 2 : i == 160 ? 1 : 0,
                            underruns: 0, muted: false)
    }
}

struct Scenario {
    var name: String
    var stats: ReceiverStats
    var link: LinkState
    var hasSound = true
    var muted = false
    /// 上次播放过的发送端（等待时的占位）
    var lastName: String?
    var lastKind: DeviceKind?
}

func ended(bySender: Bool) -> ReceiverStats {
    var stats = streaming(.idle, input: -120, output: -120)
    stats.endedBySender = bySender
    return stats
}

let scenarios = [
    Scenario(name: "waiting", stats: ReceiverStats(), link: .waiting, hasSound: false),
    Scenario(name: "waiting-remembered", stats: ReceiverStats(), link: .waiting, hasSound: false,
             lastName: "DESKTOP-7Q2", lastKind: .desktop),
    Scenario(name: "connecting", stats: streaming(.buffering, input: -120, output: -120), link: .connecting,
             hasSound: false),
    Scenario(name: "playing", stats: streaming(.playing, input: -17.6, output: -9.4), link: .playing),
    Scenario(name: "silent", stats: streaming(.playing, input: -120, output: -120), link: .playing, hasSound: false),
    Scenario(name: "muted", stats: streaming(.playing, input: -17.6, output: -120), link: .playing, muted: true),
    Scenario(name: "stopped", stats: ended(bySender: true), link: .stopped, hasSound: false),
    Scenario(name: "disconnected", stats: ended(bySender: false), link: .disconnected, hasSound: false),
    Scenario(name: "receive-failed", stats: ReceiverStats(),
             link: .receiveFailed("端口 47800 被其他程序占用，收不到 Windows 的声音。"), hasSound: false),
    Scenario(name: "output-failed", stats: streaming(.playing, input: -17.6, output: -120),
             link: .outputFailed("无法打开音频输出：设备不可用")),
]

@MainActor
func controller(for scenario: Scenario) -> ReceiverController {
    let hasSender = scenario.stats.senderAddress != nil
    return ReceiverController(preview: scenario.stats, addresses: addresses,
                              bitrateKbps: scenario.stats.state == .idle ? 0 : 1587, muted: scenario.muted,
                              history: hasSender ? history(sound: scenario.hasSound) : [],
                              linkState: scenario.link, hasSound: scenario.hasSound,
                              senderName: hasSender ? "DESKTOP-7Q2" : nil, senderKind: hasSender ? .desktop : nil,
                              lastSenderName: scenario.lastName, lastSenderKind: scenario.lastKind)
}

@MainActor
func render<Content: View>(_ view: Content, name: String, appearance: NSAppearance.Name, size: CGSize?) {
    let hosting = NSHostingView(rootView: view.background(Color(nsColor: .windowBackgroundColor)))
    hosting.appearance = NSAppearance(named: appearance)
    hosting.frame = CGRect(origin: .zero, size: size ?? hosting.fittingSize)
    let window = NSWindow(contentRect: hosting.frame, styleMask: [.titled], backing: .buffered, defer: false)
    window.appearance = NSAppearance(named: appearance)
    window.contentView = hosting
    hosting.layoutSubtreeIfNeeded()
    RunLoop.main.run(until: Date().addingTimeInterval(0.4))
    hosting.layoutSubtreeIfNeeded()
    guard let bitmap = hosting.bitmapImageRepForCachingDisplay(in: hosting.bounds) else { return }
    hosting.cacheDisplay(in: hosting.bounds, to: bitmap)
    let url = outputDirectory.appendingPathComponent("\(name).png")
    try? bitmap.representation(using: .png, properties: [:])?.write(to: url)
    print(url.path)
}

MainActor.assumeIsolated {
    let looks: [(String, NSAppearance.Name)] = [("light", .aqua), ("dark", .darkAqua)]
    for scenario in scenarios {
        for (look, appearance) in looks {
            let model = controller(for: scenario)
            render(MenuBarContent(controller: model), name: "panel-\(scenario.name)-\(look)",
                   appearance: appearance, size: nil)
            render(MainWindow(controller: model, initialSection: .overview),
                   name: "window-overview-\(scenario.name)-\(look)", appearance: appearance,
                   size: CGSize(width: 900, height: 640))
        }
    }
    for scenario in scenarios where ["waiting", "playing"].contains(scenario.name) {
        for (look, appearance) in looks {
            let model = controller(for: scenario)
            for section in MainSection.allCases where section != .overview {
                render(MainWindow(controller: model, initialSection: section),
                       name: "window-\(section.rawValue)-\(scenario.name)-\(look)", appearance: appearance,
                       size: CGSize(width: 900, height: 640))
            }
        }
    }
    // 连接页的“已停止”和带上次名字的等待
    for scenario in scenarios where ["stopped", "waiting-remembered"].contains(scenario.name) {
        render(MainWindow(controller: controller(for: scenario), initialSection: .connection),
               name: "window-connection-\(scenario.name)-light", appearance: .aqua, size: CGSize(width: 900, height: 640))
    }
    // 最小、最大窗口：名字不重叠，路线居中
    for scenario in scenarios where scenario.name == "playing" {
        for size in [CGSize(width: 760, height: 520), CGSize(width: 1120, height: 640)] {
            render(MainWindow(controller: controller(for: scenario), initialSection: .overview),
                   name: "window-overview-playing-\(Int(size.width))x\(Int(size.height))", appearance: .aqua,
                   size: size)
        }
    }
}
