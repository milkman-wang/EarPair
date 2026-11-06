import AppKit
import EarPairCore
import SwiftUI

/// 菜单栏弹出面板：路线（Windows → 耳机）、地址或错误、音量、静音和音量平衡两个开关、打开窗口 / 退出。
/// 样式参照系统的 Wi-Fi、蓝牙、声音菜单：平铺、分隔线分组、最下面是菜单项。
public struct MenuBarContent: View {
    @ObservedObject var controller: ReceiverController
    @Environment(\.openWindow) private var openWindow

    public init(controller: ReceiverController) {
        self.controller = controller
    }

    public var body: some View {
        VStack(spacing: 0) {
            RouteView(nodes: [controller.senderNode, controller.outputNode], links: [controller.panelLink],
                      metrics: .panel)
                .accessibilityElement(children: .ignore)
                .accessibilityLabel(controller.routeAccessibilityLabel)
                .padding(.top, 18)
            if let message = controller.failureMessage {
                ErrorRow(message: message).padding(.top, 16)
            } else if controller.linkState == .waiting {
                AddressRows(addresses: controller.localAddresses, centered: false).padding(.top, 16)
            }
            VolumeRow(controller: controller, style: .panel).padding(.top, 14)
            HStack(spacing: 8) {
                ToggleTile(title: Text("Mute", bundle: .module), systemImage: "speaker.slash.fill",
                           isOn: $controller.muted)
                ToggleTile(title: Text("Auto level", bundle: .module), systemImage: "wand.and.stars",
                           isOn: $controller.autoLevel)
            }
            .padding(.top, 12)
            Divider().padding(.vertical, 8)
            MenuRow(title: Text("Open EarPair", bundle: .module)) {
                NSApp.activate()
                openWindow(id: MainWindow.id)
            }
            MenuRow(title: Text("Quit EarPair", bundle: .module), shortcut: "⌘Q") {
                NSApplication.shared.terminate(nil)
            }
            .keyboardShortcut("q")
        }
        .padding(.horizontal, 14)
        .padding(.bottom, 8)
        .frame(width: 300)
        .animation(.smooth(duration: 0.3), value: controller.linkState)
    }
}
