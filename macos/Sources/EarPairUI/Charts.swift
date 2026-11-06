import Charts
import SwiftUI

/// 横轴固定为最近一分钟：曲线从右边长出来，满了以后往左滚
private func recentDomain(_ history: [HistoryPoint]) -> ClosedRange<Int> {
    let last = history.last?.id ?? 0
    let span = (ReceiverController.historyLength - 1) * ReceiverController.historyInterval
    return (last - span)...last
}

/// 最近一分钟的缓冲水位：强调色折线和渐变面积，虚线是目标。不画坐标轴
struct BufferHistoryChart: View {
    var history: [HistoryPoint]
    var target: Double

    private var upperBound: Double {
        max(target * 2, (history.map(\.bufferMs).max() ?? 0) + 10)
    }

    var body: some View {
        Chart {
            ForEach(history) { point in
                AreaMark(x: .value("时间", point.id), yStart: .value("下限", 0), yEnd: .value("缓冲", point.bufferMs))
                    .foregroundStyle(LinearGradient(colors: [.accentColor.opacity(0.2), .accentColor.opacity(0)],
                                                    startPoint: .top, endPoint: .bottom))
                    .interpolationMethod(.monotone)
                LineMark(x: .value("时间", point.id), y: .value("缓冲", point.bufferMs))
                    .foregroundStyle(Color.accentColor)
                    .lineStyle(StrokeStyle(lineWidth: 1.5))
                    .interpolationMethod(.monotone)
            }
            RuleMark(y: .value("目标", target))
                .foregroundStyle(.secondary)
                .lineStyle(StrokeStyle(lineWidth: 1, dash: [4, 3]))
                .annotation(position: .top, alignment: .trailing) {
                    Text(verbatim: Format.milliseconds(target))
                        .font(.caption)
                        .monospacedDigit()
                        .foregroundStyle(.secondary)
                }
        }
        .chartXScale(domain: recentDomain(history))
        .chartYScale(domain: 0...upperBound)
        .chartXAxis(.hidden)
        .chartYAxis(.hidden)
        .accessibilityLabel(Text("最近一分钟的缓冲水位"))
    }
}
