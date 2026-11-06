import AppKit
import SwiftUI

/// 从 AppKit 那边打开主窗口：在“应用程序”里再次打开 App、点通知。
/// SwiftUI 的 openWindow 只能从场景或视图里拿到，由 App 的菜单栏场景交过来。
@MainActor
public final class MainWindowOpener {
    public static let shared = MainWindowOpener()
    private var openWindow: OpenWindowAction?

    public func register(_ action: OpenWindowAction) { openWindow = action }

    /// 开着就提到最前（最小化了先恢复），关着就让 SwiftUI 重新打开。还没拿到 openWindow 时返回 false
    @discardableResult
    public func show() -> Bool {
        if NSApp.isHidden { NSApp.unhide(nil) }
        if let window = NSApp.windows.first(where: { $0.identifier?.rawValue == MainWindow.id }),
           window.isVisible || window.isMiniaturized {
            if window.isMiniaturized { window.deminiaturize(nil) }
            NSApp.activate()
            window.makeKeyAndOrderFront(nil)
            return true
        }
        guard let openWindow else { return false }
        NSApp.activate()
        openWindow(id: MainWindow.id)
        return true
    }
}
