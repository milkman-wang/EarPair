import EarPairCore
import SwiftUI

// 把控制器的状态翻译成路线上的节点和连线（窗口里三个节点，菜单栏面板里两个）。

/// Windows 电脑的图标：笔记本是 laptopcomputer，台式机或不知道是 display。
/// 不用 pc：它的屏幕上画着一个“:(”，正常播放时看起来也像出错了。
func senderSymbol(_ kind: DeviceKind?) -> String { kind == .laptop ? "laptopcomputer" : "display" }

extension ReceiverController {
    var senderDisplayName: String { senderName ?? stats.senderAddress ?? "Windows 电脑" }

    /// 等待时的占位：上次播放过的电脑，没有就是笼统的“Windows 电脑”
    var waitingSenderName: String { lastSenderName ?? "Windows 电脑" }

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
                  name: outputDevice?.name ?? "没有输出设备",
                  isPlaceholder: outputDevice == nil,
                  badge: muted && linkState == .playing ? "speaker.slash.fill" : nil)
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
        case .stopped: return [(.inactive, .stopped), (.inactive, nil)]
        case .reconnecting: return [(.connecting, .reconnecting), (.inactive, nil)]
        case .disconnected: return [(.broken, .disconnected), (.inactive, nil)]
        case .receiveFailed: return [(.failed, .failed("无法接收")), (.inactive, nil)]
        case .outputFailed: return [(incoming, nil), (.failed, .failed("无法播放"))]
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
        case .stopped: return (.inactive, nil) // 面板里只画灰线
        case .reconnecting: return (.connecting, nil)
        case .disconnected: return (.broken, .disconnected)
        case .receiveFailed: return (.failed, .failed("无法接收"))
        case .outputFailed: return (.failed, .failed("无法播放"))
        }
    }

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
        switch linkState {
        case .waiting:
            return "等待 \(waitingSenderName) 连接，本机地址 " + localAddresses.map(\.address).joined(separator: "、")
        case .connecting: return "正在连接 \(senderDisplayName)"
        case .playing:
            return muted ? "\(senderDisplayName) 的声音已静音"
                : "\(senderDisplayName) 到 \(outputDevice?.name ?? "输出设备")，正在播放"
        case .stopped: return "\(senderDisplayName) 已停止发送"
        case .reconnecting: return "正在重新连接 \(senderDisplayName)"
        case .disconnected: return "\(senderDisplayName) 已断开"
        case .receiveFailed(let message), .outputFailed(let message): return message
        }
    }

    public var menuBarSymbol: String {
        switch linkState {
        case .receiveFailed, .outputFailed: return "ear.trianglebadge.exclamationmark"
        case .playing where !muted: return "ear.fill"
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
