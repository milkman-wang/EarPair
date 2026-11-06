import EarPairCore
import Foundation
import os
import UserNotifications

private let noticeLog = Logger(subsystem: "app.earpair", category: "notice")

/// 把连接变化发成系统通知。同一时间只留一条（后一条替换前一条），通知中心里不会堆一串连上、断开。
/// 只能在打包好的 App 里用（UNUserNotificationCenter 需要 bundle id），预览和命令行不创建它。
@MainActor
final class ConnectionNotifier: NSObject, UNUserNotificationCenterDelegate {
    private let center = UNUserNotificationCenter.current()

    override init() {
        super.init()
        center.delegate = self
        center.requestAuthorization(options: [.alert]) { _, _ in }
    }

    func post(_ notice: ConnectionNoticePolicy.Notice, sender: String, output: String?) {
        let content = UNMutableNotificationContent()
        switch notice {
        case .connected:
            content.title = String(localized: "Connected to \(sender)", bundle: .module)
            if let output { content.body = String(localized: "Playing on \(output)", bundle: .module) }
        case .reconnected:
            content.title = String(localized: "Reconnected to \(sender)", bundle: .module)
        case .stopped:
            content.title = String(localized: "\(sender) stopped sending", bundle: .module)
        case .deviceLost:
            content.title = String(localized: "The sound device on \(sender) was disconnected", bundle: .module)
            content.body = String(localized: "Playback will resume when the device is back.", bundle: .module)
        case .connectionLost:
            content.title = String(localized: "Lost connection to \(sender)", bundle: .module)
            content.body = String(localized: "The network is unstable. Trying to reconnect…", bundle: .module)
        case .gaveUp:
            content.title = String(localized: "Couldn’t reconnect to \(sender)", bundle: .module)
            content.body = String(localized: "EarPair will connect again when the PC starts sending.", bundle: .module)
        }
        content.threadIdentifier = "connection"
        noticeLog.info("通知：\(content.title, privacy: .public) \(content.body, privacy: .public)")
        center.add(UNNotificationRequest(identifier: "connection", content: content, trigger: nil))
    }

    /// 窗口在前台时也显示横幅
    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter,
                                            willPresent notification: UNNotification) async
        -> UNNotificationPresentationOptions {
        [.banner, .list]
    }

    /// 点通知：打开主窗口。系统随后也会发一次“重新打开”，但唤醒后那段时间的会被忽略，所以这里自己开
    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter,
                                            didReceive response: UNNotificationResponse) async {
        await MainActor.run { _ = MainWindowOpener.shared.show() }
    }
}
