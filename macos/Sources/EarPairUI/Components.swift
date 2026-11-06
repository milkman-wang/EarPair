import AppKit
import EarPairCore
import SwiftUI

// MARK: - 状态

extension ReceiverStats {
    var formatText: String? {
        guard let format, senderAddress != nil else { return nil }
        let rate = Format.sampleRate(format.sampleRate)
        return format.channels == 1
            ? String(localized: "\(rate) · Mono", bundle: .module)
            : String(localized: "\(rate) · Stereo", bundle: .module)
    }

    /// 正在收发送端的流（缓冲中或播放中）
    var isStreaming: Bool { state != .idle && senderAddress != nil }
}

// MARK: - Liquid Glass（macOS 26 起），macOS 14 / 15 上退回普通样式

enum Appearance {
    /// 设置环境变量 EARPAIR_LEGACY_STYLE=1 可以在新系统上预览 macOS 14 / 15 的样子
    static var usesGlass: Bool {
        if #available(macOS 26.0, *) {
            return ProcessInfo.processInfo.environment["EARPAIR_LEGACY_STYLE"] == nil
        }
        return false
    }
}

// MARK: - 按钮

/// 嵌入式图标按钮：系统原生的无边框样式，按下时高亮
struct IconButton: View {
    var systemImage: String
    var help: String
    var action: () -> Void

    var body: some View {
        Button(action: action) {
            Label(help, systemImage: systemImage)
                .labelStyle(.iconOnly)
                .contentTransition(.symbolEffect(.replace))
        }
        .buttonStyle(.borderless)
        .help(help)
    }
}

/// 音量对应的喇叭图标
private func speakerSymbol(volume: Double, muted: Bool) -> String {
    if muted { return "speaker.slash.fill" }
    if volume < 0.5 { return "speaker.wave.1.fill" }
    if volume < 1.2 { return "speaker.wave.2.fill" }
    return "speaker.wave.3.fill"
}

struct MuteButton: View {
    @Binding var muted: Bool
    var volume: Double

    var body: some View {
        let help = muted ? String(localized: "Unmute", bundle: .module) : String(localized: "Mute", bundle: .module)
        IconButton(systemImage: speakerSymbol(volume: volume, muted: muted), help: help) {
            muted.toggle()
        }
    }
}

/// 复制文字到剪贴板，复制后短暂显示对勾
struct CopyButton: View {
    var text: String
    var help: String
    @State private var copied = false

    var body: some View {
        IconButton(systemImage: copied ? "checkmark" : "doc.on.doc", help: help) {
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(text, forType: .string)
            copied = true
            Task {
                try? await Task.sleep(for: .seconds(1.5))
                copied = false
            }
        }
    }
}

// MARK: - 行

/// 音量：窗口里是“静音按钮 + 滑块 + 百分比”；面板里喇叭只是图标（静音交给圆钮，和控制中心一样）
struct VolumeRow: View {
    enum Style { case form, panel }

    @ObservedObject var controller: ReceiverController
    var style: Style

    var body: some View {
        HStack(spacing: 8) {
            switch style {
            case .form:
                MuteButton(muted: $controller.muted, volume: controller.volume)
            case .panel:
                Image(systemName: speakerSymbol(volume: controller.volume, muted: controller.muted))
                    .foregroundStyle(.secondary)
                    .contentTransition(.symbolEffect(.replace))
                    .frame(width: 18)
            }
            VolumeSlider(volume: $controller.volume)
            Text(verbatim: Format.percent(controller.volume))
                .monospacedDigit()
                .foregroundStyle(.secondary)
                .frame(width: style == .panel ? 38 : 44, alignment: .trailing)
        }
    }
}

/// 出错时的一句完整说明
struct ErrorRow: View {
    var message: String

    var body: some View {
        Label {
            Text(verbatim: message)
                .fixedSize(horizontal: false, vertical: true)
        } icon: {
            Image(systemName: "exclamationmark.triangle.fill")
                .symbolRenderingMode(.multicolor)
                .symbolEffect(.bounce, value: message)
        }
        .font(.callout)
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

/// 本机地址：每个网卡一行，复制的是 IP（Windows 端要填的就是它）
struct AddressRows: View {
    var addresses: [LocalAddress]
    /// 窗口概览里居中放在 Mac 节点下面，只显示地址
    var centered: Bool

    var body: some View {
        VStack(alignment: centered ? .center : .leading, spacing: 6) {
            ForEach(addresses, id: \.self) { local in
                HStack(spacing: 6) {
                    if !centered {
                        Text(verbatim: local.name).foregroundStyle(.secondary)
                        Spacer(minLength: 8)
                    }
                    Text(verbatim: local.address)
                        .monospacedDigit()
                        .foregroundStyle(centered ? .secondary : .primary)
                        .textSelection(.enabled)
                    CopyButton(text: local.address, help: String(localized: "Copy Address", bundle: .module))
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: centered ? .center : .leading)
    }
}

/// 连接页每组的第一行：设备圆盘 + 名字，右边放附加信息（比如状态）
struct DeviceHeaderRow<Accessory: View>: View {
    var symbol: String
    var title: String
    var isPlaceholder = false
    @ViewBuilder var accessory: Accessory

    var body: some View {
        HStack(spacing: 10) {
            CircleGlyph(systemImage: symbol, diameter: 32, isPlaceholder: isPlaceholder)
            Text(verbatim: title)
                .font(.headline)
                .foregroundStyle(isPlaceholder ? .secondary : .primary)
            Spacer()
            accessory
        }
    }
}

/// 连接页发送端那一行右边的状态：圆点加文字；等待时只有文字
struct StatusPill: View {
    var state: LinkState

    var body: some View {
        HStack(spacing: 6) {
            if let color {
                Circle().fill(color).frame(width: 6, height: 6)
            }
            Text(verbatim: text).font(.callout).foregroundStyle(.secondary)
        }
        .contentTransition(.opacity)
    }

    private var color: Color? {
        switch state {
        case .playing, .standby: return .green
        case .connecting, .reconnecting: return .orange
        case .stopped, .disconnected: return .gray
        case .receiveFailed, .outputFailed: return .red
        case .waiting: return nil
        }
    }

    private var text: String {
        switch state {
        case .waiting: return String(localized: "Waiting", bundle: .module)
        case .connecting: return String(localized: "Connecting", bundle: .module)
        case .playing: return String(localized: "Playing", bundle: .module)
        case .standby: return String(localized: "Standby", bundle: .module)
        case .stopped: return String(localized: "Stopped", bundle: .module)
        case .reconnecting: return String(localized: "Reconnecting", bundle: .module)
        case .disconnected: return String(localized: "Disconnected", bundle: .module)
        case .receiveFailed: return String(localized: "Can’t receive", bundle: .module)
        case .outputFailed: return String(localized: "Can’t play", bundle: .module)
        }
    }
}

// MARK: - 格式

/// 数字自己排好（小数位、正负号、减号），单位和数字的位置交给本地化的格式
enum Format {
    /// 用真正的减号显示负数
    private static func minus(_ text: String) -> String { text.replacingOccurrences(of: "-", with: "−") }

    static func decibels(_ value: Double) -> String {
        decibels(number: value <= -119 ? "−∞" : minus(String(format: "%.0f", value)))
    }

    static func signedDecibels(_ value: Double) -> String {
        decibels(number: minus(String(format: "%+.1f", value)))
    }

    private static func decibels(number: String) -> String { String(localized: "\(number) dB", bundle: .module) }

    static func percent(_ value: Double) -> String { percent(number: "\(Int((value * 100).rounded()))") }

    static func percent(number: String) -> String { String(localized: "\(number)%", bundle: .module) }

    static func sampleRate(_ hz: Int) -> String {
        let number = hz % 1000 == 0 ? "\(hz / 1000)" : String(format: "%.1f", Double(hz) / 1000)
        return String(localized: "\(number) kHz", bundle: .module)
    }

    static func milliseconds(_ value: Double, digits: Int = 0) -> String {
        milliseconds(number: String(format: "%.\(digits)f", value))
    }

    static func milliseconds(number: String) -> String { String(localized: "\(number) ms", bundle: .module) }

    static func ppm(_ value: Double) -> String {
        let number = minus(String(format: "%+.0f", value))
        return String(localized: "\(number) ppm", bundle: .module)
    }

    /// 0 → "0"；小于 0.01 → "<0.01"（不显示成 0.00）；小于 1 → 两位小数；否则一位小数（单位 % 另外画）
    static func lossPercent(_ percent: Double) -> String {
        if percent == 0 { return "0" }
        if percent < 0.01 { return "<0.01" }
        return percent < 1 ? String(format: "%.2f", percent) : String(format: "%.1f", percent)
    }

    /// 69467 → "69,467"
    static func count(_ value: Int) -> String { value.formatted() }

    /// 包数、次数：中文带量词（“69,467 个”“3 次”），英文只有数字（名词在标签里，不用分单复数）
    static func packets(_ count: String) -> String {
        String(localized: "count.packets", defaultValue: "\(count)", bundle: .module)
    }

    static func times(_ count: String) -> String {
        String(localized: "count.times", defaultValue: "\(count)", bundle: .module)
    }

    /// 丢包数和丢包率：“3 个 · 0.12%”
    static func packetLoss(count: String, percent: String) -> String {
        String(localized: "count.packetLoss", defaultValue: "\(count) · \(percent)%", bundle: .module)
    }

    /// kbps → "1.59 Mbps"
    static func megabits(_ kbps: Double) -> String {
        let number = String(format: "%.2f", kbps / 1000)
        return String(localized: "\(number) Mbps", bundle: .module)
    }

    /// 时长：m:ss 或 h:mm:ss
    static func duration(_ seconds: Double) -> String {
        let s = Int(seconds)
        return s >= 3600
            ? String(format: "%d:%02d:%02d", s / 3600, s / 60 % 60, s % 60)
            : String(format: "%d:%02d", s / 60, s % 60)
    }
}

extension MetricColumn.Tone {
    static func loss(_ percent: Double) -> Self {
        percent == 0 ? .calm : percent <= 0.5 ? .normal : percent <= 3 ? .warning : .critical
    }

    static func underruns(_ count: Int) -> Self { count == 0 ? .calm : count < 5 ? .warning : .critical }
}
