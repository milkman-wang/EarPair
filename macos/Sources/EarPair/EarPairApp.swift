import AppKit
import EarPairUI
import SwiftUI

// 打包后 Info.plist 里的 LSUIElement 让 App 只在菜单栏显示；主窗口打开时会临时出现在 Dock 和 ⌘Tab 里。
@main
struct EarPairApp: App {
    @StateObject private var controller = ReceiverController()

    var body: some Scene {
        MenuBarExtra {
            MenuBarContent(controller: controller)
        } label: {
            MenuBarLabel(controller: controller)
        }
        .menuBarExtraStyle(.window)

        Window("EarPair", id: MainWindow.id) {
            MainWindow(controller: controller)
        }
        .windowResizability(.contentSize)
        .defaultSize(width: 900, height: 640)
        .defaultPosition(.center)
    }
}

/// 菜单栏图标。启动参数带 --show-window 时顺便打开主窗口（截图、调试用）
struct MenuBarLabel: View {
    @ObservedObject var controller: ReceiverController
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        Image(systemName: controller.menuBarSymbol)
            .onAppear {
                if CommandLine.arguments.contains("--show-window") {
                    NSApp.activate()
                    openWindow(id: MainWindow.id)
                }
            }
    }
}
