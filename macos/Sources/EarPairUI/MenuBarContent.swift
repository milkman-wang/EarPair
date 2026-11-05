import AppKit
import EarPairCore
import SwiftUI

/// 菜单栏弹出面板：状态、音量、音量平衡。其余设置在主窗口里。
public struct MenuBarContent: View {
    @ObservedObject var controller: ReceiverController
    @Environment(\.openWindow) private var openWindow

    public init(controller: ReceiverController) {
        self.controller = controller
    }

    private var stats: ReceiverStats { controller.stats }

    public var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            header
            if let message = controller.errorMessage {
                Text(verbatim: message)
                    .font(.callout)
                    .foregroundStyle(.red)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if !stats.isStreaming {
                ForEach(controller.localAddresses, id: \.self) { local in
                    AddressRow(address: local.address)
                }
            }
            VolumeControl(controller: controller, showsMute: true, showsMeter: true)
            GlassToggleTile(title: "音量平衡", systemImage: "wand.and.stars", isOn: $controller.autoLevel)
        }
        .padding(16)
        .frame(width: 300)
    }

    private var header: some View {
        HStack(spacing: 8) {
            StatusDot(color: stats.statusColor)
            Text(verbatim: stats.statusTitle)
                .font(.headline)
                .lineLimit(1)
            if stats.state == .buffering {
                ProgressView().controlSize(.mini)
            }
            Spacer(minLength: 8)
            HStack(spacing: 12) {
                IconButton(systemImage: "macwindow", help: "打开 EarPair") {
                    NSApp.activate()
                    openWindow(id: MainWindow.id)
                }
                IconButton(systemImage: "power", help: "退出 EarPair") {
                    NSApplication.shared.terminate(nil)
                }
            }
        }
    }
}
