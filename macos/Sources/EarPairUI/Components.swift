import AppKit
import EarPairCore
import SwiftUI

// MARK: - 状态

extension ReceiverStats {
    var statusTitle: String {
        switch state {
        case .idle: return senderAddress == nil ? "等待连接" : "已断开"
        case .buffering, .playing: return senderAddress ?? "等待连接"
        }
    }

    var statusColor: Color {
        switch state {
        case .idle: return .secondary
        case .buffering: return .orange
        case .playing: return .green
        }
    }

    var formatText: String? {
        guard let format, senderAddress != nil else { return nil }
        let channels = format.channels == 1 ? "单声道" : "立体声"
        return "\(Format.sampleRate(format.sampleRate)) · \(channels)"
    }

    /// 正在收发送端的流（缓冲中或播放中）
    var isStreaming: Bool { state != .idle && senderAddress != nil }
}

struct StatusDot: View {
    var color: Color

    var body: some View {
        Circle()
            .fill(color)
            .frame(width: 8, height: 8)
    }
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

extension View {
    /// 圆形底：新系统是玻璃（打开时着强调色），旧系统是实心圆
    @ViewBuilder
    func glassCircle(highlighted: Bool) -> some View {
        if #available(macOS 26.0, *), Appearance.usesGlass {
            glassEffect(highlighted ? Glass.regular.tint(.accentColor).interactive() : Glass.regular.interactive(),
                        in: .circle)
        } else {
            background(Circle().fill(highlighted ? AnyShapeStyle(Color.accentColor) : AnyShapeStyle(.quaternary)))
        }
    }

    /// 按钮样式：新系统是玻璃，旧系统是带边框
    @ViewBuilder
    func glassButtonStyle() -> some View {
        if #available(macOS 26.0, *), Appearance.usesGlass {
            buttonStyle(.glass)
        } else {
            buttonStyle(.bordered)
        }
    }
}

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

/// 控制中心式开关：圆形图标（打开时着色）加名称
struct GlassToggleTile: View {
    var title: LocalizedStringKey
    var systemImage: String
    @Binding var isOn: Bool

    var body: some View {
        Button {
            isOn.toggle()
        } label: {
            HStack(spacing: 10) {
                Image(systemName: systemImage)
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(isOn ? Color.white : Color.primary)
                    .frame(width: 30, height: 30)
                    .glassCircle(highlighted: isOn)
                Text(title)
                Spacer(minLength: 0)
            }
            .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(isOn ? .isSelected : [])
    }
}

// MARK: - 电平表

/// 横条电平表：−60…0 dBFS，绿 → 黄 → 红
struct LevelMeter: View {
    var level: Double

    private static let gradient = LinearGradient(
        stops: [
            .init(color: .green, location: 0),
            .init(color: .green, location: 0.78),
            .init(color: .yellow, location: 0.9),
            .init(color: .red, location: 0.98),
        ],
        startPoint: .leading, endPoint: .trailing)

    private var fraction: Double { min(max((level + 60) / 60, 0), 1) }

    var body: some View {
        GeometryReader { proxy in
            ZStack(alignment: .leading) {
                Capsule().fill(.quaternary)
                Capsule()
                    .fill(Self.gradient)
                    .mask(alignment: .leading) {
                        Rectangle().frame(width: proxy.size.width * fraction)
                    }
            }
        }
        .frame(height: 4)
        .animation(.linear(duration: 0.1), value: fraction)
        .accessibilityElement()
        .accessibilityValue(Format.decibels(level))
    }
}

// MARK: - 按钮

struct MuteButton: View {
    @Binding var muted: Bool
    var volume: Double

    private var symbol: String {
        if muted { return "speaker.slash.fill" }
        if volume < 0.5 { return "speaker.wave.1.fill" }
        if volume < 1.2 { return "speaker.wave.2.fill" }
        return "speaker.wave.3.fill"
    }

    var body: some View {
        IconButton(systemImage: symbol, help: muted ? "取消静音" : "静音") {
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

/// 本机地址，带复制 Windows 端命令的按钮
struct AddressRow: View {
    var address: String

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: "laptopcomputer")
                .foregroundStyle(.secondary)
            Text(verbatim: address)
                .monospacedDigit()
            Spacer()
            CopyButton(text: "EarPair.Sender \(address)", help: "复制 Windows 端命令")
        }
    }
}

/// 音量：静音按钮（可选）、滑块（0–200%）、百分比，下面可选一条输出电平表
struct VolumeControl: View {
    @ObservedObject var controller: ReceiverController
    var showsMute: Bool
    var showsMeter: Bool

    /// 静音按钮和百分比的固定宽度，让下面的电平表和滑块正好对齐
    private static let buttonWidth: CGFloat = 22
    private static let percentWidth: CGFloat = 44

    var body: some View {
        VStack(spacing: 8) {
            HStack(spacing: 10) {
                if showsMute {
                    MuteButton(muted: $controller.muted, volume: controller.volume)
                        .frame(width: Self.buttonWidth)
                }
                Slider(value: $controller.volume, in: 0...2)
                Text(Format.percent(controller.volume))
                    .monospacedDigit()
                    .foregroundStyle(.secondary)
                    .frame(width: Self.percentWidth, alignment: .trailing)
            }
            if showsMeter {
                HStack(spacing: 10) {
                    if showsMute {
                        Color.clear.frame(width: Self.buttonWidth, height: 1)
                    }
                    LevelMeter(level: controller.muted ? -120 : controller.stats.outputLevelDB)
                    Color.clear.frame(width: Self.percentWidth, height: 1)
                }
            }
        }
    }
}

// MARK: - 格式

enum Format {
    /// 用真正的减号显示负数
    private static func minus(_ text: String) -> String { text.replacingOccurrences(of: "-", with: "−") }

    static func decibels(_ value: Double) -> String {
        value <= -119 ? "−∞ dB" : minus(String(format: "%.0f dB", value))
    }

    static func signedDecibels(_ value: Double) -> String {
        minus(String(format: "%+.1f dB", value))
    }

    static func percent(_ value: Double) -> String { "\(Int((value * 100).rounded()))%" }

    static func sampleRate(_ hz: Int) -> String {
        hz % 1000 == 0 ? "\(hz / 1000) kHz" : String(format: "%.1f kHz", Double(hz) / 1000)
    }

    static func milliseconds(_ value: Double, digits: Int = 0) -> String {
        String(format: "%.\(digits)f ms", value)
    }

    static func ppm(_ value: Double) -> String { minus(String(format: "%+.0f ppm", value)) }

    /// 时长：m:ss 或 h:mm:ss
    static func duration(_ seconds: Double) -> String {
        let s = Int(seconds)
        return s >= 3600
            ? String(format: "%d:%02d:%02d", s / 3600, s / 60 % 60, s % 60)
            : String(format: "%d:%02d", s / 60, s % 60)
    }
}
