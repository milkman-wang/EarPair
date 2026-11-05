import EarPairCore
import Foundation
import Testing

/// 按稳定节奏投递包并渲染：每 10 ms 两个包、480 帧。
struct ToneRun {
    let core: ReceiverCore
    var factory = PacketFactory()
    var left: [Float] = []
    var right: [Float] = []
    var nextPacket = 0
    var time = 0.0

    init(core: ReceiverCore) { self.core = core }

    mutating func play(seconds: Double) {
        for _ in 0..<Int(seconds * 100) {
            for _ in 0..<2 {
                core.ingest(factory.packet(nextPacket), at: time)
                nextPacket += 1
            }
            let block = core.renderStereo(480)
            left += block.left
            right += block.right
            time += 0.010
        }
    }

    /// 最近 `seconds` 秒输出的峰值
    func recentPeak(_ channel: [Float], seconds: Double) -> Float {
        channel.suffix(Int(seconds * 48_000)).reduce(0) { max($0, abs($1)) }
    }
}

func decibels(_ value: Float) -> Double { 20 * log10(Double(value)) }

func levelingCore(autoLevel: Bool) -> ReceiverCore {
    var config = ReceiverCore.Configuration()
    config.autoLevel = autoLevel
    config.targetLoudness = -16
    config.driftCompensation = false
    let core = ReceiverCore(configuration: config)
    core.setOutputSampleRate(48_000)
    return core
}

@Suite("音量平衡、限幅、左右平衡")
struct LevelingTests {
    // 立体声 1 kHz 正弦的响度（LUFS）约等于 20·log10(幅度)，所以 −16 LUFS 对应峰值约 0.158

    @Test("把 −30 dBFS 的小声拉到目标响度 −16 LUFS")
    func raisesQuietSignal() {
        var run = ToneRun(core: levelingCore(autoLevel: true))
        run.factory.sine = (1000, 0.0316)
        run.play(seconds: 15)

        let peak = run.recentPeak(run.left, seconds: 2)
        #expect(abs(decibels(peak) - (-16)) < 1, "输出峰值 \(decibels(peak)) dBFS")
        let stats = run.core.statistics(now: run.time)
        #expect(abs(stats.levelingGainDB - 14) < 1, "增益 \(stats.levelingGainDB) dB")
        #expect(abs((stats.loudnessLUFS ?? 0) - (-30)) < 1, "响度 \(stats.loudnessLUFS ?? .nan) LUFS")
        #expect(abs(stats.inputLevelDB - (-30)) < 0.5, "输入电平 \(stats.inputLevelDB) dBFS")
        #expect(abs(stats.outputLevelDB - (-16)) < 1, "输出电平 \(stats.outputLevelDB) dBFS")
    }

    @Test("把 −4 dBFS 的大声压到目标响度")
    func lowersLoudSignal() {
        var run = ToneRun(core: levelingCore(autoLevel: true))
        run.factory.sine = (1000, 0.63)
        run.play(seconds: 10)
        let peak = run.recentPeak(run.left, seconds: 2)
        #expect(abs(decibels(peak) - (-16)) < 1, "输出峰值 \(decibels(peak)) dBFS")
    }

    @Test("中间停 10 秒静音：增益不变，恢复时不会突然很响")
    func silenceHoldsGain() {
        var run = ToneRun(core: levelingCore(autoLevel: true))
        run.factory.sine = (1000, 0.0316)
        run.play(seconds: 12)
        let before = run.core.statistics(now: run.time).levelingGainDB

        run.factory.silent = true
        run.play(seconds: 10)
        let during = run.core.statistics(now: run.time).levelingGainDB
        #expect(abs(during - before) < 0.5, "静音前 \(before) dB，静音后 \(during) dB")

        run.factory.silent = false
        run.play(seconds: 0.5)
        let peak = run.recentPeak(run.left, seconds: 0.4)
        #expect(decibels(peak) < -15, "恢复后峰值 \(decibels(peak)) dBFS")
    }

    @Test("关闭音量平衡时不改变音量")
    func offMeansUnity() {
        var run = ToneRun(core: levelingCore(autoLevel: false))
        run.factory.sine = (1000, 0.0316)
        run.play(seconds: 5)
        let peak = run.recentPeak(run.left, seconds: 2)
        #expect(abs(decibels(peak) - (-30)) < 0.1)
        #expect(run.core.statistics(now: run.time).levelingGainDB == 0)
    }

    @Test("音量开到 200%：限幅器把峰值压在 −1 dBFS 以下")
    func limiterHoldsCeiling() {
        let core = levelingCore(autoLevel: false)
        core.setGain(2)
        var run = ToneRun(core: core)
        run.factory.sine = (1000, 0.9)
        run.play(seconds: 3)
        let peak = max(run.recentPeak(run.left, seconds: 2), run.recentPeak(run.right, seconds: 2))
        #expect(peak <= 0.8911, "峰值 \(peak)")
        #expect(peak > 0.85)
        #expect(core.statistics(now: run.time).isLimiting)
    }

    @Test("左右平衡：拉到最左时右边静音，左边不变；拉到 +0.5 时左边减半")
    func balance() throws {
        let core = makeCore()
        core.setBalance(-1)
        var harness = SteadyHarness(core: core)
        harness.run(order: Array(0..<40))
        let anchor = try #require(outputIndex(ofFrame: 300, in: harness.left))
        #expect(mismatches(harness.left, anchor: anchor, anchorFrame: 300, frames: 300..<9000,
                           expected: PacketFactory.expectedLeft) == 0)
        #expect(harness.right.allSatisfy { $0 == 0 })

        let halfLeft = makeCore()
        halfLeft.setBalance(0.5)
        var second = SteadyHarness(core: halfLeft)
        second.run(order: Array(0..<40))
        let anchorRight = try #require(outputIndexRight(ofFrame: 300, in: second.right))
        #expect(mismatches(second.left, anchor: anchorRight, anchorFrame: 300, frames: 300..<9000,
                           expected: { PacketFactory.expectedLeft($0) * 0.5 }) == 0)
    }
}

/// 用右声道定位第 `frame` 帧
func outputIndexRight(ofFrame frame: Int, in output: [Float]) -> Int? {
    let a = PacketFactory.expectedRight(frame)
    let b = PacketFactory.expectedRight(frame + 1)
    guard output.count > 1 else { return nil }
    for i in 0..<(output.count - 1) where output[i] == a && output[i + 1] == b { return i }
    return nil
}
