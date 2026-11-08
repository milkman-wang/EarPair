import Foundation

// 空间音频：发送端（Windows 电脑）的声音放在它的屏幕所在的方向，Mac 自己的声音放在 Mac 的方向，都跟着头转。
// 头正对 Mac 时，发送端的声音移到一边、小一些（保留一部分）；正对发送端时反过来。
// 两台的方向靠 ScreenAnchors 从头部数据里一直跟着（漂移、读数重置、耳机重新连上都会自己找回来）。

// MARK: - 校准

/// 校准两台电脑的方向：先脸正对 Mac 屏幕，再脸正对发送端的屏幕。头稳住 1.5 秒就自动记下，
/// 记发送端之前头至少要从 Mac 那边转开 12°。某一步 30 秒还没记到就算失败。
public struct SpatialCalibration: Sendable {
    public enum Step: Sendable, Equatable {
        /// 等脸正对 Mac
        case mac
        /// 等脸正对发送端
        case sender
        /// 都记下了：两台在连续朝向里的方向（度，左转为正）
        case done(mac: Double, sender: Double)
        /// 某一步太久没记到
        case failed
    }

    public static let steadySeconds = 1.5
    /// 这段时间里角速度都低于它（度/秒）才算稳住
    public static let steadySpeed = 6.0
    public static let minimumTurn = 12.0
    public static let stepTimeout = 30.0

    public private(set) var step = Step.mac
    /// 这一步头已经稳住了多久（0…1），给界面画进度
    public private(set) var progress = 0.0
    private var stepStarted: Double?
    private var window: [(time: Double, heading: Double)] = []
    private var macHeading: Double?

    public init() {}

    /// 喂一个样本：heading 是连续朝向（度，左转为正，扣掉了读数的重置），speed 是角速度（度/秒）
    public mutating func feed(time: Double, heading: Double, speed: Double) {
        guard step == .mac || step == .sender else { return }
        let started = stepStarted ?? time
        stepStarted = started
        if time - started > Self.stepTimeout {
            step = .failed
            progress = 0
            window = []
            return
        }
        let turnedEnough = macHeading.map { abs(heading - $0) >= Self.minimumTurn } ?? true
        if speed >= Self.steadySpeed || !turnedEnough {
            window = []
        } else {
            window.append((time, heading))
        }
        while let first = window.first, time - first.time > Self.steadySeconds { window.removeFirst() }
        let held = window.first.map { time - $0.time } ?? 0
        progress = min(1, held / (Self.steadySeconds - 0.05))
        guard progress >= 1 else { return }
        let captured = window.map(\.heading).reduce(0, +) / Double(window.count)
        window = []
        progress = 0
        stepStarted = nil
        if let mac = macHeading {
            step = .done(mac: mac, sender: captured)
        } else {
            macHeading = captured
            step = .sender
        }
    }

    /// 耳机重新连上（读数归零）：已经记下的不能再用，从头来
    public mutating func restart() {
        self = SpatialCalibration()
    }
}

// MARK: - 混音

public enum SpatialMix {
    /// 发送端的两只虚拟音箱各偏中心多少度（像屏幕两边的一对小音箱）
    public static let halfWidth = 15.0
    /// 头和发送端的屏幕相差多少度以内算看着它（原样），多少度以外算看着别处（降到 awayGain）
    public static let facingAngle = 20.0
    public static let awayAngle = 50.0

    /// 一台电脑声音的增益：看着它时 1，转开到 awayAngle 以外是 awayGain，中间按余弦平滑过渡。
    /// relative：它相对头的方向（度，左为正）
    public static func gain(relative: Double, awayGain: Double) -> Double {
        let angle = abs(relative)
        if angle <= facingAngle { return 1 }
        if angle >= awayAngle { return awayGain }
        let t = (angle - facingAngle) / (awayAngle - facingAngle)
        return 1 + (awayGain - 1) * (1 - cos(t * .pi)) / 2
    }
}

// MARK: - 开关

/// 空间音频现在用不用、为什么不用
public enum SpatialMode: Equatable, Sendable {
    /// 用户关了
    case off
    /// 还没校准过两台的位置
    case needsSetup
    /// 没有读头部动作的权限
    case noPermission
    /// 没有支持头部追踪的耳机，或者声音不是从它出来的
    case noHeadphones
    /// 发送端没在发（手动停了、断开超过几秒、还没连上）：它回来后自动接着用。用户的开关不变
    case waitingForSender
    case active

    /// senderPresent：发送端在发（网络断开的头几秒也算，免得 Wi‑Fi 抖一下就来回切）
    public static func decide(enabled: Bool, calibrated: Bool, authorization: HeadTracker.Authorization,
                              headphones: Bool, senderPresent: Bool) -> SpatialMode {
        guard enabled else { return .off }
        guard calibrated else { return .needsSetup }
        guard authorization != .denied else { return .noPermission }
        guard headphones else { return .noHeadphones }
        guard senderPresent else { return .waitingForSender }
        return .active
    }
}

// MARK: - 跟踪

/// ScreenAnchors 和校准加一把锁：头部数据的队列喂样本、摆声源，主线程读状态、校准、对准。
public final class SpatialTracker: @unchecked Sendable {
    public struct Status: Sendable, Equatable {
        /// 校准过（这次或者以前存下来的）
        public var calibrated: Bool
        public var phase: ScreenAnchors.Phase
        public var facing: ScreenAnchors.Screen?
        /// 两台相对头的方向（度，左为正）；还不知道时为 nil
        public var macRelative: Double?
        public var senderRelative: Double?
        /// 发送端在 Mac 左边多少度（右边为负）：校准时测的
        public var angle: Double
        /// 正在校准时的步骤和这一步的进度
        public var calibration: SpatialCalibration.Step?
        public var calibrationProgress: Double
        /// 常用位置离校准方向多少度（左为正），和刚动过身体、正在加快调整
        public var naturalMac: Double
        public var naturalSender: Double
        public var adjustingPosture: Bool
    }

    /// 存下来、下次打开接着用的：夹角、常用哪台、注视地图
    public struct Saved: Sendable, Equatable {
        public var angle: Double
        public var main: ScreenAnchors.Screen
        public var map: [Double]

        public init(angle: Double, main: ScreenAnchors.Screen, map: [Double]) {
            self.angle = angle
            self.main = main
            self.map = map
        }
    }

    private let lock = UnfairLock()
    private var anchors: ScreenAnchors
    private var calibrated: Bool
    private var calibration: SpatialCalibration?
    private var active = false
    private var awayGain = 0.5
    private var lastPlaced = -Double.infinity
    private var lastYaw = 0.0
    /// 最近一次校准的两个方向，换算成当时读数里的 yaw（度），调试记录用
    public private(set) var lastCalibrationYaws: (mac: Double, sender: Double)?

    /// 头部数据的队列上调用：发送端和 Mac 两组虚拟音箱摆在哪。只在 active 时调用，最多 60 次/秒
    public var onPlace: ((_ sender: SpatialPlacement, _ mac: SpatialPlacement) -> Void)?

    /// saved 为 nil：还没校准过。preferred：还没学出常用哪台时先当作哪台
    public init(saved: Saved?, preferred: ScreenAnchors.Screen = .windows) {
        if let saved {
            anchors = ScreenAnchors(angle: saved.angle, preferred: saved.main, map: saved.map)
            calibrated = true
        } else {
            anchors = ScreenAnchors(angle: 50, preferred: preferred)
            calibrated = false
        }
    }

    /// 头部数据的队列调用
    public func add(_ sample: HeadTracker.Sample) {
        var placement: (sender: SpatialPlacement, mac: SpatialPlacement)?
        lock.withLock {
            lastYaw = sample.yaw
            let reconnects = anchors.reconnects
            anchors.add(ScreenAnchors.Sample(time: sample.time, timestamp: sample.timestamp, yaw: sample.yaw,
                                             speed: sample.speed, verticalRate: sample.verticalRate,
                                             acceleration: sample.acceleration, pitch: sample.pitch))
            if var c = calibration {
                if anchors.reconnects != reconnects { c.restart() }
                c.feed(time: sample.time, heading: anchors.heading, speed: sample.speed)
                calibration = c
            }
            if active, calibrated, sample.time - lastPlaced >= 1.0 / 60,
               let sender = anchors.relative(.windows), let mac = anchors.relative(.mac) {
                lastPlaced = sample.time
                placement = (SpatialPlacement(centerRight: -sender, gain: SpatialMix.gain(relative: sender, awayGain: awayGain)),
                             SpatialPlacement(centerRight: -mac, gain: SpatialMix.gain(relative: mac, awayGain: awayGain)))
            }
        }
        if let placement { onPlace?(placement.sender, placement.mac) }
    }

    /// 耳机断开或连上：读数可能要归零
    public func connectionChanged() {
        lock.withLock { anchors.connectionChanged() }
    }

    /// 头部数据要重新开始了（在 HeadTracker.start() 之前调用）：新数据的读数从头算
    public func motionRestarted() {
        lock.withLock {
            anchors.motionRestarted()
            calibration?.restart()
        }
    }

    /// 空间音频在用：开始按头的方向摆声源
    public func setActive(_ on: Bool) {
        lock.withLock {
            active = on
            lastPlaced = -.infinity
        }
    }

    /// 看别处时那台的声音保留多少（0…1）
    public func setAwayGain(_ gain: Double) {
        lock.withLock { awayGain = min(max(gain, 0), 1) }
    }

    public func beginCalibration() {
        lock.withLock { calibration = SpatialCalibration() }
    }

    public func cancelCalibration() {
        lock.withLock { calibration = nil }
    }

    /// 校准两步都记下了：用它，返回要存的东西；还没记完时返回 nil
    @discardableResult
    public func commitCalibration() -> Saved? {
        lock.withLock {
            guard case .done(let mac, let sender)? = calibration?.step else { return nil }
            lastCalibrationYaws = (lastYaw + mac - anchors.heading, lastYaw + sender - anchors.heading)
            anchors.calibrate(macHeading: mac, windowsHeading: sender)
            calibrated = true
            calibration = nil
            return savedLocked()
        }
    }

    /// 用户看着 Mac 时调用：把 Mac 的方向定在现在的朝向（夹角不变）
    public func recenter() {
        lock.withLock { anchors.align(.mac) }
    }

    public func status() -> Status {
        lock.withLock {
            Status(calibrated: calibrated, phase: anchors.phase, facing: anchors.facing,
                   macRelative: anchors.relative(.mac), senderRelative: anchors.relative(.windows),
                   angle: anchors.calibratedAngle, calibration: calibration?.step,
                   calibrationProgress: calibration?.progress ?? 0, naturalMac: anchors.naturalOffset(.mac),
                   naturalSender: anchors.naturalOffset(.windows), adjustingPosture: anchors.adjustingPosture)
        }
    }

    /// 要存下来的（还没校准过时为 nil）
    public func saved() -> Saved? {
        lock.withLock { savedLocked() }
    }

    private func savedLocked() -> Saved? {
        guard calibrated else { return nil }
        return Saved(angle: anchors.calibratedAngle, main: anchors.mainScreen, map: anchors.map)
    }
}
