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
            content.title = "\(sender) 已连接"
            if let output { content.body = "从 \(output) 播放" }
        case .reconnected:
            content.title = "已重新连上 \(sender)"
        case .stopped:
            content.title = "\(sender) 停止发送了"
        case .deviceLost:
            content.title = "\(sender) 的声音设备断开了"
            content.body = "设备恢复后会自动继续"
        case .connectionLost:
            content.title = "和 \(sender) 的连接断了"
            content.body = "网络不稳定，正在尝试重新连接…"
        case .gaveUp:
            content.title = "没能重新连上 \(sender)"
            content.body = "它再次发送时会自动连上"
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
