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
    public let bufferMs: Double
    public let jitterMs: Double
    public let inputLevelDB: Double
    public let outputLevelDB: Double

    public init(id: Int, bufferMs: Double, jitterMs: Double, inputLevelDB: Double, outputLevelDB: Double) {
        self.id = id
        self.bufferMs = bufferMs
        self.jitterMs = jitterMs
        self.inputLevelDB = inputLevelDB
        self.outputLevelDB = outputLevelDB
    }
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
    @Published public private(set) var errorMessage: String?
    @Published public private(set) var localAddresses: [LocalAddress] = []

    /// 远端声音的音量，0–2（1 = 100%）
    @Published public var volume: Double {
        didSet { core.setGain(Float(volume)); save(volume, Keys.volume) }
    }

    @Published public var muted: Bool {
        didSet { core.setMuted(muted); save(muted, Keys.muted) }
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
    }

    private let core: ReceiverCore
    private let output: AudioOutput
    private let isLive: Bool
    private var receiver: UDPReceiver?
    private var bitrateWindowStart = MonotonicClock.now()
    private var bitrateWindowBytes = 0
    private var idleSince: Double?
    private var ticks = 0

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
        self.volume = volume
        self.muted = muted
        self.balance = balance
        self.autoLevel = autoLevel
        self.loudness = loudness
        self.bufferMs = bufferMs
        driftCompensation = drift
        start()
    }

    /// 只用来渲染界面：不监听网络、不打开音频设备、不保存设置
    public init(preview stats: ReceiverStats, addresses: [LocalAddress], bitrateKbps: Double = 0,
                volume: Double = 1, autoLevel: Bool = true, history: [HistoryPoint] = []) {
        let core = ReceiverCore()
        self.core = core
        output = AudioOutput(core: core)
        isLive = false
        self.volume = volume
        muted = false
        balance = 0
        self.autoLevel = autoLevel
        loudness = .standard
        bufferMs = 60
        driftCompensation = true
        self.stats = stats
        localAddresses = addresses
        self.bitrateKbps = bitrateKbps
        self.history = history
    }

    public func resetStatistics() {
        core.resetStatistics()
        bitrateWindowBytes = 0
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
        let receiver = UDPReceiver(
            port: Self.port,
            onPacket: { bytes, sender, now in core.ingest(bytes, from: sender, at: now) },
            onTick: { now in core.housekeeping(now: now) })
        do {
            try receiver.start()
            self.receiver = receiver
        } catch {
            errorMessage = error.localizedDescription
        }
        refreshAddresses()
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
            if errorMessage?.hasPrefix("无法打开音频输出") == true { errorMessage = nil }
        } catch {
            errorMessage = "无法打开音频输出：\(error.localizedDescription)"
        }
    }

    private func tick() {
        let now = MonotonicClock.now()
        let current = core.statistics(now: now)
        if current != stats { stats = current }

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
            history.append(HistoryPoint(id: ticks, bufferMs: current.bufferedMs, jitterMs: current.jitterMs,
                                        inputLevelDB: current.inputLevelDB,
                                        outputLevelDB: muted ? -120 : current.outputLevelDB))
            if history.count > Self.historyLength { history.removeFirst(history.count - Self.historyLength) }
        }
        if ticks % 50 == 0 { refreshAddresses() }
    }

    private func refreshAddresses() {
        let addresses = NetworkInfo.localAddresses()
        if addresses != localAddresses { localAddresses = addresses }
    }
}
