import EarPairCore
import SwiftUI

// 把控制器的状态翻译成路线上的节点和连线（窗口里三个节点，菜单栏面板里两个）。

/// Windows 电脑的图标：笔记本是 laptopcomputer，台式机或不知道是 display。
/// 不用 pc：它的屏幕上画着一个“:(”，正常播放时看起来也像出错了。
func senderSymbol(_ kind: DeviceKind?) -> String { kind == .laptop ? "laptopcomputer" : "display" }

extension ReceiverController {
    var senderDisplayName: String { senderName ?? stats.senderAddress ?? Self.genericSenderName }

    /// 等待时的占位：上次播放过的电脑，没有就是笼统的“Windows 电脑”
    var waitingSenderName: String { lastSenderName ?? Self.genericSenderName }

    private static var genericSenderName: String { String(localized: "Windows PC", bundle: .module) }

    var senderNode: RouteNode {
        switch linkState {
        case .waiting, .receiveFailed:
            return RouteNode(symbol: senderSymbol(lastSenderKind), name: waitingSenderName, isPlaceholder: true)
        case .stopped, .reconnecting, .disconnected:
            return RouteNode(symbol: senderSymbol(senderKind), name: senderDisplayName, isDimmed: true)
        default:
            return RouteNode(symbol: senderSymbol(senderKind), name: senderDisplayName)
        }
    }

    var macNode: RouteNode {
        RouteNode(symbol: HostInfo.isLaptop ? "macbook" : "desktopcomputer", name: macName)
    }

    var outputNode: RouteNode {
        RouteNode(symbol: outputDevice?.symbolName ?? "speaker.slash",
                  name: outputDevice?.name ?? String(localized: "No output device", bundle: .module),
                  isPlaceholder: outputDevice == nil,
                  badge: muted && (linkState == .playing || linkState == .standby) ? "speaker.slash.fill" : nil)
    }

    /// 窗口：Windows → Mac、Mac → 输出 两段
    var windowLinks: [(style: RouteLink.Style, pill: RouteLink.Pill?)] {
        let incoming: RouteLink.Style = hasSound ? .flowing(Self.intensity(stats.inputLevelDB)) : .quiet
        let outgoing: RouteLink.Style = muted ? .inactive
            : hasSound ? .flowing(Self.intensity(stats.outputLevelDB)) : .quiet
        switch linkState {
        case .waiting: return [(.waiting, .waiting), (.inactive, nil)]
        case .connecting: return [(.connecting, nil), (.inactive, nil)]
        case .playing: return [(incoming, nil), (outgoing, nil)]
        case .standby: return [(.quiet, nil), (muted ? .inactive : .quiet, nil)]
        case .stopped: return [(.inactive, .stopped), (.inactive, nil)]
        case .reconnecting: return [(.connecting, .reconnecting), (.inactive, nil)]
        case .disconnected: return [(.broken, .disconnected), (.inactive, nil)]
        case .receiveFailed: return [(.failed, .failed(Self.cannotReceive)), (.inactive, nil)]
        case .outputFailed: return [(incoming, nil), (.failed, .failed(Self.cannotPlay))]
        }
    }

    /// 面板：Windows → 输出 一段
    var panelLink: (style: RouteLink.Style, pill: RouteLink.Pill?) {
        switch linkState {
        case .waiting: return (.waiting, .waiting) // 面板里只画点线，不写字
        case .connecting: return (.connecting, nil)
        case .playing:
            if muted { return (.inactive, nil) }
            return (hasSound ? .flowing(Self.intensity(stats.outputLevelDB)) : .quiet, nil)
        case .standby: return (muted ? .inactive : .quiet, nil)
        case .stopped: return (.inactive, nil) // 面板里只画灰线
        case .reconnecting: return (.connecting, nil)
        case .disconnected: return (.broken, .disconnected)
        case .receiveFailed: return (.failed, .failed(Self.cannotReceive))
        case .outputFailed: return (.failed, .failed(Self.cannotPlay))
        }
    }

    private static var cannotReceive: String { String(localized: "Can’t receive", bundle: .module) }
    private static var cannotPlay: String { String(localized: "Can’t play", bundle: .module) }

    var failureMessage: String? {
        switch linkState {
        case .receiveFailed(let message), .outputFailed(let message): return message
        default: return nil
        }
    }

    /// −50 dBFS 以下算没声音，−10 dBFS 以上光点最亮
    static func intensity(_ db: Double) -> Double { min(max((db + 50) / 40, 0), 1) }

    /// 路线整体给 VoiceOver 的一句话
    var routeAccessibilityLabel: String {
        let sender = senderDisplayName
        switch linkState {
        case .waiting:
            // 列表分隔符：中文是顿号
            let addresses = localAddresses.map(\.address).joined(separator: String(localized: ", ", bundle: .module))
            guard let name = lastSenderName else {
                return String(localized: "Waiting for a Windows PC to connect. This Mac is at \(addresses)",
                              bundle: .module)
            }
            return String(localized: "Waiting for \(name) to connect. This Mac is at \(addresses)", bundle: .module)
        case .connecting: return String(localized: "Connecting to \(sender)", bundle: .module)
        case .playing:
            if muted { return String(localized: "Sound from \(sender) is muted", bundle: .module) }
            guard let output = outputDevice?.name else {
                return String(localized: "Playing from \(sender)", bundle: .module)
            }
            return String(localized: "Playing from \(sender) to \(output)", bundle: .module)
        case .standby: return String(localized: "No sound from \(sender), on standby", bundle: .module)
        case .stopped: return String(localized: "\(sender) has stopped sending", bundle: .module)
        case .reconnecting: return String(localized: "Reconnecting to \(sender)", bundle: .module)
        case .disconnected: return String(localized: "Disconnected from \(sender)", bundle: .module)
        case .receiveFailed(let message), .outputFailed(let message): return message
        }
    }

    public var menuBarSymbol: String {
        switch linkState {
        case .receiveFailed, .outputFailed: return "ear.trianglebadge.exclamationmark"
        case .playing where !muted, .standby where !muted: return "ear.fill"
        default: return "ear"
        }
    }
}

extension OutputDevice {
    var symbolName: String {
        let text = "\(model ?? "") \(name)".lowercased()
        switch transport {
        case .bluetooth:
            if text.contains("airpods max") {
                if #available(macOS 15.0, *) { return "airpods.max" }
                return "airpodsmax"
            }
            if text.contains("airpods pro") {
                if #available(macOS 15.0, *) { return "airpods.pro" }
                return "airpodspro"
            }
            if text.contains("airpods") { return "airpods" }
            if text.contains("beats") { return "beats.headphones" }
            return "headphones"
        case .builtIn: return usesHeadphoneJack ? "headphones" : "speaker.wave.2.fill"
        case .hdmi, .displayPort: return text.contains("tv") ? "tv" : "display"
        case .airPlay: return "airplayaudio"
        case .usb, .thunderbolt: return "hifispeaker"
        case .virtual, .other: return "speaker.wave.2.fill"
        }
    }
}
