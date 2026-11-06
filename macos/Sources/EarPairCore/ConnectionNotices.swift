import Foundation

/// 连接状态变了要不要弹通知、弹哪一条（纯逻辑，方便测试；真正发通知的是界面层）。
///
/// - 开始播放：连上了；网络断开后又连上：重新连上了（只有“断了”的通知发出去过才发）。
/// - 发送端手动停止、音频设备没了：各发一条。
/// - 网络断开：先等一会儿（graceSeconds），这段时间里自己恢复了就什么都不发，免得 Wi‑Fi 抖一下就弹两条；
///   等不到才发“连接断了，正在重连”。之后还是没连上、回到等待状态时，再发一条“没能重新连上”。
public struct ConnectionNoticePolicy: Sendable {
    public enum Phase: Equatable, Sendable {
        /// 等待发送端
        case waiting
        /// 正在缓冲
        case connecting
        case playing
        /// 发送端手动停止
        case stopped
        /// 发送端的音频设备没了
        case deviceLost
        /// 网络断开（正在重连，或者不知道发送端的地址、没法重连）
        case lost
    }

    public enum Notice: Equatable, Sendable {
        case connected
        case reconnected
        case stopped
        case deviceLost
        case connectionLost
        case gaveUp
    }

    private enum Session: Equatable {
        case none
        case active
        case lost(since: Double, notified: Bool)
    }

    public static let graceSeconds = 3.0

    private var session = Session.none
    private var phase = Phase.waiting

    public init() {}

    /// 状态变化时调用，返回要发的通知
    public mutating func update(to phase: Phase, now: Double) -> [Notice] {
        self.phase = phase
        switch phase {
        case .playing:
            defer { session = .active }
            switch session {
            case .none: return [.connected]
            case .lost(_, let notified): return notified ? [.reconnected] : []
            case .active: return []
            }
        case .connecting:
            return [] // 缓冲中：结果要等播放或者断开才知道
        case .stopped, .deviceLost:
            defer { session = .none }
            guard session != .none else { return [] }
            return [phase == .stopped ? .stopped : .deviceLost]
        case .lost:
            if session == .active { session = .lost(since: now, notified: false) }
            return []
        case .waiting:
            defer { session = .none }
            if case .lost(_, true) = session { return [.gaveUp] }
            return []
        }
    }

    /// 定时调用（比如每 0.1 秒）：网络断开超过 graceSeconds 还没恢复（也没在重新缓冲），发“连接断了”
    public mutating func tick(now: Double) -> [Notice] {
        guard phase == .lost, case .lost(let since, false) = session, now - since >= Self.graceSeconds else { return [] }
        session = .lost(since: since, notified: true)
        return [.connectionLost]
    }
}
