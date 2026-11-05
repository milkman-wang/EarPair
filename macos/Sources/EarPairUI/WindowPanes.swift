import AppKit
import EarPairCore
import SwiftUI

// MARK: - 概览

/// 仪表盘：状态、电平和曲线、音量、关键指标
struct OverviewPane: View {
    @ObservedObject var controller: ReceiverController

    private var stats: ReceiverStats { controller.stats }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                header
                GroupBox {
                    Group {
                        if stats.isStreaming {
                            levels
                        } else {
                            commands
                        }
                    }
                    .padding(10)
                }
                GroupBox {
                    controls.padding(10)
                }
                metrics
            }
            .padding(24)
            .frame(maxWidth: 820, alignment: .leading)
        }
    }

    private var header: some View {
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            StatusDot(color: stats.statusColor)
            Text(verbatim: stats.statusTitle)
                .font(.title2.weight(.semibold))
            if stats.state == .buffering {
                ProgressView().controlSize(.small)
            }
            if let format = stats.formatText {
                Text(verbatim: format).foregroundStyle(.secondary)
            }
            Spacer()
        }
    }

    private var levels: some View {
        VStack(alignment: .leading, spacing: 12) {
            LevelRow(title: "输入", level: stats.inputLevelDB)
            LevelRow(title: "输出", level: controller.muted ? -120 : stats.outputLevelDB)
            LevelHistoryChart(history: controller.history)
                .frame(height: 110)
        }
    }

    private var commands: some View {
        VStack(alignment: .leading, spacing: 10) {
            ForEach(controller.localAddresses, id: \.self) { local in
                CommandRow(address: local.address)
            }
        }
    }

    private var controls: some View {
        VStack(alignment: .leading, spacing: 14) {
            VolumeControl(controller: controller, showsMute: true, showsMeter: false)
            HStack(spacing: 12) {
                GlassToggleTile(title: "音量平衡", systemImage: "wand.and.stars", isOn: $controller.autoLevel)
                if controller.autoLevel && stats.isStreaming {
                    Text(verbatim: Format.signedDecibels(stats.levelingGainDB))
                        .monospacedDigit()
                        .foregroundStyle(.secondary)
                }
            }
        }
    }

    private var metrics: some View {
        LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 12), count: 4), spacing: 12) {
            MetricTile(title: "缓冲", value: stats.isStreaming ? Format.milliseconds(stats.bufferedMs) : "—")
            MetricTile(title: "丢包", value: String(format: "%.2f%%", stats.lossPercent))
            MetricTile(title: "时钟偏差", value: driftText(stats))
            MetricTile(title: "码率", value: stats.isStreaming ? "\(Int(controller.bitrateKbps.rounded())) kbps" : "—")
        }
    }
}

// MARK: - 声音

struct SoundPane: View {
    @ObservedObject var controller: ReceiverController

    private var stats: ReceiverStats { controller.stats }

    /// 左右平衡靠近中间时吸附到 0
    private var balance: Binding<Double> {
        Binding(get: { controller.balance },
                set: { controller.balance = abs($0) < 0.05 ? 0 : $0 })
    }

    var body: some View {
        Form {
            Section {
                LabeledContent("音量") {
                    VolumeControl(controller: controller, showsMute: true, showsMeter: false)
                }
                LabeledContent("左右") {
                    HStack(spacing: 8) {
                        Text("L").foregroundStyle(.secondary)
                        Slider(value: balance, in: -1...1)
                        Text("R").foregroundStyle(.secondary)
                    }
                }
            }
            Section {
                Toggle("音量平衡", isOn: $controller.autoLevel)
                Picker("目标响度", selection: $controller.loudness) {
                    ForEach(LoudnessPreset.allCases) { preset in
                        Text(preset.title).tag(preset)
                    }
                }
                .pickerStyle(.segmented)
                .fixedSize()
                .disabled(!controller.autoLevel)
                if controller.autoLevel && stats.isStreaming {
                    LabeledContent("增益", value: Format.signedDecibels(stats.levelingGainDB))
                }
                if let loudness = stats.loudnessLUFS, stats.isStreaming {
                    LabeledContent("响度", value: String(format: "%.1f LUFS", loudness).replacingOccurrences(of: "-", with: "−"))
                }
            }
        }
        .formStyle(.grouped)
        .monospacedDigit()
    }
}

// MARK: - 网络

struct NetworkPane: View {
    @ObservedObject var controller: ReceiverController

    private var stats: ReceiverStats { controller.stats }

    var body: some View {
        Form {
            Section {
                Picker("缓冲", selection: $controller.bufferMs) {
                    ForEach([30, 60, 100, 150], id: \.self) { value in
                        Text(verbatim: "\(value) ms").tag(value)
                    }
                }
                .pickerStyle(.segmented)
                .fixedSize()
                BufferHistoryChart(history: controller.history, target: Double(controller.bufferMs))
                    .frame(height: 120)
            }
            Section {
                Toggle("时钟漂移补偿", isOn: $controller.driftCompensation)
                LabeledContent("时钟偏差", value: driftText(stats))
            }
            Section("统计") {
                LabeledContent("收到", value: "\(stats.packetsReceived)")
                LabeledContent("丢包", value: "\(stats.packetsLost) · \(String(format: "%.2f%%", stats.lossPercent))")
                LabeledContent("迟到", value: "\(stats.packetsLate)")
                LabeledContent("欠载", value: "\(stats.underruns)")
                LabeledContent("裁剪", value: "\(stats.latencyTrims)")
                LabeledContent("抖动", value: stats.isStreaming ? Format.milliseconds(stats.jitterMs, digits: 1) : "—")
                LabeledContent("码率", value: stats.isStreaming ? "\(Int(controller.bitrateKbps.rounded())) kbps" : "—")
            }
        }
        .formStyle(.grouped)
        .monospacedDigit()
        .toolbar {
            ToolbarItem {
                Button {
                    controller.resetStatistics()
                } label: {
                    Label("重置统计", systemImage: "arrow.counterclockwise")
                }
                .help("重置统计")
            }
        }
    }
}

// MARK: - 连接

struct ConnectionPane: View {
    @ObservedObject var controller: ReceiverController

    private var stats: ReceiverStats { controller.stats }

    var body: some View {
        Form {
            Section("本机") {
                ForEach(controller.localAddresses, id: \.self) { local in
                    LabeledContent {
                        HStack(spacing: 8) {
                            Text(verbatim: local.address).textSelection(.enabled)
                            CopyButton(text: local.address, help: "复制")
                        }
                    } label: {
                        Text(verbatim: local.name)
                    }
                }
                LabeledContent("端口", value: "\(ReceiverController.port)")
            }
            Section("Windows") {
                ForEach(controller.localAddresses, id: \.self) { local in
                    CommandRow(address: local.address)
                }
            }
            if stats.isStreaming, let sender = stats.senderAddress {
                Section("发送端") {
                    LabeledContent("地址", value: sender)
                    if let format = stats.formatText {
                        LabeledContent("格式", value: format)
                    }
                    LabeledContent("已播放", value: Format.duration(stats.secondsPlayed))
                }
            }
        }
        .formStyle(.grouped)
        .monospacedDigit()
    }
}

// MARK: - 小部件

func driftText(_ stats: ReceiverStats) -> String {
    guard stats.isStreaming else { return "—" }
    if stats.state == .playing && stats.secondsPlayed < 60 { return "测量中…" }
    return Format.ppm(stats.driftPPM)
}

struct LevelRow: View {
    var title: LocalizedStringKey
    var level: Double

    var body: some View {
        HStack(spacing: 12) {
            Text(title)
                .foregroundStyle(.secondary)
                .frame(width: 32, alignment: .leading)
            LevelMeter(level: level)
            Text(verbatim: Format.decibels(level))
                .monospacedDigit()
                .foregroundStyle(.secondary)
                .frame(width: 56, alignment: .trailing)
        }
    }
}

struct MetricTile: View {
    var title: LocalizedStringKey
    var value: String

    var body: some View {
        GroupBox {
            VStack(alignment: .leading, spacing: 4) {
                Text(title)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                Text(verbatim: value)
                    .font(.title3.weight(.semibold))
                    .monospacedDigit()
                    .lineLimit(1)
                    .minimumScaleFactor(0.7)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(6)
        }
    }
}

/// Windows 端要运行的命令，可选中、可复制
struct CommandRow: View {
    var address: String

    private var command: String { "EarPair.Sender \(address)" }

    var body: some View {
        HStack(spacing: 10) {
            Text(verbatim: command)
                .font(.system(.body, design: .monospaced))
                .textSelection(.enabled)
            Spacer()
            CopyButton(text: command, help: "复制")
        }
    }
}
