import AppKit
import EarPairUI
import os
import SwiftUI

// 打包后 Info.plist 里的 LSUIElement 让 App 只在菜单栏显示；主窗口打开时会临时出现在 Dock 和 ⌘Tab 里。
//
// 主窗口必须排在菜单栏前面：SwiftUI 把第一个窗口场景当作主场景，从“应用程序”、启动台、聚焦搜索打开 App 时
// 弹出它，作为登录项启动时不弹；窗口菜单里也才有“关闭”（⌘W）这些标准项。
// App 已经在运行时再打开一次，由 AppDelegate 把窗口叫出来。
@main
struct EarPairApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    /// App 自己不订阅控制器：控制器播放时每 0.1 秒更新统计，订阅了的话整个场景连同菜单栏图标都会跟着重算。
    /// 面板和窗口各自订阅；菜单栏图标只订阅 MenuBarIcon。App 只创建一次，这里的实例也只有一个。
    private let controller = ReceiverController()

    var body: some Scene {
        Window(Text(verbatim: "EarPair"), id: MainWindow.id) {
            MainWindow(controller: controller)
        }
        .windowResizability(.contentSize)
        .defaultSize(width: 900, height: 640)
        .defaultPosition(.center)
        // 没有帮助文档：去掉“帮助”菜单里点了只会提示没有帮助的那一项
        .commands {
            CommandGroup(replacing: .help) {}
            UpdateCommands(updates: controller.updates)
            SpatialCommands(spatial: controller.spatial)
        }

        MenuBarScene(controller: controller)
    }
}

/// 菜单栏图标和面板。顺便把 openWindow 交给 MainWindowOpener（AppKit 那边拿不到）
struct MenuBarScene: Scene {
    let controller: ReceiverController
    @Environment(\.openWindow) private var openWindow

    var body: some Scene {
        MenuBarExtra {
            MenuBarContent(controller: controller)
        } label: {
            MenuBarLabel(icon: controller.menuBarIcon)
        }
        .menuBarExtraStyle(.window)
        .onChange(of: 0, initial: true) { MainWindowOpener.shared.register(openWindow) }
    }
}

/// 菜单栏图标：只在图标变了的时候重画
struct MenuBarLabel: View {
    @ObservedObject var icon: MenuBarIcon

    var body: some View {
        Image(systemName: icon.symbol)
    }
}

private let appLog = Logger(subsystem: "app.earpair", category: "app")

final class AppDelegate: NSObject, NSApplicationDelegate {
    private var lastWake = Date.distantPast

    /// 用户自己打开（“应用程序”、启动台、聚焦搜索）时主窗口会弹出来，要带到前台。只在菜单栏的 App（LSUIElement）
    /// 系统启动时不激活；macOS 14 起的“协作式”激活（NSApp.activate()）也会被拒绝，焦点留在访达等原来的 App 上
    /// （macOS 27.3 实测，启动前改成普通 App 也一样）。所以启动前先当作普通 App（出现在程序坞和 ⌘Tab 里，
    /// 关窗口后 MainWindow 会改回去），启动完成时用旧的强制激活。作为登录项启动时不弹窗口，保持只在菜单栏
    func applicationWillFinishLaunching(_ notification: Notification) {
        if !Self.launchedAsLoginItem { NSApp.setActivationPolicy(.regular) }
    }

    private static var launchedAsLoginItem: Bool {
        guard let event = NSAppleEventManager.shared().currentAppleEvent,
              event.eventID == AEEventID(kAEOpenApplication) else { return false }
        return event.paramDescriptor(forKeyword: AEKeyword(keyAEPropData))?.enumCodeValue
            == OSType(keyAELaunchedAsLogInItem)
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        if NSApp.activationPolicy() == .regular { NSApp.activate(ignoringOtherApps: true) }  // 用户刚打开它，抢焦点是对的
        NSWorkspace.shared.notificationCenter.addObserver(forName: NSWorkspace.didWakeNotification, object: nil,
                                                          queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.lastWake = Date() }
        }
    }

    /// 主窗口是主场景，按 Apple 的文档这样的 App 关掉窗口就会退出；EarPair 要留在菜单栏里继续收声音
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }

    /// App 在运行时，从“应用程序”、启动台、聚焦搜索或程序坞再次打开：把主窗口叫出来。
    /// 不看 hasVisibleWindows：最小化的窗口算可见，旧系统上菜单栏图标也可能被算进去。
    /// macOS 26 起，电脑唤醒后几秒内系统会自己发“重新打开”（不是用户要开窗口），这段时间的忽略；
    /// 点通知另有处理（ConnectionNotifier）。来源记在日志里，方便以后确认系统还会不会这样发
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        let source = Self.reopenSource()
        guard Date().timeIntervalSince(lastWake) > 20 else {
            appLog.info("重新打开：来自 \(source, privacy: .public)，唤醒后 20 秒内，忽略")
            return false
        }
        appLog.info("重新打开：来自 \(source, privacy: .public)")
        return !MainWindowOpener.shared.show()
    }

    /// 发来“重新打开”的 App
    private static func reopenSource() -> String {
        guard let event = NSAppleEventManager.shared().currentAppleEvent,
              let pid = event.attributeDescriptor(forKeyword: AEKeyword(keySenderPIDAttr))?.int32Value, pid > 0
        else { return "未知" }
        return NSRunningApplication(processIdentifier: pid)?.bundleIdentifier ?? "pid \(pid)"
    }
}
