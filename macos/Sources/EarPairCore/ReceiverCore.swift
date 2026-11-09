import Foundation
import os

private let bufferLog = Logger(subsystem: "app.earpair", category: "buffer")

public enum PlaybackState: String, Sendable {
    /// 没有发送端
    case idle
    /// 正在攒缓冲
    case buffering
    case playing
    /// 发送端那边没有声音，暂停发包，只用 HELLO 保持握手；有声音时接着发同一个流
    case standby
}

public struct StreamFormat: Equatable, Sendable {
    public var sampleRate: Int
    public var channels: Int

    public init(sampleRate: Int, channels: Int) {
        self.sampleRate = sampleRate
        self.channels = channels
    }
}

public enum IngestResult: Equatable, Sendable {
    case accepted
    /// 迟到（已经判为丢失）或重复的包
    case late
    /// 格式不对的包
    case rejected
    /// 来自其他发送端；当前发送端还在活动，忽略
    case ignored
}

/// 一路流为什么结束了
public enum EndReason: String, Equatable, Sendable {
    /// 发送端主动停止（关掉开关、退出、换了别的 Mac）
    case stopped
    /// 网络问题：一直收不到包（超时），或者发送端联系不上 Mac、自己暂停了
    case network
    /// 发送端的音频设备没了（拔掉、被停用）
    case device

    /// BYE 里的 reason。没有或者不认识的当作主动停止（早期的发送端不带 reason）
    public init(byeReason: String?) {
        switch byeReason {
        case "network": self = .network
        case "device": self = .device
        default: self = .stopped
        }
    }
}

public struct ReceiverStats: Equatable, Sendable {
    public var state: PlaybackState = .idle
    public var senderAddress: String?
    /// 当前（或最近一个）流的 ID
    public var streamID: UInt32?
    /// 现在是 idle 时，最近一路流是怎么结束的；正在收或者从没收过时是 nil
    public var endReason: EndReason?
    public var format: StreamFormat?
    public var packetsReceived = 0
    public var packetsLost = 0
    public var packetsLate = 0
    public var packetsRejected = 0
    public var packetsIgnored = 0
    public var concealedFrames = 0
    public var underruns = 0
    public var latencyTrims = 0
    public var resyncs = 0
    public var bytesReceived = 0
    public var bufferedMs = 0.0
    public var targetMs = 0.0
    public var driftPPM = 0.0
    public var jitterMs = 0.0
    public var secondsSinceLastPacket: Double?
    /// 当前流已经播放了多久（秒）。时钟偏差估计大约需要 1 分钟才稳定。
    public var secondsPlayed = 0.0
    /// 输入电平（增益之前的峰值，带回落），dBFS
    public var inputLevelDB = -120.0
    /// 输出电平（音量、平衡和限幅之后的峰值，带回落），dBFS
    public var outputLevelDB = -120.0
    /// 输入的听感响度估计（LUFS），还没有声音时为 nil
    public var loudnessLUFS: Double?
    /// 音量平衡当前加上的增益（dB），关闭时为 0
    public var levelingGainDB = 0.0
    /// 最近半秒内限幅器是否压过峰值
    public var isLimiting = false

    public init() {}

    /// 丢包率（%）
    public var lossPercent: Double {
        let total = packetsReceived + packetsLost
        return total == 0 ? 0 : Double(packetsLost) * 100 / Double(total)
    }
}

/// 接收端核心：把网络包整理成连续的音频（排序、丢包补偿、缓冲、时钟漂移补偿），供音频线程拉取。
///
/// 线程约定：
/// - `ingest` 只在一个线程上调用（网络线程，或测试线程）；
/// - `render` 只在音频渲染线程上调用；
/// - 其他方法可以在任意线程调用。
public final class ReceiverCore: @unchecked Sendable {
    public struct Configuration: Sendable {
        /// 手动的缓冲目标（秒）；自动缓冲打开时不用它
        public var targetLatency = 0.060
        /// 自动缓冲：按网络情况自己调整缓冲目标（见 AdaptiveBuffer）
        public var autoBuffer = false
        /// 缺包时最多再等几个后续包
        public var reorderWindow = 3
        /// 多久收不到包算断开（秒）
        public var streamTimeout = 1.0
        /// 待机时多久收不到 HELLO 算断开（秒）：发送端每秒发一次
        public var standbyTimeout = 6.0
        /// 用静音补上的最长缺口（秒），更长就清空缓冲重新开始
        public var maxConcealDuration = 0.25
        /// 缓冲超过「目标 + 这个值」时直接丢掉多余的部分（秒）
        public var latencyHeadroom = 0.060
        public var driftCompensation = true
        /// 环形缓冲容量（秒）
        public var bufferCapacity = 2.0
        /// 音量平衡：自动把远端声音的响度拉到 targetLoudness
        public var autoLevel = false
        /// 音量平衡的目标响度（LUFS）
        public var targetLoudness = -16.0

        public init() {}
    }

    /// 新的流开始（或断开后恢复）时，在调用 `ingest` 的线程上回调。用来启动或重建音频输出。
    public var onStreamStarted: ((StreamFormat) -> Void)?

    static let maxRenderBlock = 4096
    static let ingestFadeFrames = 64
    static let renderFadeFrames = 128
    static let maxSequenceJump: Int32 = 1000
    private static let renderBufferFrames = maxRenderBlock + 64

    private final class Stream {
        let id: UInt32
        let format: StreamFormat
        let senderAddress: String
        var nextSequence: UInt32
        var nextSampleTime: UInt64
        var lastArrival: Double
        var lastTransit: Double?

        init(id: UInt32, format: StreamFormat, senderAddress: String,
             nextSequence: UInt32, nextSampleTime: UInt64, lastArrival: Double) {
            self.id = id
            self.format = format
            self.senderAddress = senderAddress
            self.nextSequence = nextSequence
            self.nextSampleTime = nextSampleTime
            self.lastArrival = lastArrival
        }
    }

    private struct PendingPacket {
        let header: PacketHeader
        /// 交错立体声
        var samples: [Float]
    }

    /// 被发送端用 BYE 结束的流
    private struct EndedStream {
        let sender: String
        let id: UInt32
    }

    /// 最近一路流怎么结束的；开始新流时清掉
    private var lastEndReason: EndReason?
    /// 待机时最近一次 HELLO 的时间
    private var standbyHelloAt = 0.0
    /// 待机时：恢复后第一个包的序号（发送端在 HELLO 里告诉的），比它小的是暂停前发出、晚到的包
    private var standbyResumeSequence: UInt32?

    private let lock = UnfairLock()

    // ---- 以下状态都受 lock 保护 ----
    private var config: Configuration
    private var stream: Stream?
    private var ring: StereoRing?
    private var pending: [UInt32: PendingPacket] = [:]
    /// 音频线程上用掉的待处理包先放这里，回到网络线程再释放（音频线程上不释放内存）
    private var recycled: [PendingPacket] = []
    private var state: PlaybackState = .idle
    /// 最近一个被 BYE 结束的流；开始新流时清掉
    private var endedStream: EndedStream?
    /// 当前流是否已经开始播放过（开播前因为音频输出还没启动而丢掉的积压数据不算"裁剪"）
    private var hasPlayed = false
    private var fadeInNextPacket = false
    private var fadeInNextRender = false
    private var outputSampleRate = 0.0
    private var gain: Float = 1
    private var muted = false
    /// 左右平衡，−1（只有左边）… 0 … 1（只有右边）
    private var balance: Float = 0
    private var meters = Meters()
    private var counters = ReceiverStats()
    private var jitter = 0.0
    private var driftEstimatePPM = 0.0
    /// 显示用的缓冲水位（帧），和漂移控制看的是同一个水位。
    /// 低通滤掉按包到达造成的 5 ms 锯齿，否则界面每 0.3 秒取一次样，曲线会混叠成假的起伏。
    private var displayLevel: Double?
    /// 当前流已经播放的帧数
    private var playedFrames = 0
    /// 新流开始时 +1：渲染侧据此重置漂移估计和插值状态
    private var streamEpoch = 0
    /// 缓冲被清空或裁剪时 +1：渲染侧据此重置水位滤波
    private var levelEpoch = 0

    // ---- 只在调用 ingest 的线程上使用 ----
    private let decodeBuffer: UnsafeMutablePointer<Float>

    // ---- 只在渲染线程上使用 ----
    private var renderStreamEpoch = -1
    private var renderLevelEpoch = -1
    private var drift = DriftController()
    private var adaptive = AdaptiveBuffer()
    /// 日志里上次记下的自动缓冲目标
    private var loggedTarget = AdaptiveBuffer().target
    private var resampler = DriftResampler()
    private var leveler = LoudnessLeveler()
    private var limiter = PeakLimiter()
    private var renderRate = 48_000.0
    private var levelingGain: Float = 1
    private var appliedLeft: Float = 1
    private var appliedRight: Float = 1
    private var inputMeter = -120.0
    private var outputMeter = -120.0
    private var limitingHold = 0.0
    private let renderBuffer: UnsafeMutablePointer<Float>

    /// 渲染线程算出的电平，在锁里交给统计
    private struct Meters {
        var inputLevelDB = -120.0
        var outputLevelDB = -120.0
        var loudnessLUFS: Double?
        var levelingGainDB = 0.0
        var isLimiting = false
    }

    /// 渲染一块时用到的输出设置（在锁里取一次）
    private struct OutputSettings {
        var gain: Float
        var balance: Float
        var autoLevel: Bool
        var targetLoudness: Double
    }

    /// 电平表的回落速度（dB/秒）
    private static let meterFallRate = 24.0

    public init(configuration: Configuration = Configuration()) {
        config = configuration
        decodeBuffer = .allocate(capacity: PacketHeader.maxFrameCount * 2)
        decodeBuffer.initialize(repeating: 0, count: PacketHeader.maxFrameCount * 2)
        renderBuffer = .allocate(capacity: Self.renderBufferFrames * 2)
        renderBuffer.initialize(repeating: 0, count: Self.renderBufferFrames * 2)
        recycled.reserveCapacity(64)
    }

    deinit {
        decodeBuffer.deallocate()
        renderBuffer.deallocate()
    }

    // MARK: - 设置

    public var configuration: Configuration { lock.withLock { config } }

    /// 远端声音的音量，0–2（1 = 原始音量）
    public func setGain(_ value: Float) { lock.withLock { gain = min(max(value, 0), 2) } }

    public func setMuted(_ value: Bool) { lock.withLock { muted = value } }

    /// 左右平衡：−1 只有左边，0 居中，1 只有右边
    public func setBalance(_ value: Float) { lock.withLock { balance = min(max(value, -1), 1) } }

    public func setAutoLevel(_ enabled: Bool) { lock.withLock { config.autoLevel = enabled } }

    /// 音量平衡的目标响度（LUFS）
    public func setTargetLoudness(_ lufs: Double) { lock.withLock { config.targetLoudness = min(max(lufs, -30), -6) } }

    public func setDriftCompensation(_ enabled: Bool) { lock.withLock { config.driftCompensation = enabled } }

    /// 音频输出实际使用的采样率。和流的采样率不一致时输出静音，等输出重建。
    public func setOutputSampleRate(_ rate: Double) { lock.withLock { outputSampleRate = rate } }

    /// 修改手动的缓冲目标。自动缓冲关着时立刻生效：调大会重新攒缓冲（短暂静音），调小会立刻丢掉多出来的部分。
    public func setTargetLatency(_ seconds: Double) {
        lock.withLock {
            let old = currentTarget
            config.targetLatency = min(max(seconds, 0.01), 0.5)
            if !config.autoBuffer { applyTargetChange(from: old) }
        }
    }

    /// 打开或关闭自动缓冲。打开时从当前的缓冲目标开始调整；关闭时回到手动的目标。
    public func setAutoBuffer(_ on: Bool) {
        lock.withLock {
            guard on != config.autoBuffer else { return }
            let old = currentTarget
            config.autoBuffer = on
            if on {
                adaptive.start(from: old)
                loggedTarget = adaptive.target
            } else {
                applyTargetChange(from: old)
            }
        }
    }

    /// 现在用的缓冲目标（秒）
    private var currentTarget: Double { config.autoBuffer ? adaptive.target : config.targetLatency }

    private func applyTargetChange(from old: Double) {
        guard let s = stream, let ring, state != .idle else { return }
        let target = targetFrames(for: s)
        if currentTarget > old {
            if state == .playing && ring.count < target { state = .buffering }
        } else if ring.count > target {
            ring.discard(frames: ring.count - target)
            fadeInNextRender = true
        }
        levelEpoch += 1
    }

    public func resetStatistics() {
        lock.withLock { counters = ReceiverStats() }
    }

    // MARK: - 网络侧

    /// 处理一个收到的 UDP 包。`sender` 是发送端 IP，`now` 是单调时钟（秒）。
    @discardableResult
    public func ingest(_ bytes: UnsafeRawBufferPointer, from sender: String, at now: Double) -> IngestResult {
        let header: PacketHeader
        do {
            header = try PacketHeader.parse(bytes)
        } catch {
            lock.withLock { counters.packetsRejected += 1 }
            return .rejected
        }
        let frames = Int(header.frameCount)
        Self.decode(UnsafeRawBufferPointer(rebasing: bytes[PacketHeader.size...]),
                    channels: Int(header.channels), frames: frames, into: decodeBuffer)

        var startedFormat: StreamFormat?
        let result: IngestResult = lock.withLock {
            ingestLocked(header, frames: frames, sender: sender, now: now, startedFormat: &startedFormat)
        }
        if let format = startedFormat { onStreamStarted?(format) }
        return result
    }

    /// 定期调用：发送端超时就进入 idle。待机时看 HELLO，平时看音频包。
    public func housekeeping(now: Double) {
        lock.withLock {
            guard let s = stream, state != .idle else { return }
            let silence = state == .standby ? now - standbyHelloAt : now - s.lastArrival
            guard silence > (state == .standby ? config.standbyTimeout : config.streamTimeout) else { return }
            endStreamLocked()
            lastEndReason = .network
        }
    }

    /// 发送端说它那边没有声音、暂停发包了（HELLO 里 standby，每秒一次）：当前流进入待机。
    /// 待机时不按 1 秒没包算断开、不算卡顿，HELLO 停了才算断开；它暂停前最后几个包是静音，缓冲直接清掉。
    /// 恢复不看 HELLO（可能乱序），看音频包：序号到了 `resumeSequence` 的包来了就恢复。
    public func enterStandby(stream id: UInt32, from sender: String, resumeSequence: UInt32?, now: Double) {
        lock.withLock {
            guard let s = stream, s.id == id, s.senderAddress == sender, state != .idle else { return }
            if state == .standby {
                standbyHelloAt = now
                return
            }
            // 已经收到恢复后的包了：这是晚到的旧 HELLO
            if let resume = resumeSequence, Int32(bitPattern: s.nextSequence &- resume) > 0 { return }
            state = .standby
            standbyHelloAt = now
            standbyResumeSequence = resumeSequence ?? s.nextSequence
            ring?.clear()
            pending.removeAll()
            levelEpoch += 1
        }
    }

    /// 发送端说它停了（控制包 BYE）：是当前流就立即进入 idle，不等超时。
    /// 之后同一个流迟到的包都忽略，不会再“连上”一次；同一个发送端换了新流照常开始。
    /// 已经按超时结束了（BYE 比超时晚到）也要记下原因：是手动停止就不再当成网络断开去重连。
    public func endStream(_ id: UInt32, from sender: String, reason: EndReason = .stopped) {
        lock.withLock {
            guard let s = stream, s.id == id, s.senderAddress == sender else { return }
            if state != .idle { endStreamLocked() }
            endedStream = EndedStream(sender: sender, id: id)
            lastEndReason = reason
        }
    }

    private func endStreamLocked() {
        state = .idle
        standbyResumeSequence = nil
        ring?.clear()
        pending.removeAll()
        levelEpoch += 1
    }

    private func ingestLocked(_ header: PacketHeader, frames: Int, sender: String, now: Double,
                              startedFormat: inout StreamFormat?) -> IngestResult {
        if !recycled.isEmpty { recycled.removeAll(keepingCapacity: true) }
        if let ended = endedStream, ended.id == header.streamID, ended.sender == sender {
            // BYE 之后还在路上的包
            counters.packetsIgnored += 1
            return .ignored
        }
        if let s = stream, s.id == header.streamID, state == .standby {
            if let resume = standbyResumeSequence, Int32(bitPattern: header.sequence &- resume) < 0 {
                // 暂停前发出、晚到的包（静音），不当成恢复
                counters.packetsIgnored += 1
                return .ignored
            }
            // 发送端又有声音了：从这个包开始重新攒缓冲（不算卡顿），到达抖动重新估计
            state = .buffering
            standbyResumeSequence = nil
            s.nextSequence = header.sequence
            s.nextSampleTime = header.sampleTime
            s.lastTransit = nil
            adaptive.restart()
            pending.removeAll()
            fadeInNextPacket = true
        }
        if let s = stream, s.id == header.streamID, state != .idle {
            // 当前流的包，往下走
        } else if let s = stream, state != .idle, s.senderAddress != sender,
                  state == .standby || now - s.lastArrival < config.streamTimeout {
            // 当前发送端还在（待机的发送端也算：它靠 HELLO 保持，HELLO 停了 housekeeping 会结束它）
            counters.packetsIgnored += 1
            return .ignored
        } else {
            beginStream(header, sender: sender, now: now)
            startedFormat = stream?.format
        }
        guard let s = stream else { return .rejected }

        let delta = Int32(bitPattern: header.sequence &- s.nextSequence)
        if (delta < 0 && delta > -Self.maxSequenceJump) || pending[header.sequence] != nil {
            counters.packetsLate += 1
            // 晚到的包正说明缓冲不够，自动缓冲要算上它
            adaptive.latePacketArrived(transit: transit(s, header, now: now), at: now)
            logBufferChange()
            return .late
        }

        counters.packetsReceived += 1
        counters.bytesReceived += header.packetSize
        s.lastArrival = now
        updateJitter(s, header, now: now)

        if delta == 0 {
            append(header, samples: decodeBuffer, frames: frames)
            s.nextSequence &+= 1
            flushPending()
        } else if delta > Self.maxSequenceJump || delta <= -Self.maxSequenceJump {
            // 序号跳得太远（发送端暂停过很久、大量丢包或重新编号）：从这一包重新开始
            pending.removeAll()
            resync()
            s.nextSequence = header.sequence
            s.nextSampleTime = header.sampleTime
            append(header, samples: decodeBuffer, frames: frames)
            s.nextSequence &+= 1
        } else {
            // 前面还有包没到：先存起来等一等
            pending[header.sequence] = PendingPacket(
                header: header, samples: Array(UnsafeBufferPointer(start: decodeBuffer, count: frames * 2)))
            if pending.count >= config.reorderWindow { skipToEarliestPending() }
        }
        enforceLatencyLimit()
        return .accepted
    }

    private func beginStream(_ header: PacketHeader, sender: String, now: Double) {
        endedStream = nil
        lastEndReason = nil
        standbyResumeSequence = nil
        let format = StreamFormat(sampleRate: Int(header.sampleRate), channels: Int(header.channels))
        stream = Stream(id: header.streamID, format: format, senderAddress: sender,
                        nextSequence: header.sequence, nextSampleTime: header.sampleTime, lastArrival: now)
        let capacity = Int(Double(format.sampleRate) * config.bufferCapacity)
        if let ring, ring.capacity == capacity {
            ring.clear()
        } else {
            ring = StereoRing(capacity: capacity)
        }
        pending.removeAll()
        state = .buffering
        hasPlayed = false
        playedFrames = 0
        fadeInNextPacket = true
        jitter = 0
        adaptive.restart()
        streamEpoch += 1
        levelEpoch += 1
    }

    /// 把一个按顺序轮到的包写进缓冲；处理 sampleTime 上的缺口（补静音或重新缓冲）和淡入。
    private func append(_ header: PacketHeader, samples: UnsafeMutablePointer<Float>, frames: Int) {
        guard let s = stream, let ring else { return }
        if header.sampleTime > s.nextSampleTime {
            let gap = header.sampleTime - s.nextSampleTime
            let maxConceal = UInt64(config.maxConcealDuration * Double(s.format.sampleRate))
            if gap <= maxConceal {
                conceal(frames: Int(gap))
            } else {
                resync()
            }
        }
        if fadeInNextPacket {
            let n = min(frames, Self.ingestFadeFrames)
            for i in 0..<n {
                let g = Float(i + 1) / Float(n + 1)
                samples[i * 2] *= g
                samples[i * 2 + 1] *= g
            }
            fadeInNextPacket = false
        }
        if ring.write(samples, frames: frames) > 0 {
            levelEpoch += 1
        }
        s.nextSampleTime = header.sampleTime &+ UInt64(frames)
    }

    /// 用静音补上缺失的 `frames` 帧：先让已写入数据的尾巴淡出，补完静音后让下一包淡入。
    private func conceal(frames: Int) {
        guard let ring, frames > 0 else { return }
        ring.fadeOutNewest(frames: Self.ingestFadeFrames)
        ring.writeSilence(frames: frames)
        counters.concealedFrames += frames
        fadeInNextPacket = true
    }

    /// 缺口太大：清空缓冲，用接下来的数据重新攒缓冲。
    private func resync() {
        ring?.clear()
        if state != .idle { state = .buffering }
        fadeInNextPacket = true
        counters.resyncs += 1
        levelEpoch += 1
    }

    /// 等够了还没等到缺的包：把它们记为丢失，从最早的待处理包继续。
    /// `recycle`：在音频线程上调用时为 true，用掉的包不在这里释放
    private func skipToEarliestPending(recycle: Bool = false) {
        guard let s = stream else { return }
        var earliest: UInt32?
        var smallestDelta = Int32.max
        for sequence in pending.keys {
            let d = Int32(bitPattern: sequence &- s.nextSequence)
            if d > 0 && d < smallestDelta {
                smallestDelta = d
                earliest = sequence
            }
        }
        guard let first = earliest else {
            pending.removeAll()
            return
        }
        counters.packetsLost += Int(smallestDelta)
        s.nextSequence = first
        flushPending(recycle: recycle)
    }

    /// 把已经轮到的待处理包依次写入缓冲。
    private func flushPending(recycle: Bool = false) {
        guard let s = stream else { return }
        while var packet = pending.removeValue(forKey: s.nextSequence) {
            let header = packet.header
            let frames = Int(header.frameCount)
            packet.samples.withUnsafeMutableBufferPointer { buffer in
                append(header, samples: buffer.baseAddress!, frames: frames)
            }
            s.nextSequence &+= 1
            if recycle && recycled.count < recycled.capacity { recycled.append(packet) }
        }
    }

    /// 缓冲超过「目标 + 余量」时丢掉最旧的数据（比如 Wi‑Fi 卡顿后一次涌进很多包）。
    private func enforceLatencyLimit() {
        guard let s = stream, let ring else { return }
        let target = targetFrames(for: s)
        let limit = target + Int(config.latencyHeadroom * Double(s.format.sampleRate))
        guard ring.count > limit else { return }
        ring.discard(frames: ring.count - target)
        levelEpoch += 1
        if hasPlayed { counters.latencyTrims += 1 }
        if state == .playing { fadeInNextRender = true }
    }

    private func targetFrames(for stream: Stream) -> Int {
        max(Int(currentTarget * Double(stream.format.sampleRate)), 1)
    }

    /// 传输时间：到达时刻 − 包里时间戳对应的时刻（基准是任意的，只看变化）
    private func transit(_ s: Stream, _ header: PacketHeader, now: Double) -> Double {
        now - Double(header.sampleTime) / Double(s.format.sampleRate)
    }

    /// RFC 3550 风格的到达抖动估计；同时交给自动缓冲（关着时也统计，打开时马上有数据）
    private func updateJitter(_ s: Stream, _ header: PacketHeader, now: Double) {
        let transit = transit(s, header, now: now)
        if let last = s.lastTransit {
            jitter += (abs(transit - last) - jitter) / 16
        }
        s.lastTransit = transit
        adaptive.setPacketDuration(Double(header.frameCount) / Double(s.format.sampleRate))
        adaptive.packetArrived(transit: transit, at: now)
        logBufferChange()
    }

    /// 自动缓冲的目标变了 5 ms 以上时记一笔（为什么变、变成多少），方便以后对着日志分析
    private func logBufferChange() {
        guard config.autoBuffer else { return }
        let target = adaptive.target
        guard abs(target - loggedTarget) >= 0.005 else { return }
        let incidents = adaptive.incidents
        let worst = incidents.map(\.needed).max().map { String(format: "%.0f", $0 * 1000) } ?? "—"
        bufferLog.info("""
            自动缓冲：\(String(format: "%.0f", self.loggedTarget * 1000), privacy: .public) → \
            \(String(format: "%.0f", target * 1000), privacy: .public) ms，抖动 \
            \(String(format: "%.1f", self.jitter * 1000), privacy: .public) ms，最近 5 分钟出问题 \
            \(incidents.count, privacy: .public) 次（最多要 \(worst, privacy: .public) ms）
            """)
        loggedTarget = target
    }

    /// 16-bit 交错 PCM → Float 交错立体声（单声道复制到两边，多于两个声道只取前两个）。
    private static func decode(_ payload: UnsafeRawBufferPointer, channels: Int, frames: Int,
                               into output: UnsafeMutablePointer<Float>) {
        let scale: Float = 1.0 / 32768
        let stride = channels * 2
        for f in 0..<frames {
            let base = f * stride
            let left = Float(payload.readLE(Int16.self, at: base)) * scale
            let right = channels > 1 ? Float(payload.readLE(Int16.self, at: base + 2)) * scale : left
            output[f * 2] = left
            output[f * 2 + 1] = right
        }
    }

    // MARK: - 渲染侧

    /// 由音频渲染线程调用：输出 `frames` 帧到左右声道。返回 false 表示整段都是静音。
    @discardableResult
    public func render(left: UnsafeMutablePointer<Float>, right: UnsafeMutablePointer<Float>, frames: Int) -> Bool {
        var offset = 0
        var produced = false
        while offset < frames {
            let n = min(frames - offset, Self.maxRenderBlock)
            if renderBlock(left: left + offset, right: right + offset, frames: n) { produced = true }
            offset += n
        }
        return produced
    }

    private func renderBlock(left: UnsafeMutablePointer<Float>, right: UnsafeMutablePointer<Float>,
                             frames n: Int) -> Bool {
        var ratio = 1.0
        var haveAudio = false
        var fadeIn = false
        let settings: OutputSettings

        lock.lock()
        if renderStreamEpoch != streamEpoch {
            renderStreamEpoch = streamEpoch
            drift.reset()
            resampler.reset()
            displayLevel = nil
            if let s = stream {
                renderRate = Double(s.format.sampleRate)
                leveler.prepare(sampleRate: renderRate)
                limiter.prepare(sampleRate: renderRate)
            }
        }
        if renderLevelEpoch != levelEpoch {
            renderLevelEpoch = levelEpoch
            drift.resetLevel()
            displayLevel = nil
        }
        settings = OutputSettings(gain: muted ? 0 : gain, balance: balance,
                                  autoLevel: config.autoLevel, targetLoudness: config.targetLoudness)
        if let s = stream, let ring, state != .idle, Double(s.format.sampleRate) == outputSampleRate {
            let rate = Double(s.format.sampleRate)
            let target = targetFrames(for: s)
            if state == .buffering && ring.count >= target {
                // 开播时缓冲最多比目标多 10 ms（比如卡顿后一次涌进很多包），多出来的直接丢掉，免得延迟偏高
                let keep = target + Int(0.010 * rate)
                if ring.count > keep { ring.discard(frames: ring.count - keep) }
                drift.resetLevel()
                displayLevel = nil
                state = .playing
                hasPlayed = true
                fadeIn = true
            }
            if state == .playing {
                let level = Double(ring.count)
                let smoothing = 1 - exp(-Double(n) / rate / drift.levelSmoothing)
                displayLevel = displayLevel.map { $0 + smoothing * (level - $0) } ?? level
                adaptive.setRenderBlock(Double(n) / rate)
                if config.driftCompensation {
                    ratio = drift.update(levelFrames: ring.count, targetFrames: target,
                                         blockFrames: n, sampleRate: rate)
                }
                let need = DriftResampler.requirement(phase: resampler.phase, outputFrames: n, ratio: ratio)
                // 缓冲不够这一块了，而缺的包后面的包已经到了：不再等缺的包（它晚到也来不及播了），
                // 现在就记为丢失、补上静音，接着播后面的。不然丢一个包就会卡一次、重新攒缓冲
                while ring.count < need.needed && !pending.isEmpty {
                    skipToEarliestPending(recycle: true)
                }
                if ring.count >= need.needed {
                    ring.peek(into: renderBuffer, frames: need.needed)
                    ring.discard(frames: need.consumed)
                    playedFrames += n
                    haveAudio = true
                } else {
                    // 缓冲耗尽：这一块输出静音，重新攒缓冲
                    state = .buffering
                    counters.underruns += 1
                    adaptive.underrun()
                }
                driftEstimatePPM = config.driftCompensation ? drift.estimatedPPM : 0
            }
        }
        if fadeInNextRender && haveAudio {
            fadeInNextRender = false
            fadeIn = true
        }
        lock.unlock()

        guard haveAudio else {
            left.update(repeating: 0, count: n)
            right.update(repeating: 0, count: n)
            (appliedLeft, appliedRight) = Self.channelGains(settings, leveling: levelingGain)
            updateMeters(inputPeak: 0, outputPeak: 0, limited: false, frames: n)
            return false
        }
        resampler.process(input: renderBuffer, outputFrames: n, ratio: ratio, left: left, right: right)
        if fadeIn { Self.applyFadeIn(left: left, right: right, frames: n) }

        // 音量平衡：总是分析（打开时立刻有合适的增益），只在打开时生效
        let inputPeak = Self.peak(left: left, right: right, frames: n)
        leveler.targetLUFS = settings.targetLoudness
        let analyzed = leveler.process(left: left, right: right, frames: n)
        levelingGain = settings.autoLevel ? analyzed : 1

        // 音量 × 音量平衡 × 左右平衡，在这一块里线性过渡，避免"咔哒"声
        let (wantLeft, wantRight) = Self.channelGains(settings, leveling: levelingGain)
        Self.applyRamp(left, frames: n, from: appliedLeft, to: wantLeft)
        Self.applyRamp(right, frames: n, from: appliedRight, to: wantRight)
        appliedLeft = wantLeft
        appliedRight = wantRight

        // 限幅，同时量输出电平
        var outputPeak: Float = 0
        var limited = false
        for i in 0..<n {
            var l = left[i]
            var r = right[i]
            if limiter.process(&l, &r) {
                limited = true
                left[i] = l
                right[i] = r
            }
            outputPeak = max(outputPeak, max(abs(l), abs(r)))
        }
        updateMeters(inputPeak: inputPeak, outputPeak: outputPeak, limited: limited, frames: n)
        return true
    }

    private static func channelGains(_ settings: OutputSettings, leveling: Float) -> (Float, Float) {
        let base = settings.gain * leveling
        return (base * min(1, 1 - settings.balance), base * min(1, 1 + settings.balance))
    }

    private static func applyRamp(_ samples: UnsafeMutablePointer<Float>, frames: Int, from start: Float, to end: Float) {
        if start == end {
            guard end != 1 else { return }
            for i in 0..<frames { samples[i] *= end }
        } else {
            let step = (end - start) / Float(frames)
            for i in 0..<frames { samples[i] *= start + step * Float(i + 1) }
        }
    }

    private static func peak(left: UnsafePointer<Float>, right: UnsafePointer<Float>, frames: Int) -> Float {
        var result: Float = 0
        for i in 0..<frames { result = max(result, max(abs(left[i]), abs(right[i]))) }
        return result
    }

    private static func decibels(_ value: Float) -> Double {
        value > 1e-6 ? max(20 * log10(Double(value)), -120) : -120
    }

    private func updateMeters(inputPeak: Float, outputPeak: Float, limited: Bool, frames: Int) {
        let dt = Double(frames) / renderRate
        inputMeter = max(Self.decibels(inputPeak), inputMeter - Self.meterFallRate * dt)
        outputMeter = max(Self.decibels(outputPeak), outputMeter - Self.meterFallRate * dt)
        limitingHold = limited ? 0.5 : max(0, limitingHold - dt)
        let snapshot = Meters(inputLevelDB: inputMeter, outputLevelDB: outputMeter,
                              loudnessLUFS: leveler.loudnessLUFS, levelingGainDB: leveler.gainDB,
                              isLimiting: limitingHold > 0)
        lock.withLock { meters = snapshot }
    }

    private static func applyFadeIn(left: UnsafeMutablePointer<Float>, right: UnsafeMutablePointer<Float>,
                                    frames: Int) {
        let n = min(frames, renderFadeFrames)
        for i in 0..<n {
            let g = Float(i + 1) / Float(n + 1)
            left[i] *= g
            right[i] *= g
        }
    }

    // MARK: - 统计

    public func statistics(now: Double) -> ReceiverStats {
        lock.withLock {
            var result = counters
            result.state = state
            result.endReason = state == .idle ? lastEndReason : nil
            result.targetMs = currentTarget * 1000
            result.jitterMs = jitter * 1000
            result.driftPPM = driftEstimatePPM
            result.inputLevelDB = meters.inputLevelDB
            result.outputLevelDB = meters.outputLevelDB
            result.loudnessLUFS = meters.loudnessLUFS
            result.levelingGainDB = config.autoLevel ? meters.levelingGainDB : 0
            result.isLimiting = meters.isLimiting
            if let s = stream {
                result.senderAddress = s.senderAddress
                result.streamID = s.id
                result.format = s.format
                result.secondsSinceLastPacket = now - s.lastArrival
                // 播放中显示平滑后的水位（和缓冲目标同一口径），否则显示当前缓冲量
                let frames = state == .playing ? (displayLevel ?? 0) : Double(ring?.count ?? 0)
                result.bufferedMs = frames / Double(s.format.sampleRate) * 1000
                result.secondsPlayed = Double(playedFrames) / Double(s.format.sampleRate)
            }
            return result
        }
    }
}
