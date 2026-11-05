import AppKit
import EarPairCore
import SwiftUI

struct MenuBarView: View {
    @ObservedObject var controller: ReceiverController

    private var stats: ReceiverStats { controller.stats }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            header
            if let message = controller.errorMessage {
                Text(verbatim: message)
                    .font(.caption)
                    .foregroundStyle(.red)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Divider()
            volumeControls
            bufferControls
            Divider()
            statistics
            Divider()
            connectionHelp
            HStack {
                Button("重置统计") { controller.resetStatistics() }
                Spacer()
                Button("退出 EarPair") { NSApplication.shared.terminate(nil) }
            }
        }
        .padding(14)
        .frame(width: 320)
    }

    // MARK: - 状态

    private var header: some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Circle().fill(statusColor).frame(width: 8, height: 8)
            VStack(alignment: .leading, spacing: 2) {
                Text(verbatim: statusTitle).font(.headline)
                if let detail = statusDetail {
                    Text(verbatim: detail).font(.caption).foregroundStyle(.secondary)
                }
            }
        }
    }

    private var statusColor: Color {
        switch stats.state {
        case .idle: return .gray
        case .buffering: return .orange
        case .playing: return .green
        }
    }

    private var statusTitle: String {
        switch stats.state {
        case .idle: return stats.senderAddress == nil ? "等待 Windows 连接" : "发送端已断开"
        case .buffering: return "正在缓冲…"
        case .playing: return "正在播放 Windows 的声音"
        }
    }

    private var statusDetail: String? {
        guard let address = stats.senderAddress, let format = stats.format else { return nil }
        let rate = format.sampleRate % 1000 == 0
            ? "\(format.sampleRate / 1000) kHz"
            : String(format: "%.1f kHz", Double(format.sampleRate) / 1000)
        return "\(address) · \(rate) · \(format.channels == 1 ? "单声道" : "立体声")"
    }

    // MARK: - 控制

    private var volumeControls: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text("Windows 音量")
                Spacer()
                Text(verbatim: controller.muted ? "静音" : "\(Int((controller.volume * 100).rounded()))%")
                    .monospacedDigit()
                    .foregroundStyle(.secondary)
            }
            HStack(spacing: 8) {
                Button {
                    controller.muted.toggle()
                } label: {
                    Image(systemName: controller.muted ? "speaker.slash.fill" : "speaker.wave.2.fill")
                        .frame(width: 18)
                }
                .buttonStyle(.borderless)
                .help(controller.muted ? "取消静音" : "静音")
                Slider(value: $controller.volume, in: 0...1)
            }
            Text("只调 Windows 传来的声音。Mac 的系统音量仍然会影响最终音量。")
                .font(.caption2)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private var bufferControls: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("缓冲")
            Picker("缓冲", selection: $controller.bufferMs) {
                ForEach([30, 60, 100, 150], id: \.self) { value in
                    Text(verbatim: "\(value) ms").tag(value)
                }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            Text("有线网络可以用 30 ms；Wi‑Fi 下断断续续就调大。")
                .font(.caption2)
                .foregroundStyle(.secondary)
        }
    }

    // MARK: - 统计

    private var statistics: some View {
        Grid(alignment: .leading, horizontalSpacing: 16, verticalSpacing: 3) {
            row("缓冲", String(format: "%.0f / %.0f ms", stats.bufferedMs, stats.targetMs))
            row("丢包", String(format: "%ld（%.2f%%）", stats.packetsLost, stats.lossPercent))
            row("迟到 / 重复", "\(stats.packetsLate)")
            row("欠载", "\(stats.underruns)")
            row("时钟偏差", stats.state == .playing && stats.secondsPlayed < 60
                ? "测量中…"
                : String(format: "%+.0f ppm", stats.driftPPM))
            row("网络抖动", String(format: "%.1f ms", stats.jitterMs))
            row("码率", String(format: "%.0f kbps", controller.bitrateKbps))
        }
        .font(.system(.caption, design: .monospaced))
    }

    private func row(_ title: String, _ value: String) -> some View {
        GridRow {
            Text(verbatim: title).foregroundStyle(.secondary)
            Text(verbatim: value)
        }
    }

    // MARK: - 连接提示

    private var connectionHelp: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("在 Windows 上运行：")
                .font(.caption)
                .foregroundStyle(.secondary)
            if controller.localAddresses.isEmpty {
                Text("没有找到局域网地址，请先连上网络").font(.caption)
            }
            ForEach(controller.localAddresses, id: \.self) { address in
                Text(verbatim: "EarPair.Sender \(address)")
                    .font(.system(.caption, design: .monospaced))
                    .textSelection(.enabled)
            }
            Text(verbatim: "UDP 端口 \(ReceiverController.port)")
                .font(.caption2)
                .foregroundStyle(.secondary)
        }
    }
}
