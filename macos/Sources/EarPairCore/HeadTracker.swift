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
        /// 左右朝向（度，左转为正，见 heading）和俯仰（度）
        public var yaw: Double
        public var pitch: Double
        /// 角速度大小（度/秒）
        public var speed: Double
        /// 绕竖直轴的角速度（度/秒，左转为正）；没有重力数据时为 nil
        public var verticalRate: Double?
        /// 头的加速度大小（g，已去掉重力）
        public var acceleration: Double?

        public init(time: Double, timestamp: Double, yaw: Double, pitch: Double, speed: Double, verticalRate: Double?,
                    acceleration: Double? = nil) {
            self.time = time
            self.timestamp = timestamp
            self.yaw = yaw
            self.pitch = pitch
            self.speed = speed
            self.verticalRate = verticalRate
            self.acceleration = acceleration
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
    /// 调试记录（开着时每个样本和连接事件都记下来）；在 start() 之前设好
    public var recorder: SpatialRecorder?

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
        let r = motion.rotationRate, g = motion.gravity, a = motion.userAcceleration
        let gravity = (g.x * g.x + g.y * g.y + g.z * g.z).squareRoot()
        let degrees = 180 / Double.pi
        // 陀螺仪的角速度投到竖直轴上（重力的反方向），右手定则下为正就是从上往下看逆时针，也就是向左转
        let vertical = gravity > 0.5 ? -(r.x * g.x + r.y * g.y + r.z * g.z) / gravity * degrees : nil
        recorder?.motion(motion, at: now)
        let q = motion.attitude.quaternion
        let sample = Sample(time: now, timestamp: motion.timestamp, yaw: Self.heading(x: q.x, y: q.y, z: q.z, w: q.w),
                            pitch: motion.attitude.pitch * degrees,
                            speed: (r.x * r.x + r.y * r.y + r.z * r.z).squareRoot() * degrees,
                            verticalRate: vertical,
                            acceleration: (a.x * a.x + a.y * a.y + a.z * a.z).squareRoot())
        lock.withLock {
            lastSampleAt = now
            connected = true
        }
        onSample?(sample)
    }

    /// 左右朝向（度，左转为正）：耳机横轴（设备 x 轴，低头、抬头时绕的就是它）在水平面上的方向。参考坐标系 z 轴竖直向上。
    /// 不用 CMAttitude 的 yaw：它是按 Z-X-Y 分解的欧拉角，等于设备 y 轴的水平方向；耳机戴得有点歪时 y 轴不水平，
    /// 低头、抬头就会让它变 8–20°（实测），两台的声音会一起偏到一边。横轴的水平方向绕横轴转时不变，平时转头和 yaw 一样
    public static func heading(x: Double, y: Double, z: Double, w: Double) -> Double {
        atan2(2 * (x * y + w * z), 1 - 2 * (y * y + z * z)) * 180 / .pi
    }

    // MARK: - CMHeadphoneMotionManagerDelegate

    public func headphoneMotionManagerDidConnect(_ manager: CMHeadphoneMotionManager) {
        lock.withLock { connected = true }
        recorder?.event("connect")
        headLog.info("耳机连上")
        onConnectionChange?(true)
    }

    public func headphoneMotionManagerDidDisconnect(_ manager: CMHeadphoneMotionManager) {
        lock.withLock { connected = false }
        recorder?.event("disconnect")
        headLog.info("耳机断开")
        onConnectionChange?(false)
    }
}
