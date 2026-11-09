import AppKit
import EarPairCore
import EarPairUI
import SwiftUI

// 把菜单栏面板和主窗口各页渲染成 PNG，检查各种状态的布局。
// 离屏渲染画不出 Liquid Glass（含玻璃的整块会变成空白），所以这里一律用 macOS 14 / 15 的样式，
// 玻璃效果要看真实窗口。
// 用法：earpair-snapshot [--lang 语言] [输出目录]
//       earpair-snapshot --readme [--lang 语言] [输出目录]   只渲染 README 用的几张图，设备名用通用的名字
// --lang：界面用哪种语言（en、zh-Hans……），不填就跟系统语言

setenv("EARPAIR_LEGACY_STYLE", "1", 1)

var readmeMode = false
var language: String?
var outputPath: String?
var arguments = CommandLine.arguments.dropFirst()
while let argument = arguments.popFirst() {
    switch argument {
    case "--readme": readmeMode = true
    case "--lang":
        guard let value = arguments.popFirst(), !value.hasPrefix("-") else {
            FileHandle.standardError.write(Data("--lang 后面要跟语言代码，比如 en、zh-Hans\n".utf8))
            exit(2)
        }
        language = value
    case let option where option.hasPrefix("-"):
        FileHandle.standardError.write(Data("不认识的选项：\(option)\n".utf8))
        exit(2)
    default: outputPath = argument
    }
}
// README 的图分中英文两套，放在不同目录：不指定语言就会跟着系统语言写错地方
if readmeMode && language == nil {
    FileHandle.standardError.write(Data("--readme 要指定 --lang：en 渲染到 docs/images，zh-Hans 渲染到 docs/images/zh-CN\n".utf8))
    exit(2)
}
// 必须在任何 Bundle 查找之前：整个进程（包括 EarPairUI、EarPairCore 的资源包和系统框架）都按这个语言找文字。
// 命令行工具链接了一份允许混合本地化的 Info.plist（Package.swift），资源包才会按这个设置选翻译
if let language {
    var domain = UserDefaults.standard.volatileDomain(forName: UserDefaults.argumentDomain)
    domain["AppleLanguages"] = [language]
    UserDefaults.standard.setVolatileDomain(domain, forName: UserDefaults.argumentDomain)
}
let outputDirectory = URL(fileURLWithPath: outputPath ?? "snapshots", isDirectory: true)
try? FileManager.default.createDirectory(at: outputDirectory, withIntermediateDirectories: true)

/// 渲染出来的界面是不是中文：截图里那些不归界面管的文字（设备名、系统给的出错原因）跟着换
let chinese = Bundle.preferredLocalizations(from: ["en", "zh-Hans"]).first == "zh-Hans"
/// 系统按语言给设备起的名字：“milkman的MacBook Air”“milkman’s MacBook Air”
let owner = chinese ? "milkman的" : "milkman’s "

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

func ended(_ reason: EndReason) -> ReceiverStats {
    var stats = streaming(.idle, input: -120, output: -120)
    stats.endReason = reason
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
    Scenario(name: "standby", stats: streaming(.standby, input: -120, output: -120), link: .standby, hasSound: false),
    Scenario(name: "muted", stats: streaming(.playing, input: -17.6, output: -120), link: .playing, muted: true),
    Scenario(name: "stopped", stats: ended(.stopped), link: .stopped, hasSound: false),
    Scenario(name: "reconnecting", stats: ended(.network), link: .reconnecting, hasSound: false),
    Scenario(name: "disconnected", stats: ended(.network), link: .disconnected, hasSound: false),
    Scenario(name: "receive-failed", stats: ReceiverStats(),
             link: .receiveFailed(UDPReceiverError.bindFailed(port: ReceiverController.port, code: EADDRINUSE,
                                                              reason: "").localizedDescription),
             hasSound: false),
    Scenario(name: "output-failed", stats: streaming(.playing, input: -17.6, output: -120),
             link: .outputFailed(ReceiverController.outputFailureMessage(chinese ? "设备不可用" : "Device unavailable"))),
]

@MainActor
func controller(for scenario: Scenario) -> ReceiverController {
    let hasSender = scenario.stats.senderAddress != nil
    return ReceiverController(preview: scenario.stats, addresses: addresses,
                              bitrateKbps: scenario.stats.state == .idle ? 0 : 1587, muted: scenario.muted,
                              history: hasSender ? history(sound: scenario.hasSound) : [],
                              linkState: scenario.link, hasSound: scenario.hasSound,
                              senderName: hasSender ? "DESKTOP-7Q2" : nil, senderKind: hasSender ? .desktop : nil,
                              lastSenderName: scenario.lastName, lastSenderKind: scenario.lastKind,
                              macName: owner + "MacBook Air",
                              outputDevice: OutputDevice(name: owner + "AirPods Pro", transport: .bluetooth))
}

/// keepingTop：只保留上面这么高（pt）的部分
@MainActor
func render<Content: View>(_ view: Content, name: String, appearance: NSAppearance.Name, size: CGSize?,
                           keepingTop: CGFloat? = nil) {
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
    var output = bitmap
    if let keepingTop, let image = bitmap.cgImage {
        let height = Int((keepingTop / hosting.bounds.height * CGFloat(image.height)).rounded())
        if let top = image.cropping(to: CGRect(x: 0, y: 0, width: image.width, height: height)) {
            output = NSBitmapImageRep(cgImage: top)
        }
    }
    let url = outputDirectory.appendingPathComponent("\(name).png")
    try? output.representation(using: .png, properties: [:])?.write(to: url)
    print(url.path)
}

/// README 用的图：正在播放，通用的设备名，不带任何个人信息
@MainActor
func renderReadmeImages() {
    let looks: [(String, NSAppearance.Name)] = [("light", .aqua), ("dark", .darkAqua)]
    for (look, appearance) in looks {
        let model = ReceiverController(preview: streaming(.playing, input: -17.6, output: -9.4), addresses: addresses,
                                       bitrateKbps: 1587, history: history(sound: true), linkState: .playing,
                                       senderName: "DESKTOP-PC", senderKind: .desktop, macName: "MacBook Air",
                                       outputDevice: OutputDevice(name: "AirPods Pro", transport: .bluetooth))
        // 窗口最小高 520，概览页的内容到 440 左右就完了，下面的空白不要
        render(MainWindow(controller: model, initialSection: .overview), name: "mac-window-\(look)",
               appearance: appearance, size: CGSize(width: 900, height: 560), keepingTop: 440)
        render(MenuBarContent(controller: model), name: "mac-menu-\(look)", appearance: appearance, size: nil)
    }
}

MainActor.assumeIsolated {
    if readmeMode {
        renderReadmeImages()
        exit(0)
    }
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
    for scenario in scenarios where ["stopped", "waiting-remembered", "standby"].contains(scenario.name) {
        render(MainWindow(controller: controller(for: scenario), initialSection: .connection),
               name: "window-connection-\(scenario.name)-light", appearance: .aqua, size: CGSize(width: 900, height: 640))
    }
    // 空间音频页的各种状态，和打开了空间音频的菜单栏面板
    let spatialStates: [(String, SpatialController)] = [
        ("off", SpatialController(preview: .off, enabled: false, angle: nil)),
        ("active", SpatialController(preview: .active, enabled: true, angle: 52, macRelative: -9, senderRelative: 43)),
        ("setup-mac", SpatialController(preview: .needsSetup, enabled: true, angle: nil, setup: .mac, setupProgress: 0.6)),
        ("setup-sender", SpatialController(preview: .needsSetup, enabled: true, angle: nil, setup: .sender)),
        ("setup-review", SpatialController(preview: .needsSetup, enabled: true, angle: nil, setup: .review(angle: 52))),
        ("setup-failed", SpatialController(preview: .needsSetup, enabled: true, angle: nil, setup: .failed)),
        ("setup-nodata", SpatialController(preview: .needsSetup, enabled: true, angle: nil, setup: .noData)),
        ("waiting", SpatialController(preview: .waitingForSender, enabled: true, angle: -38, macRelative: 2,
                                      senderRelative: -36)),
        ("noheadphones", SpatialController(preview: .noHeadphones, enabled: true, angle: 52)),
        ("nopermission", SpatialController(preview: .noPermission, enabled: true, angle: 52)),
        ("mac-denied", SpatialController(preview: .active, enabled: true, angle: 52, macRelative: -9, senderRelative: 43,
                                         macPermissionDenied: true)),
    ]
    for (name, spatial) in spatialStates {
        let model = ReceiverController(preview: streaming(.playing, input: -17.6, output: -9.4), addresses: addresses,
                                       bitrateKbps: 1587, history: history(sound: true), linkState: .playing,
                                       senderName: "DESKTOP-7Q2", senderKind: .desktop, spatial: spatial)
        for (look, appearance) in looks where name == "active" || look == "light" {
            render(MainWindow(controller: model, initialSection: .spatial),
                   name: "window-spatial-state-\(name)-\(look)", appearance: appearance, size: CGSize(width: 900, height: 640))
        }
        if name == "active" {
            render(MenuBarContent(controller: model), name: "panel-spatial-on-light", appearance: .aqua, size: nil)
        }
    }
    // 菜单栏面板上的更新那一行
    let release = AppRelease(version: "0.2.2", page: URL(string: "https://github.com")!,
                             dmg: URL(string: "https://github.com")!, size: 1, sha256: nil)
    let updateStates: [(String, UpdateController.State)] = [
        ("available", .available(release)), ("downloading", .downloading(0.42)),
        ("failed", .failed(chinese ? "下载失败：网络断了" : "The download failed: offline", release)),
    ]
    for (name, state) in updateStates {
        let model = ReceiverController(preview: streaming(.playing, input: -17.6, output: -9.4), addresses: addresses,
                                       bitrateKbps: 1587, history: history(sound: true), linkState: .playing,
                                       senderName: "DESKTOP-7Q2", senderKind: .desktop,
                                       updates: UpdateController(preview: state))
        render(MenuBarContent(controller: model), name: "panel-update-\(name)-light", appearance: .aqua, size: nil)
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
