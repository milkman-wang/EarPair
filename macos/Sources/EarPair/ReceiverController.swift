import EarPairCore
import Foundation

/// 菜单栏 App 的状态：持有接收核心、UDP 接收和音频输出，定时刷新统计。
@MainActor
final class ReceiverController: ObservableObject {
    static let port: UInt16 = 47800

    @Published private(set) var stats = ReceiverStats()
    @Published private(set) var bitrateKbps = 0.0
    @Published private(set) var errorMessage: String?
    @Published private(set) var localAddresses: [String] = []

    @Published var volume: Double {
        didSet {
            core.setGain(Float(volume))
            UserDefaults.standard.set(volume, forKey: Keys.volume)
        }
    }

    @Published var muted: Bool {
        didSet {
            core.setMuted(muted)
            UserDefaults.standard.set(muted, forKey: Keys.muted)
        }
    }

    @Published var bufferMs: Int {
        didSet {
            core.setTargetLatency(Double(bufferMs) / 1000)
            UserDefaults.standard.set(bufferMs, forKey: Keys.bufferMs)
        }
    }

    private enum Keys {
        static let volume = "volume"
        static let muted = "muted"
        static let bufferMs = "bufferMs"
    }

    private let core: ReceiverCore
    private let output: AudioOutput
    private var receiver: UDPReceiver?
    private var lastBytes = 0
    private var lastTick = MonotonicClock.now()
    private var idleSince: Double?
    private var ticks = 0

    init() {
        let defaults = UserDefaults.standard
        let savedVolume = defaults.object(forKey: Keys.volume) as? Double ?? 0.8
        let savedMuted = defaults.bool(forKey: Keys.muted)
        let savedBuffer = defaults.object(forKey: Keys.bufferMs) as? Int ?? 60

        var configuration = ReceiverCore.Configuration()
        configuration.targetLatency = Double(savedBuffer) / 1000
        let core = ReceiverCore(configuration: configuration)
        core.setGain(Float(savedVolume))
        core.setMuted(savedMuted)
        self.core = core
        output = AudioOutput(core: core)
        volume = savedVolume
        muted = savedMuted
        bufferMs = savedBuffer

        core.onStreamStarted = { [weak self] format in
            Task { @MainActor in self?.startOutput(sampleRate: Double(format.sampleRate)) }
        }
        startListening()
        refreshAddresses()
        Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .milliseconds(250))
                guard let self else { return }
                self.tick()
            }
        }
    }

    func resetStatistics() {
        core.resetStatistics()
        lastBytes = 0
        stats = core.statistics(now: MonotonicClock.now())
    }

    private func startListening() {
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
        let elapsed = now - lastTick
        if elapsed > 0 {
            bitrateKbps = Double(max(0, current.bytesReceived - lastBytes)) * 8 / elapsed / 1000
        }
        lastBytes = current.bytesReceived
        lastTick = now
        if current != stats { stats = current }

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
        if ticks % 20 == 0 { refreshAddresses() }
    }

    private func refreshAddresses() {
        let addresses = NetworkInfo.localIPv4Addresses()
        if addresses != localAddresses { localAddresses = addresses }
    }
}
