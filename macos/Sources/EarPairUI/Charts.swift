import Charts
import SwiftUI

/// 横轴固定为最近一分钟：曲线从右边长出来，满了以后往左滚
private func recentDomain(_ history: [HistoryPoint]) -> ClosedRange<Int> {
    let last = history.last?.id ?? 0
    let span = (ReceiverController.historyLength - 1) * ReceiverController.historyInterval
    return (last - span)...last
}

/// 最近一分钟的输出电平
struct LevelHistoryChart: View {
    var history: [HistoryPoint]

    var body: some View {
        Chart(history) { point in
            let level = max(point.outputLevelDB, -60)
            AreaMark(x: .value("时间", point.id), yStart: .value("下限", -60), yEnd: .value("电平", level))
                .foregroundStyle(LinearGradient(colors: [.green.opacity(0.4), .green.opacity(0.03)],
                                                startPoint: .top, endPoint: .bottom))
                .interpolationMethod(.monotone)
            LineMark(x: .value("时间", point.id), y: .value("电平", level))
                .foregroundStyle(.green)
                .lineStyle(StrokeStyle(lineWidth: 1.5))
                .interpolationMethod(.monotone)
        }
        .chartXScale(domain: recentDomain(history))
        .chartYScale(domain: -60...0)
        .chartXAxis(.hidden)
        .chartYAxis {
            AxisMarks(position: .trailing, values: [-60, -30, 0]) { value in
                AxisGridLine()
                AxisValueLabel {
                    if let db = value.as(Int.self) { Text(verbatim: "\(db)".replacingOccurrences(of: "-", with: "−")) }
                }
            }
        }
    }
}

/// 最近一分钟的缓冲水位，虚线是目标
struct BufferHistoryChart: View {
    var history: [HistoryPoint]
    var target: Double

    private var upperBound: Double {
        max(target * 2, (history.map(\.bufferMs).max() ?? 0) + 10)
    }

    var body: some View {
        Chart {
            RuleMark(y: .value("目标", target))
                .foregroundStyle(.secondary)
                .lineStyle(StrokeStyle(lineWidth: 1, dash: [4, 3]))
            ForEach(history) { point in
                LineMark(x: .value("时间", point.id), y: .value("缓冲", point.bufferMs))
                    .foregroundStyle(.blue)
                    .lineStyle(StrokeStyle(lineWidth: 1.5))
                    .interpolationMethod(.monotone)
            }
        }
        .chartXScale(domain: recentDomain(history))
        .chartYScale(domain: 0...upperBound)
        .chartXAxis(.hidden)
        .chartYAxis {
            AxisMarks(position: .trailing) { value in
                AxisGridLine()
                AxisValueLabel {
                    if let ms = value.as(Double.self) { Text(verbatim: "\(Int(ms)) ms") }
                }
            }
        }
    }
}
