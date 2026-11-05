import AppKit
import EarPairCore
import SwiftUI

@main
struct EarPairApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @StateObject private var controller = ReceiverController()

    var body: some Scene {
        MenuBarExtra {
            MenuBarView(controller: controller)
        } label: {
            Image(systemName: controller.stats.state == .playing ? "ear.fill" : "ear")
        }
        .menuBarExtraStyle(.window)
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        // 只在菜单栏显示，不占 Dock（打包后 Info.plist 里的 LSUIElement 也有同样效果）
        NSApp.setActivationPolicy(.accessory)
    }
}
