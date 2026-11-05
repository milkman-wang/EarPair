import EarPairCore
import Testing

@Suite("接收核心：排序、丢包、发送端切换")
struct ReceiverCoreTests {
    /// 最后一部分数据会因为插值需要的前瞻帧和缓冲耗尽而不输出，比对时避开
    let lastComparedFrame = 40 * 240 - 600

    @Test("按顺序到达：输出与输入逐样本一致")
    func inOrderIsBitExact() throws {
        var harness = SteadyHarness(core: makeCore())
        harness.run(order: Array(0..<40))

        let anchor = try #require(outputIndex(ofFrame: 300, in: harness.left))
        let range = 300..<lastComparedFrame
        #expect(mismatches(harness.left, anchor: anchor, anchorFrame: 300, frames: range,
                           expected: PacketFactory.expectedLeft) == 0)
        #expect(mismatches(harness.right, anchor: anchor, anchorFrame: 300, frames: range,
                           expected: PacketFactory.expectedRight) == 0)

        let stats = harness.core.statistics(now: harness.time)
        #expect(stats.packetsReceived == 40)
        #expect(stats.packetsLost == 0)
        #expect(stats.packetsLate == 0)
        #expect(stats.format == StreamFormat(sampleRate: 48_000, channels: 2))
    }

    @Test("乱序到达：重新排好，不算丢包")
    func reorderedPacketsAreRestored() throws {
        var order = Array(0..<40)
        order.swapAt(20, 21)
        order.swapAt(31, 33)
        var harness = SteadyHarness(core: makeCore())
        harness.run(order: order)

        let anchor = try #require(outputIndex(ofFrame: 300, in: harness.left))
        #expect(mismatches(harness.left, anchor: anchor, anchorFrame: 300, frames: 300..<lastComparedFrame,
                           expected: PacketFactory.expectedLeft) == 0)
        let stats = harness.core.statistics(now: harness.time)
        #expect(stats.packetsLost == 0)
        #expect(stats.packetsLate == 0)
    }

    @Test("丢一个包：这段补静音，前后数据不受影响")
    func lostPacketIsConcealed() throws {
        let order = Array(0..<40).map { $0 == 20 ? -1 : $0 }
        var harness = SteadyHarness(core: makeCore())
        harness.run(order: order)

        let anchor = try #require(outputIndex(ofFrame: 300, in: harness.left))
        let gap = (20 * 240)..<(21 * 240)
        // 缺口前（除了最后 64 帧的淡出）和缺口后（除了开头 64 帧的淡入）都应逐样本一致
        #expect(mismatches(harness.left, anchor: anchor, anchorFrame: 300, frames: 300..<(gap.lowerBound - 64),
                           expected: PacketFactory.expectedLeft) == 0)
        #expect(mismatches(harness.left, anchor: anchor, anchorFrame: 300,
                           frames: (gap.upperBound + 64)..<lastComparedFrame,
                           expected: PacketFactory.expectedLeft) == 0)
        // 缺口本身是静音
        #expect(mismatches(harness.left, anchor: anchor, anchorFrame: 300, frames: gap, expected: { _ in 0 }) == 0)

        let stats = harness.statsAfterDelivery
        #expect(stats.packetsLost == 1)
        #expect(stats.concealedFrames == 240)
        #expect(stats.underruns == 0)
    }

    @Test("判为丢失之后才到的包记为迟到，重复的包也记为迟到")
    func lateAndDuplicatePacketsAreCounted() {
        // 20 号包在 21–24 之后才到；10 号包来了两次
        var order = Array(0..<40).filter { $0 != 20 }
        order.insert(20, at: order.firstIndex(of: 25)!)
        order.insert(10, at: order.firstIndex(of: 11)!)
        var harness = SteadyHarness(core: makeCore())
        harness.run(order: order)

        let stats = harness.core.statistics(now: harness.time)
        #expect(stats.packetsLost == 1)
        #expect(stats.packetsLate == 2)
    }

    @Test("正在接收时忽略其他发送端，当前发送端超时后才切换")
    func foreignSenderWaitsForTimeout() {
        let core = makeCore()
        var started: [StreamFormat] = []
        core.onStreamStarted = { started.append($0) }
        let a = PacketFactory(streamID: 1)
        let b = PacketFactory(streamID: 2, sampleRate: 44_100)

        #expect(core.ingest(a.packet(0), from: "10.0.0.2", at: 0) == .accepted)
        #expect(core.ingest(b.packet(0), from: "10.0.0.3", at: 0.01) == .ignored)
        core.housekeeping(now: 0.5)
        #expect(core.statistics(now: 0.5).state == .buffering)
        core.housekeeping(now: 2.0)
        #expect(core.statistics(now: 2.0).state == .idle)
        #expect(core.ingest(b.packet(1), from: "10.0.0.3", at: 2.0) == .accepted)

        let stats = core.statistics(now: 2.0)
        #expect(stats.senderAddress == "10.0.0.3")
        #expect(stats.packetsIgnored == 1)
        #expect(started == [StreamFormat(sampleRate: 48_000, channels: 2), StreamFormat(sampleRate: 44_100, channels: 2)])
    }

    @Test("同一台电脑重启发送端（新 streamId）立刻切换")
    func sameSenderRestartSwitchesImmediately() {
        let core = makeCore()
        var starts = 0
        core.onStreamStarted = { _ in starts += 1 }
        core.ingest(PacketFactory(streamID: 1).packet(0), at: 0)
        #expect(core.ingest(PacketFactory(streamID: 2).packet(0), at: 0.01) == .accepted)
        #expect(starts == 2)
    }

    @Test("格式不对的包被拒绝并计数")
    func garbageIsRejected() {
        let core = makeCore()
        #expect(core.ingest([1, 2, 3], at: 0) == .rejected)
        #expect(core.statistics(now: 0).packetsRejected == 1)
    }

    @Test("网络中断 300 ms：记一次欠载，之后恢复播放")
    func recoversFromUnderrun() throws {
        let order = Array(0..<30) + Array(repeating: -1, count: 60) + Array(30..<70)
        var harness = SteadyHarness(core: makeCore())
        harness.run(order: order)

        let stats = harness.statsAfterDelivery
        #expect(stats.underruns == 1)
        #expect(stats.packetsLost == 0)
        // 恢复之后的数据照常播放
        let anchor = try #require(outputIndex(ofFrame: 40 * 240, in: harness.left))
        #expect(mismatches(harness.left, anchor: anchor, anchorFrame: 40 * 240, frames: (40 * 240)..<(60 * 240),
                           expected: PacketFactory.expectedLeft) == 0)
    }

    @Test("音量和静音只作用在远端声音上")
    func gainAndMute() throws {
        let core = makeCore()
        core.setGain(0.5)
        var harness = SteadyHarness(core: core)
        harness.run(order: Array(0..<40))
        let anchor = try #require(outputIndex(ofFrame: 300, in: harness.left.map { $0 * 2 }))
        #expect(mismatches(harness.left, anchor: anchor, anchorFrame: 300, frames: 300..<lastComparedFrame,
                           expected: { PacketFactory.expectedLeft($0) * 0.5 }) == 0)

        let muted = makeCore()
        muted.setMuted(true)
        var silent = SteadyHarness(core: muted)
        silent.run(order: Array(0..<40))
        #expect(silent.left.allSatisfy { $0 == 0 })
    }
}
