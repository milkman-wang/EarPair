import AppKit
import EarPairCore
import Foundation

/// 音量平衡的目标响度
public enum LoudnessPreset: String, CaseIterable, Identifiable, Sendable {
    case soft, standard, loud

    public var id: Self { self }

    public var lufs: Double {
        switch self {
        case .soft: return -20
        case .standard: return -16
        case .loud: return -12
        }
    }

    public var title: String {
        switch self {
        case .soft: return "柔和"
        case .standard: return "标准"
        case .loud: return "响亮"
        }
    }
}

/// 曲线用的一个采样点
public struct HistoryPoint: Identifiable, Sendable {
    public let id: Int
    public let time: Date
    public let bufferMs: Double
    public let jitterMs: Double
    public let inputLevelDB: Double
    public let outputLevelDB: Double
    /// 这一段时间里新丢的包、新出现的卡顿（欠载）次数
    public let packetsLost: Int
    public let underruns: Int
    public let muted: Bool

    public init(id: Int, time: Date = Date(), bufferMs: Double, jitterMs: Double, inputLevelDB: Double,
                outputLevelDB: Double, packetsLost: Int = 0, underruns: Int = 0, muted: Bool = false) {
        self.id = id
        self.time = time
        self.bufferMs = bufferMs
        self.jitterMs = jitterMs
        self.inputLevelDB = inputLevelDB
        self.outputLevelDB = outputLevelDB
        self.packetsLost = packetsLost
        self.underruns = underruns
        self.muted = muted
    }
}

/// 界面上的连接状态（已去抖）：决定路线怎么画、菜单栏图标、哪些分组显示
public enum LinkState: Equatable, Sendable {
    /// 还没有发送端
    case waiting
    /// 缓冲中：刚连上，或者播放中掉进缓冲超过 0.4 秒
    case connecting
    /// 正在播放；有没有声音看 hasSound
    case playing
    /// 发送端用 BYE 说它停了（Windows 上关了开关）
    case stopped
    /// 发送端超过 1 秒没包
    case disconnected
    /// 监听端口失败
    case receiveFailed(String)
    /// 音频输出打不开
    case outputFailed(String)
}

/// App 的状态：持有接收核心、UDP 接收和音频输出，定时刷新统计。菜单栏和主窗口共用一个实例。
@MainActor
public final class ReceiverController: ObservableObject {
    public static let port: UInt16 = 47800
    /// 曲线每隔几次刷新（0.1 秒一次）取一个点，一共保留多少个点：每 0.3 秒一个，约 1 分钟
    nonisolated static let historyInterval = 3
    nonisolated static let historyLength = 200

    @Published public private(set) var stats = ReceiverStats()
    @Published public private(set) var history: [HistoryPoint] = []
    @Published public private(set) var bitrateKbps = 0.0
    /// UDP 监听失败的原因
    @Published public private(set) var receiveError: String?
    /// 音频输出打不开的原因
    @Published public private(set) var outputError: String?
    @Published public private(set) var linkState: LinkState = .waiting
    /// 最近 1 秒内 Windows 发来的声音超过 −50 dBFS（不是只有静音保活）
    @Published public private(set) var hasSound = false
    @Published public private(set) var localAddresses: [LocalAddress] = []
    /// 声音从哪个设备出来（系统默认输出设备，比如 AirPods Pro）
    @Published public private(set) var outputDevice: OutputDevice?
    /// 发送端电脑的名字：HELLO 里报的，其次反查 IP 得到的（比如 DESKTOP-7Q2）；都没有时为 nil，界面显示 IP
    @Published public private(set) var senderName: String?
    /// 发送端是笔记本还是台式机（HELLO 里报的）；不知道时为 nil
    @Published public private(set) var senderKind: DeviceKind?
    /// 上次播放过的发送端：等待连接时占位节点显示它的名字和图标
    @Published public private(set) var lastSenderName: String?
    @Published public private(set) var lastSenderKind: DeviceKind?
    /// 这台 Mac 的名字（系统设置里的电脑名称）
    public let macName: String

    /// 远端声音的音量，0–2（1 = 100%）
    @Published public var volume: Double {
        didSet { core.setGain(Float(volume)); save(volume, Keys.volume); updateResponderInfo() }
    }

    @Published public var muted: Bool {
        didSet { core.setMuted(muted); save(muted, Keys.muted); updateResponderInfo() }
    }

    /// 左右平衡，−1…1
    @Published public var balance: Double {
        didSet { core.setBalance(Float(balance)); save(balance, Keys.balance) }
    }

    @Published public var autoLevel: Bool {
        didSet { core.setAutoLevel(autoLevel); save(autoLevel, Keys.autoLevel) }
    }

    @Published public var loudness: LoudnessPreset {
        didSet { core.setTargetLoudness(loudness.lufs); save(loudness.rawValue, Keys.loudness) }
    }

    @Published public var bufferMs: Int {
        didSet { core.setTargetLatency(Double(bufferMs) / 1000); save(bufferMs, Keys.bufferMs) }
    }

    @Published public var driftCompensation: Bool {
        didSet { core.setDriftCompensation(driftCompensation); save(driftCompensation, Keys.drift) }
    }

    public var isPlaying: Bool { stats.state == .playing }

    private enum Keys {
        static let volume = "volume"
        static let muted = "muted"
        static let balance = "balance"
        static let autoLevel = "autoLevel"
        static let loudness = "loudness"
        static let bufferMs = "bufferMs"
        static let drift = "driftCompensation"
        static let receiverID = "receiverID"
        static let lastSenderName = "lastSenderName"
        static let lastSenderKind = "lastSenderKind"
    }

    /// 断开或停止多久之后回到“等待连接”
    nonisolated static let forgetAfter = 60.0

    public static let appVersion =
        Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "0.2.0"

    private let core: ReceiverCore
    private let output: AudioOutput
    private let isLive: Bool
    private var receiver: UDPReceiver?
    private var bitrateWindowStart = MonotonicClock.now()
    private var bitrateWindowBytes = 0
    private var idleSince: Double?
    private var ticks = 0
    private var lastHistoryLost = 0
    private var lastHistoryUnderruns = 0
    private var outputMonitor: OutputDeviceMonitor?
    private var bufferingSince: Double?
    /// 进入“已停止”或“已断开”的时刻
    private var endedAt: Double?
    private var lastSoundAt = -Double.infinity
    /// 反查到的主机名（按 IP）
    private var hostNames: [String: String] = [:]
    private var lookedUp: Set<String> = []
    /// 在局域网里广播这台 Mac，Windows 端可以自动找到它
    private let advertiser = ServiceAdvertiser()
    /// 控制包：发送端的名字、回传接收状态
    private var responder: ControlResponder?

    /// 正常运行：读取保存的设置，开始监听
    public init() {
        let defaults = UserDefaults.standard
        let volume = defaults.object(forKey: Keys.volume) as? Double ?? 1
        let muted = defaults.bool(forKey: Keys.muted)
        let balance = defaults.object(forKey: Keys.balance) as? Double ?? 0
        let autoLevel = defaults.object(forKey: Keys.autoLevel) as? Bool ?? true
        let loudness = LoudnessPreset(rawValue: defaults.string(forKey: Keys.loudness) ?? "") ?? .standard
        let bufferMs = defaults.object(forKey: Keys.bufferMs) as? Int ?? 60
        let drift = defaults.object(forKey: Keys.drift) as? Bool ?? true

        var configuration = ReceiverCore.Configuration()
        configuration.targetLatency = Double(bufferMs) / 1000
        configuration.autoLevel = autoLevel
        configuration.targetLoudness = loudness.lufs
        configuration.driftCompensation = drift
        let core = ReceiverCore(configuration: configuration)
        core.setGain(Float(volume))
        core.setMuted(muted)
        core.setBalance(Float(balance))

        self.core = core
        output = AudioOutput(core: core)
        isLive = true
        macName = HostInfo.computerName
        self.volume = volume
        self.muted = muted
        self.balance = balance
        self.autoLevel = autoLevel
        self.loudness = loudness
        self.bufferMs = bufferMs
        driftCompensation = drift
        lastSenderName = defaults.string(forKey: Keys.lastSenderName)
        lastSenderKind = DeviceKind(protocolValue: defaults.string(forKey: Keys.lastSenderKind))
        start()
    }

    /// 只用来渲染界面：不监听网络、不打开音频设备、不保存设置
    public init(preview stats: ReceiverStats, addresses: [LocalAddress], bitrateKbps: Double = 0,
                volume: Double = 1, autoLevel: Bool = true, muted: Bool = false, history: [HistoryPoint] = [],
                linkState: LinkState, hasSound: Bool = true, senderName: String? = nil,
                senderKind: DeviceKind? = nil, lastSenderName: String? = nil, lastSenderKind: DeviceKind? = nil,
                macName: String = "milkman的MacBook Air",
                outputDevice: OutputDevice? = OutputDevice(name: "milkman的AirPods Pro", transport: .bluetooth)) {
        let core = ReceiverCore()
        self.core = core
        output = AudioOutput(core: core)
        isLive = false
        self.macName = macName
        self.volume = volume
        self.muted = muted
        balance = 0
        self.autoLevel = autoLevel
        loudness = .standard
        bufferMs = 60
        driftCompensation = true
        self.stats = stats
        localAddresses = addresses
        self.bitrateKbps = bitrateKbps
        self.history = history
        self.outputDevice = outputDevice
        self.linkState = linkState
        self.hasSound = hasSound
        self.senderName = senderName
        self.senderKind = senderKind
        self.lastSenderName = lastSenderName
        self.lastSenderKind = lastSenderKind
        switch linkState {
        case .receiveFailed(let message): receiveError = message
        case .outputFailed(let message): outputError = message
        default: break
        }
    }

    public func resetStatistics() {
        core.resetStatistics()
        bitrateWindowBytes = 0
        lastHistoryLost = 0
        lastHistoryUnderruns = 0
        stats = core.statistics(now: MonotonicClock.now())
    }

    private func save(_ value: Any, _ key: String) {
        if isLive { UserDefaults.standard.set(value, forKey: key) }
    }

    private func start() {
        core.onStreamStarted = { [weak self] format in
            Task { @MainActor in self?.startOutput(sampleRate: Double(format.sampleRate)) }
        }
        let core = self.core
        let id = Self.receiverID()
        let link = ReceiverLink()
        let responder = ControlResponder(core: core, info: responderInfo(id: id)) { data, endpoint in
            link.receiver?.send(data, to: endpoint)
        }
        self.responder = responder
        let receiver = UDPReceiver(
            port: Self.port,
            onPacket: { bytes, sender, now in core.ingest(bytes, from: sender, at: now) },
            onControl: { bytes, sender, now in responder.handle(bytes, from: sender, now: now) },
            onTick: { now in
                core.housekeeping(now: now)
                responder.tick(now: now)
            })
        link.receiver = receiver
        do {
            try receiver.start()
            self.receiver = receiver
            advertiser.start(port: Self.port, id: id, kind: HostInfo.kind)
        } catch {
            receiveError = error.localizedDescription
        }
        refreshAddresses()
        let monitor = OutputDeviceMonitor()
        monitor.onChange = { [weak self] device in
            self?.outputDevice = device
            self?.updateResponderInfo()
        }
        outputDevice = monitor.current
        outputMonitor = monitor
        Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .milliseconds(100))
                guard let self else { return }
                self.tick()
            }
        }
    }

    private func startOutput(sampleRate: Double) {
        do {
            try output.start(sampleRate: sampleRate)
            outputError = nil
        } catch {
            outputError = "无法打开音频输出：\(error.localizedDescription)"
        }
    }

    private func tick() {
        let now = MonotonicClock.now()
        let current = core.statistics(now: now)
        if current != stats { stats = current }
        updateLinkState(now: now)

        if now - bitrateWindowStart >= 1 {
            bitrateKbps = Double(max(0, current.bytesReceived - bitrateWindowBytes)) * 8
                / (now - bitrateWindowStart) / 1000
            bitrateWindowStart = now
            bitrateWindowBytes = current.bytesReceived
        }

        // 没有发送端 3 秒后关掉音频输出，让 AirPods 可以休眠或切到别的设备
        if current.state == .idle {
            if idleSince == nil { idleSince = now }
            if let since = idleSince, now - since > 3, output.isRunning { output.stop() }
        } else {
            idleSince = nil
            if !output.isRunning, let format = current.format {
                startOutput(sampleRate: Double(format.sampleRate))
            }
        }

        ticks += 1
        if ticks % Self.historyInterval == 0 && current.isStreaming {
            let lost = max(0, current.packetsLost - lastHistoryLost)
            let underruns = max(0, current.underruns - lastHistoryUnderruns)
            history.append(HistoryPoint(id: ticks, bufferMs: current.bufferedMs, jitterMs: current.jitterMs,
                                        inputLevelDB: current.inputLevelDB,
                                        outputLevelDB: muted ? -120 : current.outputLevelDB,
                                        packetsLost: history.isEmpty ? 0 : lost,
                                        underruns: history.isEmpty ? 0 : underruns, muted: muted))
            lastHistoryLost = current.packetsLost
            lastHistoryUnderruns = current.underruns
            if history.count > Self.historyLength { history.removeFirst(history.count - Self.historyLength) }
        }
        if ticks % 50 == 0 { refreshAddresses() }
    }

    /// 每次 tick 拿到新统计之后调用：算出去抖后的连接状态、有没有声音、发送端的名字和类型
    private func updateLinkState(now: Double) {
        if stats.inputLevelDB > -50 { lastSoundAt = now }
        let sound = now - lastSoundAt < 1
        if sound != hasSound { hasSound = sound }

        let next: LinkState
        if let receiveError {
            next = .receiveFailed(receiveError)
        } else if let outputError, stats.isStreaming {
            next = .outputFailed(outputError)
        } else {
            switch stats.state {
            case .idle:
                bufferingSince = nil
                if stats.senderAddress == nil {
                    next = .waiting
                } else {
                    // 停止或断开 60 秒后回到等待，旧数据不再留在概览上
                    let since = endedAt ?? now
                    endedAt = since
                    next = now - since > Self.forgetAfter ? .waiting
                        : stats.endedBySender ? .stopped : .disconnected
                }
            case .buffering:
                endedAt = nil
                // 播放中偶尔掉进缓冲几十毫秒时不切换，免得闪
                let since = bufferingSince ?? now
                bufferingSince = since
                let fresh = linkState == .waiting || linkState == .stopped || linkState == .disconnected
                next = fresh || now - since > 0.4 ? .connecting : linkState
            case .playing:
                endedAt = nil
                bufferingSince = nil
                next = .playing
            }
        }
        if next != linkState { linkState = next }
        updateSenderIdentity()
    }

    /// 发送端的名字和类型。名字按优先级取：HELLO 里报的 > 反查 IP 得到的 > nil（界面显示 IP）。
    /// 每个 tick 重新算，反查结果只进缓存，两种来源不会互相覆盖。正在播放时记下来，等待时占位节点用。
    private func updateSenderIdentity() {
        guard let address = stats.senderAddress else {
            if senderName != nil { senderName = nil }
            if senderKind != nil { senderKind = nil }
            return
        }
        let announced = responder?.senderName(for: address)
        if announced == nil { resolveName(address) }
        let name = announced ?? hostNames[address]
        let kind = responder?.senderKind(for: address)
        if name != senderName { senderName = name }
        if kind != senderKind { senderKind = kind }
        if linkState == .playing, let name, name != lastSenderName || kind != lastSenderKind {
            lastSenderName = name
            lastSenderKind = kind
            save(name, Keys.lastSenderName)
            if let kind {
                save(kind.rawValue, Keys.lastSenderKind)
            } else if isLive {
                UserDefaults.standard.removeObject(forKey: Keys.lastSenderKind)
            }
        }
    }

    // MARK: - 控制包

    /// 接收端的固定 id：第一次运行时生成，存在设置里
    private static func receiverID() -> String {
        if let id = UserDefaults.standard.string(forKey: Keys.receiverID), id.count == 32 { return id }
        let id = UUID().uuidString.replacingOccurrences(of: "-", with: "").lowercased()
        UserDefaults.standard.set(id, forKey: Keys.receiverID)
        return id
    }

    private func responderInfo(id: String) -> ControlResponder.LocalInfo {
        ControlResponder.LocalInfo(id: id, name: macName, kind: HostInfo.kind.rawValue, app: Self.appVersion,
                                   output: outputDevice?.name, transport: outputDevice?.protocolTransport,
                                   muted: muted, volume: volume)
    }

    private func updateResponderInfo() {
        guard let responder else { return }
        responder.update(responderInfo(id: Self.receiverID()))
    }

    /// 反查发送端的主机名，每个 IP 只查一次（查不到也不再重复查），结果进缓存
    private func resolveName(_ address: String) {
        guard isLive, lookedUp.insert(address).inserted else { return }
        Task { [weak self] in
            let name = await Task.detached(priority: .utility) { HostInfo.hostName(for: address) }.value
            if let name { self?.hostNames[address] = name }
        }
    }

    private func refreshAddresses() {
        let addresses = NetworkInfo.localAddresses()
        if addresses != localAddresses { localAddresses = addresses }
    }
}

/// 控制包回 STATUS 要用到接收器，而接收器创建时又要用控制包的回调：用一个弱引用盒子把两边接起来
private final class ReceiverLink: @unchecked Sendable {
    weak var receiver: UDPReceiver?
}
