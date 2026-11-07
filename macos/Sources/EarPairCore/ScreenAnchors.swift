import Foundation

/// 两块屏幕在 AirPods 读数里的方向：从平时看屏幕的样子里自己学，跟着漂移、重置、重新连接和坐姿走。
///
/// 喂头部样本和 AirPods 的连接事件，读出 Mac 和 Windows（发送端）各在哪个方向、头现在朝着哪台。纯逻辑，方便测试。
/// 算法在 HeadProbe（实测 AirPods 头部数据的探针）里用真实记录和模拟数据验证过。
/// 角度都是度，左转为正（和 CMAttitude 的 yaw 一样）。
///
/// 核心是一张注视地图：以 Mac 的方向为 0°，记下平时都看哪些方向、各看了多久（Windows 在校准的夹角那里）。
/// 宽屏、一块屏上开着两台电脑的窗口、屏幕旁边常看的东西，都会成为地图上的一片，不用假设每台屏幕只是一个点。
/// 地图按分界分成两半：Mac 那半（连同别处）和 Windows 那半。夹角可以比校准时变一点（delta，靠在椅子上时侧面那台会挪），
/// 这时 Windows 那半整体挪 delta 度再和注视对。
/// - 连续朝向：跟着读数走，但扣掉读数的重置（头没在转、读数却突然变了），所以重置不影响跟踪。
/// - 对位：把最近的注视和地图对上，求出 Mac 现在在哪、夹角变了多少。跟踪时每 10 秒在附近找一次：
///   两台一起挪最快每分钟 maxDrift 度（漂移比这慢，跟得上）；侧面那台（不常看的那台）单独挪最快每分钟 maxFlex 度，
///   要最近看过它几秒才挪。看了一处新地方也拽不走整个方向，它会被记进地图。
///   每 30 秒在一圈里找一次：另一个位置能让最近的注视六成以上落在地图上看过的地方、比现在多 20% 以上，
///   最近的注视铺开了 20° 以上（只看一处时，放在哪儿都说得通），而且连续两次，才跳过去，比如漏掉的重置。
///   校准或点“对准”之后，直到下次重新连上都不跳：用户亲手定的位置只跟漂移慢慢挪，不会被自动推翻。
/// - 重新连上：读数归零，断开期间头怎么动的也不知道，每来一次注视都在一圈里重新对位（夹角在 ±flexRange 里一起找，
///   离断开前的夹角越远扣分越多）。最好的位置明显比第二好的强、而且注视铺开了 20° 以上，才开始跟踪（或者已经看了 90 秒）。
///   只看过一处时，它会被放到地图上最常看的地方：宽屏上常看的地方不止一处，这时可能放错，看过第二处就会改过来。
/// - 学习：跟踪稳定后把注视记进地图（Windows 那半扣掉夹角的变化），地图按几小时慢慢衰减，可以存下来下次接着用；校准时从头学。
///   校准（或者点“对准”）之后的 trustWindow 秒里方向不动、只学地图：那时方向是准的，先把你常看的几处按真实位置学下来；
///   不然一边对位一边学，方向会被“还没学过的常看位置”慢慢拽偏，地图又按偏了的位置学进去，越来越偏。
///   注视等离开对位用的窗口（recentMemory）之后才记进地图，记的是当时的相对位置：对位用的地图里不含正在对位的注视，
///   不然它们总能对上刚学进去的自己，整体漂移就看不出来了。
public struct ScreenAnchors: Sendable {
    public enum Screen: Sendable, Equatable {
        case mac, windows
    }

    public enum Phase: Sendable, Equatable {
        /// 刚开始或刚重新连上，还没有注视
        case waiting
        /// 有了初步的方向，还在确认
        case acquiring
        case tracking
    }

    public struct Sample: Sendable {
        /// 收到的时间（秒，单调递增）
        public var time: Double
        /// 传感器时间戳（秒）
        public var timestamp: Double
        /// 左右朝向的读数（度，左转为正）
        public var yaw: Double
        /// 角速度大小（度/秒）
        public var speed: Double
        /// 绕竖直轴的角速度（度/秒，左转为正）；没有重力数据时为 nil
        public var verticalRate: Double?

        public init(time: Double, timestamp: Double, yaw: Double, speed: Double, verticalRate: Double?) {
            self.time = time
            self.timestamp = timestamp
            self.yaw = yaw
            self.speed = speed
            self.verticalRate = verticalRate
        }
    }

    /// 一次注视（长注视每秒交一次）
    public struct Fixation: Sendable {
        public var time: Double
        /// 连续朝向
        public var heading: Double
        public var seconds: Double
        /// 算在看哪台；nil 是两台都不靠近
        public var screen: Screen?
    }

    public struct Configuration: Sendable {
        /// 角速度低于它（度/秒）算在注视
        public var fixationSpeed = 5.0
        /// 注视至少多长（秒）才算；长注视每隔这么久交一次
        public var fixationChunk = 1.0
        /// 前后两个样本的角速度都低于它（度/秒），读数却突然变了超过 resetThreshold（度），算读数被重置
        public var resetSpeed = 10.0
        public var resetThreshold = 3.0
        /// 断了这么久（秒）、中间又有连接事件，算重新连上；没有连接事件时断这么久（silentReconnectGap）也算
        public var reconnectGap = 1.5
        public var silentReconnectGap = 10.0
        /// 重新找方向时，从重新连上起至少累计这么多秒注视、而且对位明显（或者累计到 acquireLimit 秒）才开始跟踪
        public var acquireSeconds = 20.0
        public var acquireLimit = 90.0
        /// 对位用最近多久（秒）的注视
        public var recentMemory = 180.0
        /// 跟踪时两台一起最快每分钟挪多少度（漂移一般每分钟 0.4–1.2°）
        public var maxDrift = 2.0
        /// 跟踪时在附近多少度里找
        public var localRange = 12.0
        /// 夹角最多比校准时变多少度；跟踪时侧面那台单独最快每分钟挪多少度、最近至少看过它多少秒才挪
        public var flexRange = 20.0
        public var maxFlex = 6.0
        public var flexEvidence = 6.0
        /// 地图按这个时间常数（秒）衰减
        public var mapMemory = 3.0 * 3600
        /// 重新连上、跳过去之后，跟踪稳定这么久（秒）才往地图里记
        public var learnAfter = 60.0
        /// 校准、对准之后这么久（秒）方向不动，只学地图
        public var trustWindow = 300.0
        /// 头部数据停了又开，停的时间在这以内（秒）就当头没动、把前后接上；更久就重新找
        public var bridgeLimit = 120.0

        public init() {}
    }

    public var configuration: Configuration
    public private(set) var phase = Phase.waiting
    /// 校准时两台的夹角（Windows 减 Mac，左转为正）
    public private(set) var calibratedAngle: Double
    /// 夹角现在比校准时变了多少（度）
    public private(set) var delta = 0.0
    /// 现在的夹角
    public var angle: Double { calibratedAngle + delta }
    /// 现在的连续朝向
    public private(set) var heading = 0.0
    /// 识别出的读数重置、重新连接、跳到别的位置的次数
    public private(set) var resets = 0
    public private(set) var reconnects = 0
    public private(set) var relocations = 0
    /// 注视地图：360 格，第 i 格是“Mac 方向 + (i − 180)°”附近一共被看了多少秒（含开头的先验；Windows 那半按校准时的夹角记）
    public private(set) var map: [Double]

    /// Mac 的方向（连续朝向坐标）；Windows 是 mac + angle
    private var mac: Double?
    private var last: Sample?
    private var frameMayReset = false
    /// 头部数据刚重新开始：下一个样本的读数是从头算的
    private var pendingBridge = false
    private var fixationStart: Double?
    private var chunkStart = 0.0
    private var chunkHeadings: [Double] = []
    private var recent: [Fixation] = []
    private let preferred: Screen
    /// 学进地图的秒数（不算先验）
    private var learned = 0.0
    /// 从什么时候起跟踪稳定（往地图里记要等它满 learnAfter）
    private var stableSince: Double?
    private var lastLocal = -Double.infinity
    private var lastGlobal = -Double.infinity
    private var pendingJump: Double?
    /// 断开前的夹角变化：重新找方向时往它靠
    private var deltaPrior = 0.0
    /// 这次重新找方向以来累计的注视秒数
    private var acquiredSeconds = 0.0
    /// 这一段是用户亲手定的（校准或“对准”过）：重新连上之前不跳
    private var manual = false
    /// 等着记进地图的注视：时间、地图坐标（相对 Mac 的度数，Windows 那半扣掉了夹角的变化）、秒数
    private var pendingLearn: [(time: Double, relative: Double, seconds: Double)] = []
    /// 到这个时间之前方向不动、只学地图（校准、对准之后）
    private var frozenUntil = -Double.infinity
    /// 地图的两半（平滑过）、没看过的地方的“底”、归一化的对数，和两半的分界（地图坐标）；地图变了再算
    private var macPart: [Double] = []
    private var windowsPart: [Double] = []
    private var floorValue = 0.0
    private var logNorm = 0.0
    private var boundary = 0.0
    private var densityDirty = true

    static let seedMass = 40.0

    /// angle：两台的夹角（Windows 减 Mac，左转为正）；preferred：常用哪台（开头的先验更偏向它）；
    /// map：上次存下来的地图（夹角没变时接着用）
    public init(angle: Double, preferred: Screen = .mac, map: [Double]? = nil,
                configuration: Configuration = Configuration()) {
        calibratedAngle = angle
        self.preferred = preferred
        self.configuration = configuration
        if let map, map.count == 360, map.allSatisfy({ $0.isFinite && $0 >= 0 }), map.reduce(0, +) > 0 {
            self.map = map
            learned = max(0, map.reduce(0, +) - Self.seedMass)
        } else {
            self.map = Self.seeds(angle: angle, main: preferred)
        }
        refreshDensity()
    }

    // MARK: - 读

    /// 某台在当前读数里的方向（度，-180…180）；还不知道时为 nil
    public func direction(of screen: Screen) -> Double? {
        guard let anchor = anchor(screen), let last else { return nil }
        return Self.wrap(anchor - heading + last.yaw)
    }

    /// 某台相对头现在朝向的方向（度，左为正）
    public func relative(_ screen: Screen) -> Double? {
        anchor(screen).map { Self.wrap($0 - heading) }
    }

    /// 头现在朝着哪台；两台都不靠近时为 nil
    public var facing: Screen? {
        guard let mac else { return nil }
        return classify(Self.wrap(heading - mac))
    }

    /// 常用的那台：地图上两半哪边看得多；还没学够 15 秒时用 preferred
    public var mainScreen: Screen {
        guard knowsMainScreen else { return preferred }
        var onMac = 0.0, onWindows = 0.0
        for (i, seconds) in map.enumerated() {
            switch mapScreen(Double(i - 180)) {
            case .mac?: onMac += seconds
            case .windows?: onWindows += seconds
            case nil: break
            }
        }
        return onWindows > onMac ? .windows : .mac
    }

    /// 常用的那台是学出来的（不是 preferred 猜的），可以存下来下次用
    public var knowsMainScreen: Bool {
        learned >= 15
    }

    /// 0…1：确认阶段最多 0.5；跟踪时稳定一分钟到 1
    public var confidence: Double {
        guard let now = last?.time else { return 0 }
        switch phase {
        case .waiting:
            return 0
        case .acquiring:
            return 0.5 * min(1, acquiredSeconds / configuration.acquireSeconds)
        case .tracking:
            return 0.5 + 0.5 * min(1, max(0, now - (stableSince ?? now)) / 60)
        }
    }

    // MARK: - 喂

    /// 校准：两台在当前读数里的方向（度，左转为正）。地图从头学
    public mutating func calibrate(macYaw: Double, windowsYaw: Double) {
        let current = last?.yaw ?? macYaw
        calibrate(macHeading: heading + Self.wrap(macYaw - current),
                  windowsHeading: heading + Self.wrap(windowsYaw - current))
    }

    /// 校准：两台在连续朝向（heading）里的方向。校准过程中读数被重置过也没关系
    public mutating func calibrate(macHeading: Double, windowsHeading: Double) {
        mac = macHeading
        calibratedAngle = Self.wrap(windowsHeading - macHeading)
        delta = 0
        deltaPrior = 0
        map = Self.seeds(angle: calibratedAngle, main: knowsMainScreen ? mainScreen : preferred)
        learned = 0
        pendingLearn = []
        densityDirty = true
        refreshDensity()
        startTracking(learnNow: true)
        frozenUntil = (last?.time ?? 0) + configuration.trustWindow
        manual = true
    }

    /// 看着某台时调用：把它的方向定在现在的朝向（菜单里的“对准”）。马上开始往地图里记。
    /// 和原来的估计差 10° 以上时，说明之前跟错了，错的时候学进地图的也不可信：地图从头学
    public mutating func align(_ screen: Screen) {
        guard last != nil else { return }
        let aligned = screen == .mac ? heading : heading - angle
        if let old = mac, abs(Self.wrap(aligned - old)) > 10 {
            map = Self.seeds(angle: calibratedAngle, main: knowsMainScreen ? mainScreen : preferred)
            learned = 0
            pendingLearn = []
            densityDirty = true
            refreshDensity()
        }
        mac = aligned
        startTracking(learnNow: true)
        frozenUntil = (last?.time ?? 0) + configuration.trustWindow
        manual = true
    }

    /// AirPods 断开或连上：读数可能要归零
    public mutating func connectionChanged() {
        frameMayReset = true
    }

    /// 头部数据停了又重新开始（在第一个新样本之前调用）：读数会从头算，不能当成头转了。
    /// 停得不久就当头没动、把前后接上，但不再当作用户亲手定的位置：真转过头的话，看到明显更好的位置可以跳过去；
    /// 停太久就重新找
    public mutating func motionRestarted() {
        pendingBridge = true
    }

    /// 喂一个头部样本；交出一次注视时返回它
    @discardableResult
    public mutating func add(_ sample: Sample) -> Fixation? {
        defer { last = sample }
        guard let last else {
            heading = sample.yaw
            return nil
        }
        let gap = sample.time - last.time
        if pendingBridge {
            pendingBridge = false
            frameMayReset = false
            guard gap <= configuration.bridgeLimit, mac != nil else {
                restart(at: sample)
                return nil
            }
            resets += 1  // 朝向不变，只换读数的零点
            manual = false
            frozenUntil = -Double.infinity
            fixationStart = nil
            chunkHeadings = []
            lastGlobal = sample.time - 25  // 几秒后就在一圈里查一次
            return nil
        }
        if gap > configuration.reconnectGap && (frameMayReset || gap > configuration.silentReconnectGap) {
            restart(at: sample)
            return nil
        }
        frameMayReset = false
        let step = Self.wrap(sample.yaw - last.yaw)
        let dt = sample.timestamp - last.timestamp
        let calm = last.speed < configuration.resetSpeed && sample.speed < configuration.resetSpeed
        if dt > 0, dt < 0.2, let rate = sample.verticalRate {
            let turned = rate * dt
            if calm && abs(Self.wrap(step - turned)) > max(configuration.resetThreshold, 0.5 * abs(turned)) {
                heading += turned  // 读数被重置了：只按陀螺仪转过的角度走
                resets += 1
            } else {
                heading += step
            }
        } else if gap <= configuration.reconnectGap && last.speed < 3 && sample.speed < 3 && abs(step) > 5 {
            resets += 1  // 短暂中断、前后头都没动，读数却变了：重置
        } else {
            heading += step
        }
        return fixate(sample, previous: last)
    }

    // MARK: - 注视

    private func anchor(_ screen: Screen) -> Double? {
        mac.map { screen == .mac ? $0 : $0 + angle }
    }

    private var recentSeconds: Double {
        recent.reduce(0) { $0 + $1.seconds }
    }

    private mutating func restart(at sample: Sample) {
        reconnects += 1
        frameMayReset = false
        heading = sample.yaw
        mac = nil
        deltaPrior = delta
        acquiredSeconds = 0
        manual = false
        phase = .waiting
        recent = []
        fixationStart = nil
        chunkHeadings = []
        stableSince = nil
        pendingJump = nil
        frozenUntil = -Double.infinity
    }

    private mutating func startTracking(learnNow: Bool) {
        phase = .tracking
        let now = last?.time ?? 0
        stableSince = learnNow ? now - configuration.learnAfter : now
        lastLocal = now
        lastGlobal = now
        pendingJump = nil
    }

    private mutating func fixate(_ sample: Sample, previous: Sample) -> Fixation? {
        guard sample.speed < configuration.fixationSpeed else {
            // 注视结束：整段够长、尾巴也不太短，就把尾巴交上去
            defer {
                fixationStart = nil
                chunkHeadings = []
            }
            guard let start = fixationStart, previous.time - start >= configuration.fixationChunk,
                  previous.time - chunkStart >= 0.3, !chunkHeadings.isEmpty else { return nil }
            return observe(Self.median(chunkHeadings), seconds: previous.time - chunkStart, at: previous.time)
        }
        if fixationStart == nil {
            fixationStart = sample.time
            chunkStart = sample.time
            chunkHeadings = []
        }
        chunkHeadings.append(heading)
        guard sample.time - chunkStart >= configuration.fixationChunk else { return nil }
        let fixation = observe(Self.median(chunkHeadings), seconds: sample.time - chunkStart, at: sample.time)
        chunkStart = sample.time
        chunkHeadings = []
        return fixation
    }

    private mutating func observe(_ heading: Double, seconds: Double, at time: Double) -> Fixation {
        refreshDensity()
        recent.append(Fixation(time: time, heading: heading, seconds: seconds, screen: nil))
        recent.removeAll { time - $0.time > configuration.recentMemory }
        switch phase {
        case .waiting, .acquiring:
            // 在一圈里找最能对上地图的位置；只看过一处时，它会落在地图上最常看的地方
            phase = .acquiring
            let best = alignAround(heading, prior: deltaPrior)
            mac = best.x
            delta = best.d
            acquiredSeconds += seconds
            if acquiredSeconds >= configuration.acquireSeconds
                && ((best.margin >= 6 && spread >= 20) || acquiredSeconds >= configuration.acquireLimit) {
                startTracking(learnNow: false)
            }
        case .tracking:
            follow(heading, seconds: seconds, at: time)
        }
        return Fixation(time: time, heading: heading, seconds: seconds,
                        screen: mac.flatMap { classify(Self.wrap(heading - $0)) })
    }

    /// 跟踪：附近对位跟漂移和夹角（都限速），一圈对位查有没有跳（连续两次才跳），稳定时学进地图
    private mutating func follow(_ heading: Double, seconds: Double, at time: Double) {
        guard var m = mac else { return }
        if time < frozenUntil {
            // 刚校准或对准过：方向是准的，先不动，只学地图
            lastLocal = time
            lastGlobal = time
            remember(Self.wrap(heading - m), seconds: seconds, at: time)
            return
        }
        if time - lastLocal >= 10 {
            let elapsed = min(time - lastLocal, 60)
            lastLocal = time
            // 两台一起挪（漂移）
            let limit = configuration.maxDrift / 60 * elapsed
            let best = align(around: m, delta: delta, range: configuration.localRange, step: 0.5).x
            m += max(-limit, min(limit, Self.wrap(best - m)))
            mac = m
            flexSide(elapsed: elapsed)
            m = mac ?? m
        }
        if !manual && time - lastGlobal >= 30 {
            lastGlobal = time
            let best = alignAround(heading, prior: delta)
            let gain = best.score - likelihood(m, delta)
            let better = known(best.x, best.d)
            if abs(Self.wrap(best.x - m)) > 10 && gain >= max(10, recentSeconds) && spread >= 20
                && better >= 0.6 && better - known(m, delta) >= 0.2 {
                if let pending = pendingJump, abs(Self.wrap(pending - best.x)) <= 6 {
                    m = best.x
                    mac = m
                    delta = best.d
                    relocations += 1
                    stableSince = time
                    pendingLearn = []
                    pendingJump = nil
                } else {
                    pendingJump = best.x
                }
            } else {
                pendingJump = nil
            }
        }
        if let since = stableSince, time - since >= configuration.learnAfter {
            remember(Self.wrap(heading - m), seconds: seconds, at: time)
        }
    }

    /// 侧面那台（不常看的那台）单独挪，常用的那台不动：最近看过它 flexEvidence 秒以上才挪，最快每分钟 maxFlex 度
    private mutating func flexSide(elapsed: Double) {
        guard let m = mac else { return }
        let side: Screen = mainScreen == .windows ? .mac : .windows
        var onSide = 0.0
        for f in recent where classify(Self.wrap(f.heading - m)) == side { onSide += f.seconds }
        guard onSide >= configuration.flexEvidence else { return }
        let limit = configuration.maxFlex / 60 * elapsed
        let base = likelihood(m, delta)
        // 在整个可变范围里找侧面那台最合适的位置（靠在椅子上能挪 10–15°），再按速度限制往那边挪
        var best = (shift: 0.0, score: base)
        for target in stride(from: -configuration.flexRange, through: configuration.flexRange, by: 1) {
            let shift = side == .mac ? delta - target : target - delta
            guard abs(shift) >= 0.5 else { continue }
            let x = side == .mac ? m + shift : m
            let s = likelihood(x, target)
            if s > best.score { best = (shift, s) }
        }
        guard best.score > base + 3 else { return }
        let shift = max(-limit, min(limit, best.shift))
        if side == .mac {
            mac = m + shift
            delta -= shift
        } else {
            delta += shift
        }
    }

    // MARK: - 地图

    /// 开头的先验：常用那台 30 秒、宽一些（σ 10°），另一台 10 秒（σ 6°）
    public static func seeds(angle: Double, main: Screen) -> [Double] {
        var map = [Double](repeating: 0, count: 360)
        func bump(_ center: Double, _ sigma: Double, _ mass: Double) {
            for i in 0..<360 {
                let d = wrap(Double(i - 180) - center)
                map[i] += mass * exp(-d * d / (2 * sigma * sigma)) / (sigma * (2 * Double.pi).squareRoot())
            }
        }
        bump(0, main == .mac ? 10 : 6, main == .mac ? 30 : 10)
        bump(angle, main == .windows ? 10 : 6, main == .windows ? 30 : 10)
        return map
    }

    /// 记下一次注视（当时相对 Mac 的度数），换成地图坐标，等它离开对位用的窗口再学进地图
    private mutating func remember(_ relative: Double, seconds: Double, at time: Double) {
        let position = classify(relative) == .windows ? relative - delta : relative
        pendingLearn.append((time, position, seconds))
        while let first = pendingLearn.first, time - first.time > configuration.recentMemory {
            pendingLearn.removeFirst()
            learn(first.relative, seconds: first.seconds)
        }
    }

    /// 把一次注视记进地图（地图坐标），整张图同时按 mapMemory 衰减；总量超过 2 小时就整体缩小
    private mutating func learn(_ relative: Double, seconds: Double) {
        let decay = exp(-seconds / configuration.mapMemory)
        for i in 0..<360 { map[i] *= decay }
        let position = Self.wrap(relative) + 180
        let low = Int(position.rounded(.down))
        let fraction = position - Double(low)
        map[(low % 360 + 360) % 360] += seconds * (1 - fraction)
        map[((low + 1) % 360 + 360) % 360] += seconds * fraction
        learned += seconds
        let total = map.reduce(0, +)
        if total > 7200 {
            let scale = 7200 / total
            for i in 0..<360 { map[i] *= scale }
        }
        densityDirty = true
    }

    /// 找 Mac 和 Windows 之间最少看的地方当分界，把地图分成两半各自平滑（σ 2°），加底（没看过的地方也有一点概率）
    private mutating func refreshDensity() {
        guard densityDirty else { return }
        densityDirty = false
        let smooth = Self.smoothed(map)
        // 分界：0 和夹角之间（两头各让 3°）看得最少的地方；看不出低谷时取中点
        let a = calibratedAngle
        let lo = min(0, a) + 3, hi = max(0, a) - 3
        boundary = a / 2
        if hi > lo {
            var best = Double.infinity
            var r = lo
            while r <= hi {
                let v = smooth[Int(r.rounded()) + 180]
                if v < best {
                    best = v
                    boundary = r
                }
                r += 1
            }
        }
        var macRaw = [Double](repeating: 0, count: 360)
        var windowsRaw = macRaw
        for i in 0..<360 {
            if mapScreen(Double(i - 180)) == .windows { windowsRaw[i] = map[i] } else { macRaw[i] = map[i] }
        }
        macPart = Self.smoothed(macRaw)
        windowsPart = Self.smoothed(windowsRaw)
        let total = macPart.reduce(0, +) + windowsPart.reduce(0, +)
        floorValue = total * 0.001
        logNorm = log(total + floorValue * 360)
    }

    private static func smoothed(_ values: [Double]) -> [Double] {
        let weights = (-6...6).map { exp(-Double($0 * $0) / 8) }
        let weightSum = weights.reduce(0, +)
        var smooth = [Double](repeating: 0, count: 360)
        for i in 0..<360 {
            var s = 0.0
            for (k, w) in zip(-6...6, weights) { s += w * values[((i + k) % 360 + 360) % 360] }
            smooth[i] = s / weightSum
        }
        return smooth
    }

    /// 地图坐标（相对 Mac 的度数，夹角按校准时）→ 哪台：分界哪边；离 Mac 外侧 35° 以上、离 Windows 外侧 40° 以上算别处
    private func mapScreen(_ relative: Double) -> Screen? {
        let sign: Double = calibratedAngle >= 0 ? 1 : -1
        let r = Self.wrap(relative) * sign, a = abs(calibratedAngle), b = boundary * sign
        if r >= -35 && r < b { return .mac }
        if r >= b && r <= a + 40 { return .windows }
        return nil
    }

    /// 相对 Mac 的度数（按现在的夹角）→ 算在看哪台：比地图两半在这里谁看得多；都没怎么看过时按中点分
    private func classify(_ relative: Double) -> Screen? {
        let sign: Double = angle >= 0 ? 1 : -1
        let r = Self.wrap(relative) * sign, a = abs(angle)
        guard r >= -35 && r <= a + 40 else { return nil }
        let m = Self.sample(macPart, relative), w = Self.sample(windowsPart, relative - delta)
        if max(m, w) > 3 * floorValue { return w > m ? .windows : .mac }
        return r >= a / 2 ? .windows : .mac
    }

    private static func sample(_ part: [Double], _ relative: Double) -> Double {
        guard part.count == 360 else { return 0 }
        let position = wrap(relative) + 180
        let low = Int(position.rounded(.down))
        let fraction = position - Double(low)
        return part[(low % 360 + 360) % 360] * (1 - fraction) + part[((low + 1) % 360 + 360) % 360] * fraction
    }

    /// Mac 在 x、夹角变了 d 时，相对 Mac relative 度的地方的对数概率
    private func logDensity(_ relative: Double, _ d: Double) -> Double {
        log(Self.sample(macPart, relative) + Self.sample(windowsPart, relative - d) + floorValue) - logNorm
    }

    /// 最近的注视按 Mac 在 x、夹角变了 d 时对上地图的程度（对数似然，按秒加权）
    private func likelihood(_ x: Double, _ d: Double) -> Double {
        var total = 0.0
        for f in recent { total += f.seconds * logDensity(f.heading - x, d) }
        return total
    }

    /// 夹角离 prior 越远扣得越多
    private func flexPenalty(_ d: Double, prior: Double) -> Double {
        let z = (d - prior) / 10
        return 3 * z * z
    }

    /// 一圈里找最好的位置和夹角变化（离 prior 越远扣得越多），以及它比第二好的位置（离它 10° 以上）强多少
    private func alignAround(_ center: Double, prior: Double) -> (x: Double, d: Double, margin: Double, score: Double) {
        let deltas = Array(stride(from: -configuration.flexRange, through: configuration.flexRange, by: 4))
        var scores: [(x: Double, d: Double, score: Double)] = []
        var x = center - 180
        while x < center + 180 {
            var best = (d: prior, score: -Double.infinity)
            for d in deltas {
                let s = likelihood(x, d) - flexPenalty(d, prior: prior)
                if s > best.score { best = (d, s) }
            }
            scores.append((x, best.d, best.score))
            x += 1
        }
        guard let top = scores.max(by: { $0.score < $1.score }) else { return (center, prior, 0, -Double.infinity) }
        let second = scores.filter { abs(Self.wrap($0.x - top.x)) > 10 }.map(\.score).max() ?? -Double.infinity
        var fine = (x: top.x, d: top.d, score: top.score)
        var fx = top.x - 1
        while fx <= top.x + 1 {
            var d = max(-configuration.flexRange, top.d - 3)
            while d <= min(configuration.flexRange, top.d + 3) {
                let s = likelihood(fx, d) - flexPenalty(d, prior: prior)
                if s > fine.score { fine = (fx, d, s) }
                d += 1
            }
            fx += 0.25
        }
        return (fine.x, fine.d, top.score - second, fine.score)
    }

    /// 最近的注视铺开了多少度：按秒数加权，第 10 到第 90 个百分位之间
    private var spread: Double {
        let sorted = recent.sorted { $0.heading < $1.heading }
        let total = sorted.reduce(0) { $0 + $1.seconds }
        guard total > 0 else { return 0 }
        var low: Double?, high: Double?, running = 0.0
        for f in sorted {
            running += f.seconds
            if low == nil && running >= 0.1 * total { low = f.heading }
            if high == nil && running >= 0.9 * total { high = f.heading }
        }
        return (high ?? 0) - (low ?? 0)
    }

    /// 最近的注视有多少（按秒）落在地图上看过的地方（比没看过的地方高 2 个对数似然以上）
    private func known(_ x: Double, _ d: Double) -> Double {
        let floorLog = log(floorValue) - logNorm
        var inside = 0.0, total = 0.0
        for f in recent {
            if logDensity(f.heading - x, d) > floorLog + 2 { inside += f.seconds }
            total += f.seconds
        }
        return total > 0 ? inside / total : 0
    }

    /// 夹角变化固定为 d，在 center ± range 里按 step 找最好的 x，再在它附近细调
    private func align(around center: Double, delta d: Double, range: Double, step: Double) -> (x: Double, score: Double) {
        var best = (x: center, score: -Double.infinity)
        var x = center - range
        while x <= center + range {
            let s = likelihood(x, d)
            if s > best.score { best = (x, s) }
            x += step
        }
        let coarse = best.x
        var fine = coarse - step
        while fine <= coarse + step {
            let s = likelihood(fine, d)
            if s > best.score { best = (fine, s) }
            fine += step / 4
        }
        return best
    }

    private static func median(_ values: [Double]) -> Double {
        let sorted = values.sorted()
        return sorted[sorted.count / 2]
    }

    /// 换到 -180…180 度
    public static func wrap(_ angle: Double) -> Double {
        var a = fmod(angle + 180, 360)
        if a < 0 { a += 360 }
        return a - 180
    }
}
