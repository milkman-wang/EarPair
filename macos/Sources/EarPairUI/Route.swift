import SwiftUI

// 音频路线：Windows 电脑 → Mac → 耳机。布局本身说明现在发生了什么。

struct RouteMetrics: Sendable {
    var circle: CGFloat
    var label: CGFloat
    var labelSpacing: CGFloat
    var line: CGFloat
    var gap: CGFloat
    var minLink: CGFloat
    var maxLink: CGFloat
    var pulseLength: CGFloat
    var pulseSpacing: CGFloat
    var pulseSpeed: Double
    var nameFont: Font
    /// 面板里连线短：标签只用图标，“等待连接”不显示文字
    var compactPills: Bool

    static let window = RouteMetrics(circle: 64, label: 168, labelSpacing: 8, line: 3, gap: 12,
                                     minLink: 96, maxLink: 220, pulseLength: 10, pulseSpacing: 26,
                                     pulseSpeed: 40, nameFont: .body, compactPills: false)
    static let panel = RouteMetrics(circle: 40, label: 140, labelSpacing: 6, line: 2.5, gap: 8,
                                    minLink: 64, maxLink: 180, pulseLength: 8, pulseSpacing: 22,
                                    pulseSpeed: 32, nameFont: .callout, compactPills: true)
}

struct RouteNode: Equatable {
    var symbol: String
    var name: String
    var isPlaceholder = false
    var isDimmed = false
    /// 右下角的小角标，比如静音时的 speaker.slash.fill
    var badge: String?
}

struct DeviceNode: View {
    var node: RouteNode
    var metrics: RouteMetrics

    var body: some View {
        VStack(spacing: metrics.labelSpacing) {
            CircleGlyph(systemImage: node.symbol, diameter: metrics.circle, isPlaceholder: node.isPlaceholder)
                .overlay(alignment: .bottomTrailing) {
                    if let badge = node.badge {
                        Image(systemName: badge)
                            .font(.system(size: metrics.circle * 0.17, weight: .bold))
                            .foregroundStyle(.white)
                            .frame(width: metrics.circle * 0.34, height: metrics.circle * 0.34)
                            .background(Circle().fill(.gray))
                            .offset(x: 2, y: 2)
                            .transition(.scale.combined(with: .opacity))
                    }
                }
                .opacity(node.isDimmed ? 0.45 : 1)
            DeviceName(name: node.name)
                .font(metrics.nameFont.weight(.medium))
                .foregroundStyle(node.isPlaceholder || node.isDimmed ? .secondary : .primary)
                .frame(width: metrics.label) // 比圆宽：往两边溢出，不撑开布局
        }
        .frame(width: metrics.circle)
        .accessibilityElement(children: .combine)
    }
}

/// 设备名：放得下就一行；放不下就在“的”/“'s ”后面断开（milkman的 / AirPods Pro），不让“Pro”单独掉到第二行
struct DeviceName: View {
    var name: String

    private var parts: (String, String)? {
        for marker in ["的", "'s ", "’s "] {
            if let range = name.range(of: marker), range.upperBound < name.endIndex {
                return (String(name[..<range.upperBound]).trimmingCharacters(in: .whitespaces),
                        String(name[range.upperBound...]))
            }
        }
        return nil
    }

    var body: some View {
        ViewThatFits(in: .horizontal) {
            Text(verbatim: name).lineLimit(1)
            if let (owner, product) = parts {
                VStack(spacing: 1) {
                    Text(verbatim: owner).lineLimit(1)
                    Text(verbatim: product).lineLimit(1)
                }
            }
            Text(verbatim: name).lineLimit(2).multilineTextAlignment(.center)
        }
    }
}

struct RouteLink: View {
    enum Style: Equatable {
        /// 点线：等待发送端
        case waiting
        /// 点线流动：收到了包，正在缓冲
        case connecting
        /// 淡色实线：在播放但没有声音
        case quiet
        /// 实线加流动的光点，强度跟着电平
        case flowing(Double)
        /// 灰色实线：这一段没在用
        case inactive
        /// 灰色实线：断开了（中间有“已断开”标签）
        case broken
        /// 红色：出错
        case failed
    }

    enum Pill: Equatable {
        case waiting
        case stopped
        case disconnected
        case failed(String)
    }

    var style: Style
    var pill: Pill?
    var metrics: RouteMetrics

    /// 面板里连线短，“等待连接”“已停止”只看线型，不放标签
    private var shownPill: Pill? {
        guard metrics.compactPills else { return pill }
        return pill == .waiting || pill == .stopped ? nil : pill
    }

    var body: some View {
        Group {
            if let pill = shownPill {
                // 有标签时线断开，标签坐在缺口里
                HStack(spacing: 6) {
                    LinkStroke(style: style, metrics: metrics, leading: metrics.gap, trailing: 0)
                    PillLabel(pill: pill, compact: metrics.compactPills)
                    LinkStroke(style: style, metrics: metrics, leading: 0, trailing: metrics.gap)
                }
                .transition(.opacity)
            } else {
                LinkStroke(style: style, metrics: metrics, leading: metrics.gap, trailing: metrics.gap)
                    .transition(.opacity)
            }
        }
        .animation(.smooth(duration: 0.3), value: style)
        .animation(.smooth(duration: 0.3), value: pill)
    }
}

/// 一段连线：等待是点线，缓冲中点线流动，播放中是强调色实线 + 流动的光点
struct LinkStroke: View {
    var style: RouteLink.Style
    var metrics: RouteMetrics
    var leading: CGFloat
    var trailing: CGFloat
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.colorSchemeContrast) private var contrast

    private var animates: Bool {
        guard !reduceMotion else { return false }
        switch style {
        case .connecting, .flowing: return true
        default: return false
        }
    }

    var body: some View {
        TimelineView(.animation(minimumInterval: 1.0 / 30, paused: !animates)) { timeline in
            Canvas { context, size in
                draw(&context, size: size, time: timeline.date.timeIntervalSinceReferenceDate)
            }
        }
        .frame(minWidth: 12)
        .accessibilityHidden(true)
    }

    private func draw(_ context: inout GraphicsContext, size: CGSize, time: Double) {
        let y = size.height / 2
        let start = leading
        let end = size.width - trailing
        guard end - start > 2 else { return }
        var line = Path()
        line.move(to: CGPoint(x: start, y: y))
        line.addLine(to: CGPoint(x: end, y: y))
        let solid = StrokeStyle(lineWidth: metrics.line, lineCap: .round)
        let dotted = StrokeStyle(lineWidth: metrics.line, lineCap: .round, dash: [0.1, 7],
                                 dashPhase: style == .connecting ? CGFloat(-time * 24) : 0)
        // “提高对比度”打开时：淡色实线更实，点线更深
        let increased = contrast == .increased
        let base = increased ? 0.6 : 0.35
        switch style {
        case .waiting:
            context.stroke(line, with: increased ? .style(.secondary) : .style(.tertiary), style: dotted)
        case .connecting:
            context.stroke(line, with: .style(.secondary), style: dotted)
        case .quiet:
            context.stroke(line, with: .color(.accentColor.opacity(base)), style: solid)
        case .flowing(let intensity):
            context.stroke(line, with: .color(.accentColor.opacity(reduceMotion ? base + (1 - base) * intensity : base)),
                           style: solid)
            guard !reduceMotion, intensity > 0.02 else { return }
            var pulses = context
            if colorScheme == .dark { pulses.addFilter(.shadow(color: .accentColor.opacity(0.7), radius: 3)) }
            let offset = CGFloat((time * metrics.pulseSpeed).truncatingRemainder(dividingBy: Double(metrics.pulseSpacing)))
            var x = start + offset
            while x + metrics.pulseLength < end {
                let rect = CGRect(x: x, y: y - metrics.line / 2, width: metrics.pulseLength, height: metrics.line)
                pulses.fill(Path(roundedRect: rect, cornerRadius: metrics.line / 2),
                            with: .color(.accentColor.opacity(intensity)))
                x += metrics.pulseSpacing
            }
        case .inactive, .broken:
            context.stroke(line, with: .style(.quaternary), style: solid)
        case .failed:
            context.stroke(line, with: .color(.red.opacity(0.55)), style: solid)
        }
    }
}

struct PillLabel: View {
    var pill: RouteLink.Pill
    var compact = false

    var body: some View {
        if compact {
            Image(systemName: symbol)
                .font(.system(size: 11, weight: .bold))
                .symbolRenderingMode(isFailure ? .multicolor : .hierarchical)
                .foregroundStyle(.secondary)
                .accessibilityLabel(Text(verbatim: text))
        } else {
            HStack(spacing: 4) {
                if isFailure {
                    Image(systemName: "exclamationmark.triangle.fill").symbolRenderingMode(.multicolor)
                }
                Text(verbatim: text)
            }
            .font(.subheadline.weight(.medium))
            .foregroundStyle(.secondary)
            .padding(.horizontal, 8)
            .padding(.vertical, 3)
            .background(.fill.quaternary, in: Capsule())
            .fixedSize()
        }
    }

    private var isFailure: Bool {
        if case .failed = pill { return true }
        return false
    }

    private var symbol: String { isFailure ? "exclamationmark.triangle.fill" : "xmark" }

    private var text: String {
        switch pill {
        case .waiting: return "等待连接"
        case .stopped: return "已停止"
        case .disconnected: return "已断开"
        case .failed(let short): return short
        }
    }
}

struct RouteView: View {
    var nodes: [RouteNode]
    var links: [(style: RouteLink.Style, pill: RouteLink.Pill?)]
    var metrics: RouteMetrics

    var body: some View {
        HStack(alignment: .top, spacing: 0) {
            ForEach(nodes.indices, id: \.self) { index in
                DeviceNode(node: nodes[index], metrics: metrics)
                if index < links.count {
                    RouteLink(style: links[index].style, pill: links[index].pill, metrics: metrics)
                        .frame(minWidth: metrics.minLink, maxWidth: metrics.maxLink)
                        .frame(height: metrics.circle)
                }
            }
        }
        .padding(.horizontal, (metrics.label - metrics.circle) / 2)
        .frame(maxWidth: .infinity)
    }
}
