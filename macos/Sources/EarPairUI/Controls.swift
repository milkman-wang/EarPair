import AppKit
import SwiftUI

/// 圆形图标：可点的（开关）在 macOS 26+ 用玻璃，打开时着强调色；设备圆盘和 14/15 用实心填充，不描边
struct CircleGlyph: View {
    var systemImage: String
    var diameter: CGFloat
    var isOn = false
    var isInteractive = false
    var isPlaceholder = false

    var body: some View {
        Image(systemName: systemImage)
            .font(.system(size: diameter * (isInteractive ? 0.44 : 0.45), weight: isInteractive ? .semibold : .regular))
            .symbolRenderingMode(.hierarchical)
            .foregroundStyle(isOn ? AnyShapeStyle(.white) : isPlaceholder ? AnyShapeStyle(.tertiary) : AnyShapeStyle(.primary))
            .contentTransition(.symbolEffect(.replace))
            .frame(width: diameter, height: diameter)
            .modifier(CircleBackground(isOn: isOn, isInteractive: isInteractive, isPlaceholder: isPlaceholder))
    }
}

private struct CircleBackground: ViewModifier {
    var isOn: Bool
    var isInteractive: Bool
    var isPlaceholder: Bool

    func body(content: Content) -> some View {
        if #available(macOS 26.0, *), Appearance.usesGlass, isInteractive {
            content.glassEffect(isOn ? .regular.tint(.accentColor).interactive() : .regular.interactive(), in: .circle)
        } else if isPlaceholder {
            content.background(Circle().strokeBorder(.tertiary, style: StrokeStyle(lineWidth: 1.5, dash: [4, 4])))
        } else {
            content.background(Circle().fill(isOn ? AnyShapeStyle(Color.accentColor.gradient) : AnyShapeStyle(.fill.tertiary)))
        }
    }
}

/// 控制中心式开关：圆钮 + 名称，整块可点
struct ToggleTile: View {
    var title: LocalizedStringKey
    var systemImage: String
    @Binding var isOn: Bool

    var body: some View {
        Button {
            isOn.toggle()
        } label: {
            HStack(spacing: 8) {
                CircleGlyph(systemImage: systemImage, diameter: 28, isOn: isOn, isInteractive: true)
                Text(title)
                Spacer(minLength: 0)
            }
            .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(isOn ? .isSelected : [])
    }
}

/// 面板底部的菜单项：整行悬停高亮，和系统菜单一样
struct MenuRow: View {
    var title: LocalizedStringKey
    var shortcut: String?
    var action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            HStack {
                Text(title)
                Spacer()
                if let shortcut {
                    Text(verbatim: shortcut).foregroundStyle(.tertiary)
                }
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            .background(RoundedRectangle(cornerRadius: Appearance.usesGlass ? 8 : 5, style: .continuous)
                .fill(hovering ? AnyShapeStyle(.fill.secondary) : AnyShapeStyle(.clear)))
            .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
    }
}

/// 音量 0–200%：100% 处吸附（带触感反馈），macOS 26+ 还有刻度
struct VolumeSlider: View {
    @Binding var volume: Double
    @State private var atUnity = false

    private var snapping: Binding<Double> {
        Binding(get: { volume }, set: { newValue in
            let snap = abs(newValue - 1) < 0.04
            volume = snap ? 1 : newValue
            if snap != atUnity { atUnity = snap }
        })
    }

    var body: some View {
        Group {
            if #available(macOS 26.0, *) {
                Slider(value: snapping, in: 0...2, label: { Text("音量") }, ticks: { SliderTick(1.0) })
            } else {
                Slider(value: snapping, in: 0...2) { Text("音量") }
            }
        }
        .labelsHidden()
        .sensoryFeedback(.alignment, trigger: atUnity) { _, new in new }
    }
}

/// 左右平衡：靠近中间吸附到 0；macOS 26+ 从中间开始填充、中间有刻度
struct BalanceSlider: View {
    @Binding var balance: Double
    @State private var centered = true

    private var snapping: Binding<Double> {
        Binding(get: { balance }, set: { newValue in
            let snap = abs(newValue) < 0.05
            balance = snap ? 0 : newValue
            if snap != centered { centered = snap }
        })
    }

    var body: some View {
        Group {
            if #available(macOS 26.0, *) {
                Slider(value: snapping, in: -1...1, neutralValue: 0,
                       label: { Text("左右") },
                       minimumValueLabel: { Text("左") },
                       maximumValueLabel: { Text("右") },
                       ticks: { SliderTick(0.0) })
            } else {
                Slider(value: snapping, in: -1...1) {
                    Text("左右")
                } minimumValueLabel: {
                    Text("左")
                } maximumValueLabel: {
                    Text("右")
                }
            }
        }
        .labelsHidden()
        .foregroundStyle(.secondary)
        .sensoryFeedback(.alignment, trigger: centered) { _, new in new }
    }
}
