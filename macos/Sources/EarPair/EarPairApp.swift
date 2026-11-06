import AppKit
import EarPairUI
import SwiftUI

// 打包后 Info.plist 里的 LSUIElement 让 App 只在菜单栏显示；主窗口打开时会临时出现在 Dock 和 ⌘Tab 里。
@main
struct EarPairApp: App {
    /// App 自己不订阅控制器：控制器播放时每 0.1 秒更新统计，订阅了的话整个场景连同菜单栏图标都会跟着重算。
    /// 面板和窗口各自订阅；菜单栏图标只订阅 MenuBarIcon。App 只创建一次，这里的实例也只有一个。
    private let controller = ReceiverController()

    var body: some Scene {
        MenuBarExtra {
            MenuBarContent(controller: controller)
        } label: {
            MenuBarLabel(icon: controller.menuBarIcon)
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

/// 菜单栏图标：只在图标变了的时候重画。启动参数带 --show-window 时顺便打开主窗口（截图、调试用）
struct MenuBarLabel: View {
    @ObservedObject var icon: MenuBarIcon
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        Image(systemName: icon.symbol)
            .onAppear {
                if CommandLine.arguments.contains("--show-window") {
                    NSApp.activate()
                    openWindow(id: MainWindow.id)
                }
            }
    }
}
