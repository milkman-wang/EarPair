import EarPairCore
import Testing

/// 用模拟时钟跑长时间的收发：发送端时钟偏差、网络抖动、丢包、乱序、卡顿。
struct NetworkSimulation {
    /// 发送端时钟相对本机的偏差（ppm），正数表示发送端更快
    var senderPPM = 0.0
    /// 每个包随机增加 0…jitter 秒的延迟
    var jitter = 0.002
    var lossRate = 0.0
    /// 被推迟 1.5 个包间隔的比例（于是晚于下一个包到达）
    var reorderRate = 0.0
    /// 每隔多少秒卡顿一次；卡顿期间的包在卡顿结束时一起到达
    var stallEvery: Double?
    var stallDuration = 0.0
    var seed: UInt64 = 1

    struct Result {
        var stats: ReceiverStats
        var droppedPackets: Int
        var minBufferedMs: Double
        var maxBufferedMs: Double
    }

    func run(core: ReceiverCore, seconds: Double, measureAfter warmup: Double) -> Result {
        var random = SeededRandom(state: seed)
        let sampleRate = 48_000.0
        let framesPerPacket = 240
        let renderFrames = 512
        let interval = Double(framesPerPacket) / (sampleRate * (1 + senderPPM / 1e6))

        var arrivals: [(time: Double, index: Int)] = []
        var dropped = 0
        for k in 0..<Int(seconds / interval) {
            var t = Double(k) * interval + 0.001 + Double.random(in: 0...jitter, using: &random)
            if Double.random(in: 0..<1, using: &random) < lossRate {
                dropped += 1
                continue
            }
            if Double.random(in: 0..<1, using: &random) < reorderRate { t += interval * 1.5 }
            if let stallEvery {
                let phase = t.truncatingRemainder(dividingBy: stallEvery)
                if phase < stallDuration { t += stallDuration - phase }
            }
            arrivals.append((t, k))
        }
        arrivals.sort { $0.time < $1.time }

        // 复用同一个静音包，只改序号和 sampleTime，跑得快一些
        var packet = PacketFactory(silent: true).packet(0)
        let left = UnsafeMutablePointer<Float>.allocate(capacity: renderFrames)
        let right = UnsafeMutablePointer<Float>.allocate(capacity: renderFrames)
        defer {
            left.deallocate()
            right.deallocate()
        }

        var next = 0
        var now = 0.0
        var minBuffered = Double.infinity
        var maxBuffered = 0.0
        let renderInterval = Double(renderFrames) / sampleRate
        while now < seconds {
            while next < arrivals.count && arrivals[next].time <= now {
                let index = arrivals[next].index
                packet.withUnsafeMutableBytes { bytes in
                    bytes.storeBytes(of: UInt32(index).littleEndian, toByteOffset: 12, as: UInt32.self)
                    bytes.storeBytes(of: UInt64(index * framesPerPacket).littleEndian, toByteOffset: 16, as: UInt64.self)
                }
                core.ingest(packet, at: arrivals[next].time)
                next += 1
            }
            core.render(left: left, right: right, frames: renderFrames)
            if now >= warmup {
                let buffered = core.statistics(now: now).bufferedMs
                minBuffered = min(minBuffered, buffered)
                maxBuffered = max(maxBuffered, buffered)
            }
            now += renderInterval
        }
        return Result(stats: core.statistics(now: now), droppedPackets: dropped,
                      minBufferedMs: minBuffered, maxBufferedMs: maxBuffered)
    }
}

@Suite("时钟漂移补偿（模拟）")
struct DriftSimulationTests {
    @Test("发送端快或慢 200 ppm，连续 30 分钟：不欠载、不裁剪、缓冲稳定在 60 ms 附近",
          arguments: [200.0, -200.0])
    func holdsBufferForThirtyMinutes(senderPPM: Double) {
        let core = makeCore(driftCompensation: true)
        let result = NetworkSimulation(senderPPM: senderPPM, jitter: 0.002)
            .run(core: core, seconds: 30 * 60, measureAfter: 120)
        print("漂移模拟 \(senderPPM) ppm / 30 分钟：估计 \(result.stats.driftPPM) ppm，"
            + "缓冲 \(result.minBufferedMs)–\(result.maxBufferedMs) ms，欠载 \(result.stats.underruns)")

        #expect(result.stats.underruns == 0)
        #expect(result.stats.latencyTrims == 0)
        #expect(abs(result.stats.driftPPM - senderPPM) < 10, "估计的偏差：\(result.stats.driftPPM) ppm")
        #expect(result.minBufferedMs > 40, "最低缓冲 \(result.minBufferedMs) ms")
        #expect(result.maxBufferedMs < 80, "最高缓冲 \(result.maxBufferedMs) ms")
    }

    @Test("关掉漂移补偿作为对照：同样 200 ppm 会出问题")
    func withoutCompensationItDrifts() {
        let core = makeCore(driftCompensation: false)
        let result = NetworkSimulation(senderPPM: 200, jitter: 0.002)
            .run(core: core, seconds: 10 * 60, measureAfter: 60)
        // 每分钟多出 12 ms，几分钟内就会超过上限被裁剪
        #expect(result.stats.latencyTrims > 0)
    }

    @Test("1% 丢包 + 2% 乱序 + 4 ms 抖动，5 分钟：不欠载，丢包数和实际一致")
    func survivesLossAndReordering() {
        let core = makeCore(driftCompensation: true)
        let result = NetworkSimulation(senderPPM: 80, jitter: 0.004, lossRate: 0.01, reorderRate: 0.02, seed: 7)
            .run(core: core, seconds: 5 * 60, measureAfter: 30)

        #expect(result.stats.underruns == 0)
        #expect(result.droppedPackets > 0)
        #expect(result.stats.packetsLost >= result.droppedPackets)
        #expect(result.stats.packetsLost <= result.droppedPackets + result.stats.packetsLate)
        #expect(result.stats.concealedFrames >= result.droppedPackets * 240)
    }

    @Test("每 20 秒卡顿 40 ms（比缓冲短）：不欠载")
    func absorbsShortStalls() {
        let core = makeCore(driftCompensation: true)
        let result = NetworkSimulation(senderPPM: -50, jitter: 0.002, stallEvery: 20, stallDuration: 0.040)
            .run(core: core, seconds: 5 * 60, measureAfter: 30)
        #expect(result.stats.underruns == 0)
    }

    @Test("卡顿 150 ms（比缓冲长）：欠载后恢复，积压的数据被裁掉，延迟回到目标")
    func recoversFromLongStalls() {
        let core = makeCore(driftCompensation: true)
        let result = NetworkSimulation(senderPPM: 0, jitter: 0.002, stallEvery: 30, stallDuration: 0.150)
            .run(core: core, seconds: 3 * 60, measureAfter: 10)
        #expect(result.stats.underruns > 0)
        #expect(result.stats.latencyTrims > 0)
        #expect(result.stats.state == .playing)
        #expect(result.maxBufferedMs < 130)
    }
}
