import EarPairCore
import SwiftUI

// MARK: - 空间音频

/// 空间音频页：开关；没在用时说为什么；从上往下看的示意图；位置（设置、对准 Mac）；Mac 自己的声音；看别处时的音量。
struct SpatialPane: View {
    @ObservedObject var controller: ReceiverController
    @ObservedObject var spatial: SpatialController

    init(controller: ReceiverController) {
        self.controller = controller
        spatial = controller.spatial
    }

    /// 发送端的名字：正在连着的，其次上次连过的，都没有时是“Windows 电脑”
    private var senderName: String { controller.senderName ?? controller.waitingSenderName }

    private var showsDiagram: Bool {
        spatial.setup == nil && (spatial.mode == .active || spatial.mode == .waitingForSender)
    }

    var body: some View {
        Form {
            Section {
                Toggle(isOn: $spatial.enabled) { Text("Spatial audio", bundle: .module) }
                switch spatial.mode {
                case .noPermission:
                    LabeledContent {
                        Button { spatial.openMotionSettings() } label: {
                            Text("Open System Settings", bundle: .module)
                        }
                    } label: {
                        Text("Allow EarPair to use motion data in System Settings.", bundle: .module)
                            .foregroundStyle(.secondary)
                    }
                case .noHeadphones:
                    Text("Use AirPods or other headphones that support head tracking.", bundle: .module)
                        .foregroundStyle(.secondary)
                case .waitingForSender:
                    Text("Resumes automatically when \(senderName) is sending", bundle: .module)
                        .foregroundStyle(.secondary)
                case .off, .needsSetup, .active:
                    EmptyView()
                }
            }
            if let step = spatial.setup {
                Section {
                    SpatialSetupView(step: step, progress: spatial.setupProgress, senderName: senderName,
                                     senderSymbol: senderSymbol(controller.senderKind ?? controller.lastSenderKind),
                                     macSymbol: controller.macNode.symbol, spatial: spatial)
                }
            } else {
                if showsDiagram {
                    Section {
                        SpatialDiagram(live: spatial.live, macSymbol: controller.macNode.symbol,
                                       senderSymbol: senderSymbol(controller.senderKind ?? controller.lastSenderKind))
                    }
                }
                Section {
                    LabeledContent {
                        HStack(spacing: 10) {
                            if let angle = spatial.angle {
                                Text(verbatim: SpatialText.side(angle, sender: senderName))
                                    .foregroundStyle(.secondary)
                                    .fixedSize()
                                Button { spatial.recenter() } label: { Text("Center on Mac", bundle: .module) }
                                    .help(String(localized: "Look at the Mac’s screen, then click", bundle: .module))
                                Button { spatial.beginSetup() } label: { Text("Set Up Again…", bundle: .module) }
                            } else {
                                Button { spatial.beginSetup() } label: { Text("Set Up…", bundle: .module) }
                            }
                        }
                    } label: {
                        Text("Positions", bundle: .module)
                    }
                }
            }
            if spatial.macSoundSupported {
                Section {
                    Toggle(isOn: $spatial.includeMac) { Text("Move this Mac’s sound too", bundle: .module) }
                    if spatial.macPermissionDenied {
                        LabeledContent {
                            Button { spatial.openAudioCaptureSettings() } label: {
                                Text("Open System Settings", bundle: .module)
                            }
                        } label: {
                            Text("Allow EarPair to record system audio in System Settings.", bundle: .module)
                                .foregroundStyle(.secondary)
                        }
                    } else if let failure = spatial.macFailure {
                        Text("Couldn’t capture this Mac’s sound: \(failure)", bundle: .module)
                            .foregroundStyle(.secondary)
                    }
                }
            }
            Section {
                LabeledContent {
                    HStack(spacing: 10) {
                        Slider(value: $spatial.awayVolume, in: 0...1)
                            .frame(maxWidth: 220)
                        Text(verbatim: Format.percent(spatial.awayVolume))
                            .monospacedDigit()
                            .foregroundStyle(.secondary)
                            .frame(minWidth: 40, alignment: .trailing)
                    }
                } label: {
                    Text("Volume when looking away", bundle: .module)
                }
            }
        }
        .formStyle(.grouped)
        .animation(.smooth(duration: 0.3), value: spatial.mode)
        .animation(.smooth(duration: 0.3), value: spatial.setup)
    }
}

enum SpatialText {
    /// “DESKTOP-7Q2 在 Mac 左边 52°”。angle：发送端在 Mac 左边多少度（右边为负）
    static func side(_ angle: Double, sender: String) -> String {
        let degrees = Int(abs(angle).rounded())
        return angle >= 0
            ? String(localized: "\(sender) is \(degrees)° to the left of the Mac", bundle: .module)
            : String(localized: "\(sender) is \(degrees)° to the right of the Mac", bundle: .module)
    }
}

/// 校准：先正对 Mac，再正对发送端，每一步头稳住时圆环转满；最后问要不要保存
struct SpatialSetupView: View {
    let step: SpatialController.SetupStep
    let progress: Double
    let senderName: String
    let senderSymbol: String
    let macSymbol: String
    let spatial: SpatialController

    var body: some View {
        VStack(spacing: 16) {
            switch step {
            case .mac:
                SetupRing(symbol: macSymbol, progress: progress)
                Text("Face the center of this Mac’s screen", bundle: .module)
                    .font(.title3.weight(.medium))
                cancel
            case .sender:
                SetupRing(symbol: senderSymbol, progress: progress)
                Text("Now face the center of \(senderName)’s screen", bundle: .module)
                    .font(.title3.weight(.medium))
                cancel
            case .review(let angle):
                Image(systemName: "checkmark.circle.fill")
                    .font(.system(size: 34))
                    .foregroundStyle(.green)
                Text(verbatim: SpatialText.side(angle, sender: senderName))
                    .font(.title3.weight(.medium))
                Text("Save these positions?", bundle: .module)
                    .foregroundStyle(.secondary)
                HStack(spacing: 10) {
                    Button { spatial.beginSetup() } label: { Text("Start Over", bundle: .module) }
                    Button { spatial.saveSetup() } label: { Text("Save", bundle: .module) }
                        .keyboardShortcut(.defaultAction)
                }
            case .failed:
                Image(systemName: "exclamationmark.circle.fill")
                    .font(.system(size: 34))
                    .foregroundStyle(.orange)
                Text("Didn’t catch that. Hold still for a moment while facing each screen.", bundle: .module)
                    .multilineTextAlignment(.center)
                HStack(spacing: 10) {
                    cancel
                    Button { spatial.beginSetup() } label: { Text("Try Again", bundle: .module) }
                        .keyboardShortcut(.defaultAction)
                }
            }
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 18)
    }

    private var cancel: some View {
        Button { spatial.cancelSetup() } label: { Text("Cancel", bundle: .module) }
    }
}

/// 圆环：头稳住多久转多满，中间是要看的那台电脑
private struct SetupRing: View {
    let symbol: String
    let progress: Double

    var body: some View {
        ZStack {
            Circle().stroke(.quaternary, lineWidth: 4)
            Circle()
                .trim(from: 0, to: progress)
                .stroke(Color.accentColor, style: StrokeStyle(lineWidth: 4, lineCap: .round))
                .rotationEffect(.degrees(-90))
                .animation(.linear(duration: 0.1), value: progress)
            Image(systemName: symbol)
                .font(.system(size: 26))
                .foregroundStyle(.secondary)
        }
        .frame(width: 72, height: 72)
    }
}

/// 从上往下看：头在中间、朝上，两台电脑在它们相对头的方向上，转头时跟着绕
struct SpatialDiagram: View {
    @ObservedObject var live: SpatialLive
    let macSymbol: String
    let senderSymbol: String

    private let radius = 70.0

    var body: some View {
        ZStack {
            Circle()
                .stroke(.quaternary, lineWidth: 1)
                .frame(width: radius * 2, height: radius * 2)
            HeadGlyph()
            device(macSymbol, relative: live.macRelative)
            device(senderSymbol, relative: live.senderRelative)
        }
        .frame(maxWidth: .infinity)
        .frame(height: radius * 2 + 56)
        .animation(.linear(duration: 0.12), value: live.macRelative)
        .animation(.linear(duration: 0.12), value: live.senderRelative)
        .accessibilityHidden(true)
    }

    /// relative：左为正（度）；屏幕上朝上是正前方
    private func device(_ symbol: String, relative: Double?) -> some View {
        let radians = (relative ?? 0) * .pi / 180
        return Image(systemName: symbol)
            .font(.system(size: 22))
            .foregroundStyle(.primary)
            .padding(6)
            .background(.background, in: Circle())
            .offset(x: -sin(radians) * radius, y: -cos(radians) * radius)
            .opacity(relative == nil ? 0 : 1)
    }
}

/// 头（从上往下看）：圆，上面一个小三角是鼻子
private struct HeadGlyph: View {
    var body: some View {
        ZStack {
            Circle()
                .fill(.secondary)
                .frame(width: 26, height: 26)
            Triangle()
                .fill(.secondary)
                .frame(width: 10, height: 7)
                .offset(y: -16)
        }
    }

    private struct Triangle: Shape {
        func path(in rect: CGRect) -> Path {
            var path = Path()
            path.move(to: CGPoint(x: rect.midX, y: rect.minY))
            path.addLine(to: CGPoint(x: rect.maxX, y: rect.maxY))
            path.addLine(to: CGPoint(x: rect.minX, y: rect.maxY))
            path.closeSubpath()
            return path
        }
    }
}

/// App 菜单里的调试记录开关和“在访达中显示记录”
public struct SpatialCommands: Commands {
    @ObservedObject var spatial: SpatialController

    public init(spatial: SpatialController) {
        self.spatial = spatial
    }

    public var body: some Commands {
        CommandGroup(after: .appSettings) {
            Toggle(isOn: $spatial.recording) { Text("Record Spatial Audio Data", bundle: .module) }
            Button { spatial.showRecordings() } label: { Text("Show Recordings in Finder", bundle: .module) }
        }
    }
}
