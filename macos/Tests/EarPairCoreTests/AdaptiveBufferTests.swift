import EarPairCore
import Testing

@Suite("自动缓冲")
struct AdaptiveBufferTests {
    /// 每 5 ms 一个包，`delay(t)` 给出这个包比最顺利时晚到多少秒
    func feed(_ buffer: inout AdaptiveBuffer, from start: Double, seconds: Double, delay: (Double) -> Double) {
        var t = start
        while t < start + seconds {
            buffer.packetArrived(transit: 0.001 + delay(t), at: t + delay(t))
            t += 0.005
        }
    }

    @Test("网络很稳：降到下限 20 ms")
    func settlesAtMinimum() {
        var buffer = AdaptiveBuffer(initial: 0.060)
        buffer.setRenderBlock(512 / 48_000)
        feed(&buffer, from: 0, seconds: 120) { t in 0.001 * (t * 200).truncatingRemainder(dividingBy: 2) }
        #expect(abs(buffer.target - 0.020) < 0.0005, "目标 \(buffer.target)")
    }

    @Test("抖动变大：立刻加大到盖住它；变好以后每秒最多减 1 ms")
    func followsJitterUpAndSlowlyDown() {
        var buffer = AdaptiveBuffer(initial: 0.020)
        buffer.setRenderBlock(0.010)
        // 每 50 ms 有一个包晚到 30 ms
        feed(&buffer, from: 0, seconds: 30) { t in Int(t * 200) % 10 == 0 ? 0.030 : 0 }
        #expect(buffer.target >= 0.044 && buffer.target <= 0.046, "目标 \(buffer.target)")
        let high = buffer.target
        // 网络变好：半分钟内旧数据还在窗口里，不降
        feed(&buffer, from: 30, seconds: 28) { _ in 0 }
        #expect(buffer.target == high)
        // 窗口过去以后开始降，每秒最多 1 ms
        feed(&buffer, from: 58, seconds: 10) { _ in 0 }
        #expect(buffer.target < high && buffer.target >= high - 0.011, "目标 \(buffer.target)")
        feed(&buffer, from: 68, seconds: 60) { _ in 0 }
        #expect(abs(buffer.target - 0.020) < 0.0005, "目标 \(buffer.target)")
    }

    @Test("半分钟里只有一次卡顿：不加大（真卡出欠载才加）")
    func ignoresASingleSpike() {
        var buffer = AdaptiveBuffer(initial: 0.020)
        buffer.setRenderBlock(0.010)
        feed(&buffer, from: 0, seconds: 30) { t in abs(t - 10) < 0.003 ? 0.080 : 0 }
        #expect(buffer.target < 0.021, "目标 \(buffer.target)")
    }

    /// 卡顿一次：缓冲耗尽，过了 `delay` 秒包才又到
    func stall(_ buffer: inout AdaptiveBuffer, at t: Double, delay: Double) {
        buffer.underrun()
        buffer.packetArrived(transit: 0.001 + delay, at: t + delay)
    }

    @Test("5 分钟里只卡一两次：不调")
    func ignoresOccasionalStalls() {
        var buffer = AdaptiveBuffer(initial: 0.025)
        buffer.setRenderBlock(0.010)
        feed(&buffer, from: 0, seconds: 10) { _ in 0 }
        stall(&buffer, at: 10, delay: 0.080)
        feed(&buffer, from: 11, seconds: 60) { _ in 0 }
        stall(&buffer, at: 71, delay: 0.080)
        feed(&buffer, from: 72, seconds: 20) { _ in 0 }
        #expect(buffer.target <= 0.025, "目标 \(buffer.target)")
        #expect(buffer.incidents.count == 2)
    }

    @Test("5 分钟里卡满 3 次：按量出的晚到时间加大，只放过最严重的两次")
    func raisesByMeasuredShortfall() {
        var buffer = AdaptiveBuffer(initial: 0.020)
        buffer.setRenderBlock(0.010)
        feed(&buffer, from: 0, seconds: 10) { _ in 0 }
        stall(&buffer, at: 10, delay: 0.030)   // 需要 30 + 10 + 5 = 45 ms
        feed(&buffer, from: 11, seconds: 40) { _ in 0 }
        stall(&buffer, at: 51, delay: 0.060)   // 需要 75 ms
        feed(&buffer, from: 52, seconds: 40) { _ in 0 }
        #expect(buffer.target < 0.021, "两次还不调：\(buffer.target)")
        stall(&buffer, at: 92, delay: 0.045)   // 需要 60 ms
        #expect(abs(buffer.target - 0.045) < 0.001, "盖住第 3 严重的那次：\(buffer.target)")
        // 只要 5 分钟里还有 3 次，就保持
        feed(&buffer, from: 93, seconds: 200) { _ in 0 }
        #expect(abs(buffer.target - 0.045) < 0.001, "保持：\(buffer.target)")
        // 第一次过了 5 分钟：不满 3 次了，慢慢降回来
        feed(&buffer, from: 293, seconds: 80) { _ in 0 }
        #expect(buffer.target < 0.021, "降回来：\(buffer.target)")
    }

    @Test("迟到的包也算，同一次延迟里的卡顿和几个迟到包只算一次")
    func latePacketsCountAndMerge() {
        var buffer = AdaptiveBuffer(initial: 0.020)
        buffer.setRenderBlock(0.010)
        feed(&buffer, from: 0, seconds: 10) { _ in 0 }
        stall(&buffer, at: 10, delay: 0.040)
        buffer.latePacketArrived(transit: 0.001 + 0.050, at: 10.2)
        buffer.latePacketArrived(transit: 0.001 + 0.045, at: 10.4)
        #expect(buffer.incidents.count == 1)
        #expect(abs(buffer.incidents[0].needed - 0.065) < 0.001, "取最严重的：\(buffer.incidents[0].needed)")
        feed(&buffer, from: 11, seconds: 20) { _ in 0 }
        buffer.latePacketArrived(transit: 0.001 + 0.050, at: 31)
        feed(&buffer, from: 32, seconds: 20) { _ in 0 }
        buffer.latePacketArrived(transit: 0.001 + 0.050, at: 52)
        #expect(buffer.incidents.count == 3)
        #expect(abs(buffer.target - 0.065) < 0.001, "目标 \(buffer.target)")
    }

    @Test("缓冲本来就够、却还是卡了（不是网络延迟）：不加")
    func ignoresStallsThatBufferCannotFix() {
        var buffer = AdaptiveBuffer(initial: 0.030)
        buffer.setRenderBlock(0.010)
        feed(&buffer, from: 0, seconds: 10) { _ in 0 }
        for k in 0..<4 {
            stall(&buffer, at: 10 + Double(k) * 10, delay: 0.002)
            feed(&buffer, from: 11 + Double(k) * 10, seconds: 9) { _ in 0 }
        }
        #expect(buffer.target <= 0.030, "目标 \(buffer.target)")
    }

    @Test("卡顿后先停顿了一阵（待机）：不拿停顿当延迟")
    func pauseAfterUnderrunIsNotMeasured() {
        var buffer = AdaptiveBuffer(initial: 0.020)
        buffer.setRenderBlock(0.010)
        feed(&buffer, from: 0, seconds: 10) { _ in 0 }
        buffer.underrun()
        feed(&buffer, from: 13, seconds: 5) { _ in 3.0 }
        #expect(buffer.incidents.isEmpty)
    }

    @Test("停顿（待机、发送端暂停）不算抖动")
    func pausesAreNotJitter() {
        var buffer = AdaptiveBuffer(initial: 0.020)
        buffer.setRenderBlock(0.010)
        feed(&buffer, from: 0, seconds: 5) { _ in 0 }
        // 停了 3 秒，发送端接着原来的时间戳发：传输时间整体跳了 3 秒
        feed(&buffer, from: 8, seconds: 30) { _ in 3.0 }
        #expect(buffer.target < 0.021, "目标 \(buffer.target)")
    }

    @Test("有上限 150 ms")
    func capsAtMaximum() {
        var buffer = AdaptiveBuffer(initial: 0.020)
        feed(&buffer, from: 0, seconds: 20) { t in Int(t * 200) % 10 == 0 ? 0.300 : 0 }
        #expect(buffer.target == 0.150)
    }
}

@Suite("自动缓冲（模拟）")
struct AdaptiveBufferSimulationTests {
    @Test("好网络、发送端快或慢 200 ppm，10 分钟：缓冲降到 25 ms 以下，不欠载，时钟偏差照样估准",
          arguments: [200.0, -200.0])
    func lowLatencyOnGoodNetwork(senderPPM: Double) {
        let core = makeCore(driftCompensation: true, autoBuffer: true)
        let result = NetworkSimulation(senderPPM: senderPPM, jitter: 0.002)
            .run(core: core, seconds: 10 * 60, measureAfter: 120)
        print("自动缓冲 \(senderPPM) ppm：目标 \(result.stats.targetMs) ms，缓冲 \(result.minBufferedMs)–"
            + "\(result.maxBufferedMs) ms，欠载 \(result.stats.underruns)，估计 \(result.stats.driftPPM) ppm")
        #expect(result.stats.underruns == 0)
        #expect(result.stats.targetMs < 25)
        #expect(result.maxBufferedMs < 30)
        #expect(abs(result.stats.driftPPM - senderPPM) < 10, "估计的偏差：\(result.stats.driftPPM) ppm")
    }

    @Test("抖动 30 ms，5 分钟：自动加大到盖住抖动，最多开头卡一两次")
    func growsForJitter() {
        let core = makeCore(driftCompensation: true, autoBuffer: true)
        let result = NetworkSimulation(senderPPM: 50, jitter: 0.030, seed: 3)
            .run(core: core, seconds: 5 * 60, measureAfter: 60)
        print("自动缓冲 30 ms 抖动：目标 \(result.stats.targetMs) ms，欠载 \(result.stats.underruns)")
        #expect(result.stats.underruns <= 2)
        #expect(result.stats.targetMs > 40 && result.stats.targetMs < 60)
    }

    @Test("每 20 秒卡顿 40 ms，5 分钟：开头卡一两次，之后缓冲盖住卡顿")
    func absorbsRepeatedStalls() {
        let core = makeCore(driftCompensation: true, autoBuffer: true)
        let result = NetworkSimulation(senderPPM: -50, jitter: 0.002, stallEvery: 20, stallDuration: 0.040)
            .run(core: core, seconds: 5 * 60, measureAfter: 30)
        print("自动缓冲 每 20 秒卡 40 ms：目标 \(result.stats.targetMs) ms，欠载 \(result.stats.underruns)")
        #expect(result.stats.underruns <= 2)
        #expect(result.stats.targetMs > 40 && result.stats.targetMs < 80)
    }

    @Test("每分钟卡顿 60 ms（半分钟里看不到第二次），6 分钟：卡满 3 次以后就不卡了")
    func learnsFromRepeatedStalls() {
        let core = makeCore(driftCompensation: true, autoBuffer: true)
        let result = NetworkSimulation(senderPPM: 30, jitter: 0.002, stallEvery: 60, stallDuration: 0.060)
            .run(core: core, seconds: 6 * 60, measureAfter: 30)
        print("自动缓冲 每分钟卡 60 ms：目标 \(result.stats.targetMs) ms，欠载 \(result.stats.underruns)")
        #expect(result.stats.underruns <= 3)
        #expect(result.stats.targetMs > 60 && result.stats.targetMs < 95)
    }

    @Test("5% 丢包、网络本身很稳：不因为丢包加缓冲，丢包也几乎不造成卡顿")
    func lossDoesNotRaiseBuffer() {
        let core = makeCore(driftCompensation: true, autoBuffer: true)
        let result = NetworkSimulation(senderPPM: 0, jitter: 0.002, lossRate: 0.05, seed: 5)
            .run(core: core, seconds: 3 * 60, measureAfter: 60)
        print("自动缓冲 5% 丢包：目标 \(result.stats.targetMs) ms，欠载 \(result.stats.underruns)")
        // 缺的包不再干等：缓冲快用完时直接补静音。只有连着丢两个包、又正好是最新的那两个时才可能卡一下
        #expect(result.stats.underruns <= 3)
        #expect(result.stats.targetMs < 26)
    }

    @Test("关掉自动：回到手动的目标")
    func turningOffRestoresManualTarget() {
        let core = makeCore(driftCompensation: true, autoBuffer: true)
        core.setTargetLatency(0.030)
        _ = NetworkSimulation(senderPPM: 0, jitter: 0.030).run(core: core, seconds: 30, measureAfter: 0)
        #expect(core.statistics(now: 30).targetMs > 40)
        core.setAutoBuffer(false)
        #expect(core.statistics(now: 30).targetMs == 30)
        core.setAutoBuffer(true)
        #expect(core.statistics(now: 30).targetMs == 30, "打开时从当前目标开始")
    }
}
