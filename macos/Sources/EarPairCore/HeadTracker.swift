import CoreMotion
import Foundation
import os

private let headLog = Logger(subsystem: "app.earpair", category: "head")

/// 读支持头部追踪的耳机（AirPods Pro、AirPods Max 等）的朝向。样本在自己的串行队列上交出，约 50 次/秒，
/// App 不在前台时也不停。只给方向，不给位置；左右朝向没有绝对参考，会慢慢漂，耳机每次重新连上都会归零。
public final class HeadTracker: NSObject, CMHeadphoneMotionManagerDelegate, @unchecked Sendable {
    public struct Sample: Sendable {
        /// 收到的时间（MonotonicClock，秒）
        public var time: Double
        /// 传感器时间戳（秒）
        public var timestamp: Double
        /// 左右朝向（度，左转为正）和俯仰（度）
        public var yaw: Double
        public var pitch: Double
        /// 角速度大小（度/秒）
        public var speed: Double
        /// 绕竖直轴的角速度（度/秒，左转为正）；没有重力数据时为 nil
        public var verticalRate: Double?

        public init(time: Double, timestamp: Double, yaw: Double, pitch: Double, speed: Double, verticalRate: Double?) {
            self.time = time
            self.timestamp = timestamp
            self.yaw = yaw
            self.pitch = pitch
            self.speed = speed
            self.verticalRate = verticalRate
        }
    }

    public enum Authorization: Sendable {
        case notDetermined, denied, authorized
    }

    private let manager = CMHeadphoneMotionManager()
    private let queue: OperationQueue = {
        let queue = OperationQueue()
        queue.name = "app.earpair.head"
        queue.maxConcurrentOperationCount = 1
        queue.qualityOfService = .userInteractive
        return queue
    }()
    private let lock = UnfairLock()
    private var running = false
    private var connected = false
    private var lastSampleAt = -Double.infinity

    /// 在头部数据的队列上调用
    public var onSample: ((Sample) -> Void)?
    /// 耳机连上（true）或断开（false）；线程不定
    public var onConnectionChange: ((Bool) -> Void)?

    override public init() {
        super.init()
    }

    public static var authorization: Authorization {
        switch CMHeadphoneMotionManager.authorizationStatus() {
        case .notDetermined: return .notDetermined
        case .authorized: return .authorized
        case .denied, .restricted: return .denied
        @unknown default: return .denied
        }
    }

    /// 这台 Mac 能读耳机的头部数据（和有没有连着耳机无关）
    public var isAvailable: Bool { manager.isDeviceMotionAvailable }

    /// 第一次开始时系统会问用户要不要允许读运动数据
    public func start() {
        guard lock.withLock({ () -> Bool in
            defer { running = true }
            return !running
        }) else { return }
        manager.delegate = self
        manager.startConnectionStatusUpdates()
        manager.startDeviceMotionUpdates(to: queue) { [weak self] motion, error in
            if let error {
                headLog.error("头部数据出错：\(error.localizedDescription, privacy: .public)")
                return
            }
            if let motion { self?.handle(motion) }
        }
        headLog.info("开始读头部数据")
    }

    public func stop() {
        guard lock.withLock({ () -> Bool in
            defer { running = false }
            return running
        }) else { return }
        manager.stopDeviceMotionUpdates()
        manager.stopConnectionStatusUpdates()
        lock.withLock { connected = false }
        headLog.info("停止读头部数据")
    }

    /// 支持头部追踪的耳机连着
    public var isConnected: Bool { lock.withLock { connected } }

    /// 正在读（start 之后、stop 之前）
    public var isRunning: Bool { lock.withLock { running } }

    /// 最近 1 秒内收到过样本
    public var isReceiving: Bool {
        let last = lock.withLock { lastSampleAt }
        return MonotonicClock.now() - last < 1
    }

    private func handle(_ motion: CMDeviceMotion) {
        let now = MonotonicClock.now()
        let r = motion.rotationRate, g = motion.gravity
        let gravity = (g.x * g.x + g.y * g.y + g.z * g.z).squareRoot()
        let degrees = 180 / Double.pi
        // 陀螺仪的角速度投到竖直轴上（重力的反方向），右手定则下为正就是从上往下看逆时针，也就是向左转
        let vertical = gravity > 0.5 ? -(r.x * g.x + r.y * g.y + r.z * g.z) / gravity * degrees : nil
        let sample = Sample(time: now, timestamp: motion.timestamp, yaw: motion.attitude.yaw * degrees,
                            pitch: motion.attitude.pitch * degrees,
                            speed: (r.x * r.x + r.y * r.y + r.z * r.z).squareRoot() * degrees,
                            verticalRate: vertical)
        lock.withLock {
            lastSampleAt = now
            connected = true
        }
        onSample?(sample)
    }

    // MARK: - CMHeadphoneMotionManagerDelegate

    public func headphoneMotionManagerDidConnect(_ manager: CMHeadphoneMotionManager) {
        lock.withLock { connected = true }
        headLog.info("耳机连上")
        onConnectionChange?(true)
    }

    public func headphoneMotionManagerDidDisconnect(_ manager: CMHeadphoneMotionManager) {
        lock.withLock { connected = false }
        headLog.info("耳机断开")
        onConnectionChange?(false)
    }
}
