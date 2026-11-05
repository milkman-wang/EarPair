import AppKit
import EarPairCore
import EarPairUI
import SwiftUI

// 把菜单栏面板和主窗口各页渲染成 PNG（播放中 / 等待连接 × 浅色 / 深色），用来检查布局。
// 离屏渲染画不出 Liquid Glass（含玻璃的整块会变成空白），所以这里一律用 macOS 14 / 15 的样式，
// 玻璃效果要看真实窗口。用法：earpair-snapshot [输出目录]

setenv("EARPAIR_LEGACY_STYLE", "1", 1)

let outputDirectory = URL(fileURLWithPath: CommandLine.arguments.dropFirst().first ?? "snapshots", isDirectory: true)
try? FileManager.default.createDirectory(at: outputDirectory, withIntermediateDirectories: true)

let application = NSApplication.shared
application.setActivationPolicy(.prohibited)

var playing = ReceiverStats()
playing.state = .playing
playing.senderAddress = "192.168.1.157"
playing.format = StreamFormat(sampleRate: 48_000, channels: 2)
playing.packetsReceived = 69_467
playing.bufferedMs = 60.4
playing.targetMs = 60
playing.driftPPM = -1
playing.jitterMs = 5.0
playing.secondsPlayed = 340
playing.inputLevelDB = -17.6
playing.outputLevelDB = -9.4
playing.loudnessLUFS = -22.1
playing.levelingGainDB = 6.1

let idle = ReceiverStats()

/// 假的一分钟曲线
let history: [HistoryPoint] = (0..<200).map { i in
    let t = Double(i)
    return HistoryPoint(id: i * 3, bufferMs: 60 + 3 * sin(t / 7) + Double(i % 5) * 0.4, jitterMs: 5,
                        inputLevelDB: -20 + 6 * sin(t / 9), outputLevelDB: -12 + 7 * sin(t / 9) + 3 * sin(t / 2.3))
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
    for (state, stats) in [("playing", playing), ("idle", idle)] {
        for (look, appearance) in [("light", NSAppearance.Name.aqua), ("dark", NSAppearance.Name.darkAqua)] {
            let controller = ReceiverController(preview: stats,
                                                addresses: [LocalAddress(name: "Wi-Fi", address: "192.168.1.199")],
                                                bitrateKbps: state == "playing" ? 1587 : 0,
                                                history: state == "playing" ? history : [])
            render(MenuBarContent(controller: controller), name: "menu-\(state)-\(look)",
                   appearance: appearance, size: nil)
            for section in MainSection.allCases {
                render(MainWindow(controller: controller, initialSection: section),
                       name: "window-\(section.rawValue)-\(state)-\(look)",
                       appearance: appearance, size: CGSize(width: 900, height: 620))
            }
        }
    }
}
