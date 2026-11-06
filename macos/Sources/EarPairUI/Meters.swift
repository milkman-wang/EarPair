import SwiftUI

/// 曲线采样间隔（秒）和点数
enum HistoryTiming {
    static let interval = 0.1 * Double(ReceiverController.historyInterval)
    static let length = ReceiverController.historyLength
}

/// 最近一段时间的电平：竖条，最新的在右边，随时间平滑左移，越旧越淡
struct LevelWaveform: View {
    var points: [HistoryPoint]
    var isLive: Bool
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    private let bar: CGFloat = 2
    private let gap: CGFloat = 2

    /// 最近一分钟都没有声音（比如 Windows 只在发静音保活）：柱子全是一样的小点，不用 30 fps 滚动
    private var isSilent: Bool {
        points.allSatisfy { Self.height($0.muted ? $0.inputLevelDB : $0.outputLevelDB) == 0 }
    }

    var body: some View {
        TimelineView(.animation(minimumInterval: 1.0 / 30, paused: !isLive || reduceMotion || isSilent)) { timeline in
            Canvas { context, size in
                let step = bar + gap
                let last = points.last?.time ?? timeline.date
                let progress = isLive && !reduceMotion
                    ? CGFloat(min(1, max(0, timeline.date.timeIntervalSince(last) / HistoryTiming.interval))) : 0
                let visible = Int(size.width / step) + 2
                for (index, point) in points.suffix(visible).reversed().enumerated() {
                    let x = size.width - bar - (CGFloat(index) + progress) * step
                    let height = max(2, Self.height(point.muted ? point.inputLevelDB : point.outputLevelDB) * size.height)
                    let rect = CGRect(x: x, y: (size.height - height) / 2, width: bar, height: height)
                    var layer = context
                    layer.opacity = 0.3 + 0.7 * Double(max(0, x) / size.width)
                    layer.fill(Path(roundedRect: rect, cornerRadius: 1), with: Self.shading(point))
                }
            }
        }
        .frame(height: 40)
        .accessibilityElement()
        .accessibilityLabel(Text("Windows 声音电平"))
    }

    /// −54…−6 dBFS → 0…1，安静的部分更矮
    static func height(_ db: Double) -> CGFloat {
        CGFloat(pow(min(max((db + 54) / 48, 0), 1), 1.8))
    }

    static func shading(_ point: HistoryPoint) -> GraphicsContext.Shading {
        if point.muted { return .style(.tertiary) }
        if point.outputLevelDB < -55 { return .style(.quaternary) }
        return .color(.accentColor)
    }
}

/// 指标下面的迷你曲线：line 是连续值，events 是偶发事件（丢包、卡顿）的竖线
struct Sparkline: View {
    enum Kind { case line, events }

    var values: [Double]
    var kind: Kind
    var ceiling: Double
    var tint: Color

    var body: some View {
        Canvas { context, size in
            var base = Path()
            base.move(to: CGPoint(x: 0, y: size.height - 0.5))
            base.addLine(to: CGPoint(x: size.width, y: size.height - 0.5))
            context.stroke(base, with: .style(.quaternary), lineWidth: 1)
            guard values.count > 1 else { return }
            let dx = size.width / CGFloat(HistoryTiming.length - 1)
            let x0 = size.width - CGFloat(values.count - 1) * dx
            let top = max(ceiling, values.max() ?? 0, 0.000_1)
            switch kind {
            case .line:
                var path = Path()
                for (i, v) in values.enumerated() {
                    let p = CGPoint(x: x0 + CGFloat(i) * dx, y: size.height - 1 - CGFloat(v / top) * (size.height - 2))
                    if i == 0 { path.move(to: p) } else { path.addLine(to: p) }
                }
                context.stroke(path, with: .color(tint), style: StrokeStyle(lineWidth: 1.5, lineCap: .round, lineJoin: .round))
            case .events:
                for (i, v) in values.enumerated() where v > 0 {
                    let h = max(4, CGFloat(min(v / top, 1)) * size.height)
                    context.fill(Path(CGRect(x: x0 + CGFloat(i) * dx - 1, y: size.height - h, width: 2, height: h)),
                                 with: .color(tint))
                }
            }
        }
        .frame(height: 20)
        .accessibilityHidden(true)
    }
}

/// 一列指标：名称、大号数字和单位、迷你曲线。数字颜色表示好坏
struct MetricColumn: View {
    enum Tone { case calm, normal, warning, critical }

    var title: LocalizedStringKey
    var value: Double
    var text: String
    var unit: String
    var tone: Tone
    var spark: Sparkline

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title).font(.subheadline).foregroundStyle(.secondary)
            HStack(alignment: .firstTextBaseline, spacing: unit == "%" ? 1 : 3) {
                Text(verbatim: text)
                    .font(.title.weight(.semibold))
                    .monospacedDigit()
                    .foregroundStyle(valueStyle)
                    .contentTransition(.numericText(value: value))
                    .animation(.snappy, value: text) // 显示的数字变了才动，原始值的小抖动不触发
                Text(verbatim: unit).font(.callout.weight(.medium)).foregroundStyle(.secondary)
            }
            spark
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityElement(children: .combine)
    }

    private var valueStyle: AnyShapeStyle {
        switch tone {
        case .calm: return AnyShapeStyle(.tertiary)
        case .normal: return AnyShapeStyle(.primary)
        case .warning: return AnyShapeStyle(.orange)
        case .critical: return AnyShapeStyle(.red)
        }
    }
}
