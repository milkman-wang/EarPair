import AppKit
import EarPairCore
import SwiftUI

// 四个页面都是系统设置样式的分组表单。表单自己的滚动区域铺满内容区，滚动容器上不加 maxWidth
//（加了的话，侧边栏收起后工具栏下面的滚动边缘只有内容那么宽，两边会露出缺口）。

// MARK: - 概览

/// 概览：音频路线、实时波形和音量、三个关键指标。等待时只有路线和音量。
struct OverviewPane: View {
    @ObservedObject var controller: ReceiverController

    /// 波形只在有流的时候出现
    private var showsWaveform: Bool {
        switch controller.linkState {
        case .connecting, .playing, .outputFailed: return true
        case .waiting, .stopped, .disconnected, .receiveFailed: return false
        }
    }

    /// 指标：停止或断开后保留结束那一刻的数据（变淡），回到等待后不再显示
    private var showsHealth: Bool {
        switch controller.linkState {
        case .waiting, .receiveFailed: return false
        case .connecting, .playing, .outputFailed, .stopped, .disconnected: return true
        }
    }

    private var hasEnded: Bool { controller.linkState == .stopped || controller.linkState == .disconnected }

    var body: some View {
        Form {
            Section {
                VStack(spacing: 14) {
                    RouteView(nodes: [controller.senderNode, controller.macNode, controller.outputNode],
                              links: controller.windowLinks, metrics: .window)
                        .accessibilityElement(children: .ignore)
                        .accessibilityLabel(controller.routeAccessibilityLabel)
                    if controller.linkState == .waiting {
                        AddressRows(addresses: controller.localAddresses, centered: true)
                    }
                    if let message = controller.failureMessage {
                        ErrorRow(message: message)
                            .multilineTextAlignment(.center)
                            .frame(maxWidth: 420)
                    }
                }
                .padding(.vertical, 14)
            }
            Section {
                if showsWaveform {
                    LevelWaveform(points: controller.history, isLive: controller.stats.isStreaming)
                }
                // 音量和开关一直能用，任何状态下都不变淡
                LabeledContent("音量") { VolumeRow(controller: controller, style: .form) }
                LabeledContent("音量平衡") {
                    HStack(spacing: 10) {
                        if controller.autoLevel && controller.linkState == .playing {
                            Text(verbatim: Format.signedDecibels(controller.stats.levelingGainDB))
                                .monospacedDigit()
                                .foregroundStyle(.secondary)
                                .contentTransition(.numericText(value: controller.stats.levelingGainDB))
                        }
                        Toggle("音量平衡", isOn: $controller.autoLevel)
                            .labelsHidden()
                            .toggleStyle(.switch)
                    }
                }
            }
            if showsHealth {
                Section {
                    HealthRow(controller: controller)
                        .opacity(hasEnded ? 0.5 : 1)
                }
            }
        }
        .formStyle(.grouped)
        .animation(.smooth(duration: 0.3), value: controller.linkState)
        .animation(.smooth(duration: 0.35), value: showsWaveform)
        .animation(.smooth(duration: 0.35), value: showsHealth)
    }
}

/// 缓冲、丢包、卡顿三栏，每栏下面是最近一分钟的小图
struct HealthRow: View {
    @ObservedObject var controller: ReceiverController

    var body: some View {
        let stats = controller.stats
        let history = controller.history
        HStack(spacing: 0) {
            MetricColumn(title: "缓冲", value: stats.bufferedMs, text: "\(Int(stats.bufferedMs.rounded()))", unit: "ms",
                         tone: stats.bufferedMs < stats.targetMs / 2 ? .warning : .normal,
                         spark: Sparkline(values: history.map(\.bufferMs), kind: .line,
                                          ceiling: stats.targetMs * 2, tint: .secondary))
            Divider().padding(.horizontal, 14)
            MetricColumn(title: "丢包", value: stats.lossPercent, text: Format.lossPercent(stats.lossPercent), unit: "%",
                         tone: .loss(stats.lossPercent),
                         spark: Sparkline(values: history.map { Double($0.packetsLost) }, kind: .events,
                                          ceiling: 5, tint: .orange))
            Divider().padding(.horizontal, 14)
            MetricColumn(title: "卡顿", value: Double(stats.underruns), text: "\(stats.underruns)", unit: "次",
                         tone: .underruns(stats.underruns),
                         spark: Sparkline(values: history.map { Double($0.underruns) }, kind: .events,
                                          ceiling: 1, tint: .orange))
        }
        .padding(.vertical, 4)
    }
}

// MARK: - 声音

struct SoundPane: View {
    @ObservedObject var controller: ReceiverController

    private var stats: ReceiverStats { controller.stats }

    var body: some View {
        Form {
            Section {
                LabeledContent("音量") { VolumeRow(controller: controller, style: .form) }
                LabeledContent("左右") { BalanceSlider(balance: $controller.balance) }
            }
            Section {
                Toggle("音量平衡", isOn: $controller.autoLevel)
                LabeledContent("目标响度") {
                    Picker("目标响度", selection: $controller.loudness) {
                        ForEach(LoudnessPreset.allCases) { preset in
                            Text(preset.title).tag(preset)
                        }
                    }
                    .pickerStyle(.segmented)
                    .labelsHidden()
                    .fixedSize()
                }
                .disabled(!controller.autoLevel)
                if controller.autoLevel && stats.state == .playing {
                    LabeledContent("当前增益") {
                        Text(verbatim: Format.signedDecibels(stats.levelingGainDB))
                            .monospacedDigit()
                            .contentTransition(.numericText(value: stats.levelingGainDB))
                    }
                }
            }
            Section {
                LabeledContent("输出") {
                    if let device = controller.outputDevice {
                        Label(device.name, systemImage: device.symbolName)
                    } else {
                        Text("没有输出设备")
                    }
                }
            }
        }
        .formStyle(.grouped)
        .animation(.smooth(duration: 0.3), value: stats.state)
    }
}

// MARK: - 网络

struct NetworkPane: View {
    @ObservedObject var controller: ReceiverController

    private var stats: ReceiverStats { controller.stats }

    var body: some View {
        Form {
            Section {
                LabeledContent("缓冲") {
                    Picker("缓冲", selection: $controller.bufferMs) {
                        ForEach([30, 60, 100, 150], id: \.self) { value in
                            Text(verbatim: "\(value) ms").tag(value)
                        }
                    }
                    .pickerStyle(.segmented)
                    .labelsHidden()
                    .fixedSize()
                }
                if !controller.history.isEmpty {
                    BufferHistoryChart(history: controller.history, target: Double(controller.bufferMs))
                        .frame(height: 110)
                        .padding(.vertical, 4)
                }
            }
            Section {
                StatRow(title: "收到", value: stats.packetsReceived, text: "\(Format.count(stats.packetsReceived)) 个")
                StatRow(title: "丢包", value: stats.packetsLost,
                        text: "\(Format.count(stats.packetsLost)) 个 · \(Format.lossPercent(stats.lossPercent))%",
                        tone: .loss(stats.lossPercent))
                StatRow(title: "迟到", value: stats.packetsLate, text: "\(Format.count(stats.packetsLate)) 个")
                StatRow(title: "卡顿", value: stats.underruns, text: "\(Format.count(stats.underruns)) 次",
                        tone: .underruns(stats.underruns))
                StatRow(title: "跳过", value: stats.latencyTrims, text: "\(Format.count(stats.latencyTrims)) 次")
                LabeledContent("抖动") {
                    Text(verbatim: stats.isStreaming ? Format.milliseconds(stats.jitterMs, digits: 1) : "—")
                        .foregroundStyle(stats.isStreaming ? .secondary : .tertiary)
                }
                LabeledContent("码率") {
                    Text(verbatim: stats.isStreaming ? Format.megabits(controller.bitrateKbps) : "—")
                        .foregroundStyle(stats.isStreaming ? .secondary : .tertiary)
                }
            }
            .monospacedDigit()
            Section {
                Toggle("时钟漂移补偿", isOn: $controller.driftCompensation)
                LabeledContent("时钟偏差") {
                    Text(verbatim: driftText(stats))
                        .monospacedDigit()
                        .foregroundStyle(stats.state == .playing && stats.secondsPlayed >= 60 ? .secondary : .tertiary)
                }
            }
        }
        .formStyle(.grouped)
        .toolbar {
            ToolbarItem {
                Button("重置统计", systemImage: "arrow.counterclockwise") {
                    controller.resetStatistics()
                }
                .help("重置统计")
            }
        }
    }
}

/// 统计的一行：为 0 时用浅色，超过阈值时橙色或红色
private struct StatRow: View {
    var title: LocalizedStringKey
    var value: Int
    var text: String
    var tone: MetricColumn.Tone = .normal

    var body: some View {
        LabeledContent(title) {
            Text(verbatim: text)
                .foregroundStyle(style)
                .contentTransition(.numericText(value: Double(value)))
        }
    }

    private var style: AnyShapeStyle {
        if value == 0 { return AnyShapeStyle(.tertiary) }
        switch tone {
        case .warning: return AnyShapeStyle(.orange)
        case .critical: return AnyShapeStyle(.red)
        case .calm, .normal: return AnyShapeStyle(.secondary)
        }
    }
}

// MARK: - 连接

struct ConnectionPane: View {
    @ObservedObject var controller: ReceiverController

    private var stats: ReceiverStats { controller.stats }

    var body: some View {
        Form {
            Section {
                DeviceHeaderRow(symbol: controller.macNode.symbol, title: controller.macName) {}
                ForEach(controller.localAddresses, id: \.self) { local in
                    LabeledContent {
                        HStack(spacing: 8) {
                            Text(verbatim: local.address)
                                .monospacedDigit()
                                .textSelection(.enabled)
                            CopyButton(text: local.address, help: "复制地址")
                        }
                    } label: {
                        Text(verbatim: local.name)
                    }
                }
                LabeledContent("端口") {
                    Text(verbatim: "\(ReceiverController.port)").monospacedDigit()
                }
            }
            Section {
                switch controller.linkState {
                case .waiting, .receiveFailed:
                    DeviceHeaderRow(symbol: senderSymbol(controller.lastSenderKind),
                                    title: controller.waitingSenderName, isPlaceholder: true) {
                        StatusPill(state: controller.linkState)
                    }
                case .connecting, .playing, .stopped, .disconnected, .outputFailed:
                    DeviceHeaderRow(symbol: senderSymbol(controller.senderKind), title: controller.senderDisplayName) {
                        StatusPill(state: controller.linkState)
                    }
                    if let address = stats.senderAddress {
                        LabeledContent("地址") {
                            Text(verbatim: address).monospacedDigit().textSelection(.enabled)
                        }
                    }
                    if let format = stats.formatText {
                        LabeledContent("格式", value: format)
                    }
                    LabeledContent("已播放") {
                        Text(verbatim: Format.duration(stats.secondsPlayed)).monospacedDigit()
                    }
                }
            }
        }
        .formStyle(.grouped)
        .animation(.smooth(duration: 0.3), value: controller.linkState)
    }
}

// MARK: - 小部件

func driftText(_ stats: ReceiverStats) -> String {
    guard stats.isStreaming else { return "—" }
    if stats.state == .playing && stats.secondsPlayed < 60 { return "测量中…" }
    return Format.ppm(stats.driftPPM)
}
