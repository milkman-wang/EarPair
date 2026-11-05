import EarPairCore
import Foundation

/// 生成测试包。默认样本值由帧序号决定（3 万帧内不重复），方便逐样本比对；也可以改发静音或正弦。
struct PacketFactory {
    var streamID: UInt32 = 0x4541_5250
    var sampleRate: UInt32 = 48_000
    var framesPerPacket = 240
    var silent = false
    /// 设置后改发正弦（频率 Hz，幅度 0…1，左右相同）
    var sine: (frequency: Double, amplitude: Double)?

    static func samples(atFrame f: Int) -> (left: Int16, right: Int16) {
        (Int16((f * 7) % 30_000 - 15_000), Int16(15_000 - (f * 11) % 30_000))
    }

    static func expectedLeft(_ f: Int) -> Float { Float(samples(atFrame: f).left) / 32768 }
    static func expectedRight(_ f: Int) -> Float { Float(samples(atFrame: f).right) / 32768 }

    func packet(_ index: Int) -> [UInt8] {
        let first = index * framesPerPacket
        var samples: [Int16] = []
        samples.reserveCapacity(framesPerPacket * 2)
        for f in first..<(first + framesPerPacket) {
            let value: (left: Int16, right: Int16)
            if silent {
                value = (0, 0)
            } else if let sine {
                let phase = 2 * Double.pi * sine.frequency * Double(f) / Double(sampleRate)
                let v = Int16((sine.amplitude * sin(phase) * 32767).rounded())
                value = (v, v)
            } else {
                value = Self.samples(atFrame: f)
            }
            samples.append(value.left)
            samples.append(value.right)
        }
        let header = PacketHeader(streamID: streamID, sequence: UInt32(truncatingIfNeeded: index),
                                  sampleTime: UInt64(first), sampleRate: sampleRate,
                                  frameCount: UInt16(framesPerPacket))
        return PacketHeader.encode(header, samples: samples)
    }
}

extension ReceiverCore {
    @discardableResult
    func ingest(_ bytes: [UInt8], from sender: String = "10.0.0.2", at now: Double) -> IngestResult {
        bytes.withUnsafeBytes { ingest($0, from: sender, at: now) }
    }

    func renderStereo(_ frames: Int) -> (left: [Float], right: [Float]) {
        var left = [Float](repeating: .nan, count: frames)
        var right = [Float](repeating: .nan, count: frames)
        left.withUnsafeMutableBufferPointer { l in
            right.withUnsafeMutableBufferPointer { r in
                _ = render(left: l.baseAddress!, right: r.baseAddress!, frames: frames)
            }
        }
        return (left, right)
    }
}

func makeCore(driftCompensation: Bool = false) -> ReceiverCore {
    var config = ReceiverCore.Configuration()
    config.driftCompensation = driftCompensation
    let core = ReceiverCore(configuration: config)
    core.setOutputSampleRate(48_000)
    return core
}

/// 模拟稳定的节奏：每 10 ms 收到两个包、渲染 480 帧。
struct SteadyHarness {
    let core: ReceiverCore
    var factory = PacketFactory()
    var left: [Float] = []
    var right: [Float] = []
    var time = 0.0
    /// 最后一个包投递完、数据还没播完时的统计（之后数据播完，自然会记一次欠载）
    var statsAfterDelivery = ReceiverStats()

    init(core: ReceiverCore) { self.core = core }

    /// 按 `order` 的顺序投递包（-1 表示这个位置什么都不来），投递完再多渲染 `tailSteps` 步。
    mutating func run(order: [Int], tailSteps: Int = 25) {
        var i = 0
        while i < order.count {
            for _ in 0..<2 where i < order.count {
                if order[i] >= 0 { core.ingest(factory.packet(order[i]), at: time) }
                i += 1
            }
            step()
        }
        statsAfterDelivery = core.statistics(now: time)
        for _ in 0..<tailSteps { step() }
    }

    mutating func step() {
        let block = core.renderStereo(480)
        left += block.left
        right += block.right
        time += 0.010
    }
}

/// 在输出里找到第 `frame` 帧的位置（用连续两帧的值定位）。
func outputIndex(ofFrame frame: Int, in output: [Float], tolerance: Float = 0) -> Int? {
    let a = PacketFactory.expectedLeft(frame)
    let b = PacketFactory.expectedLeft(frame + 1)
    guard output.count > 1 else { return nil }
    for i in 0..<(output.count - 1) where abs(output[i] - a) <= tolerance && abs(output[i + 1] - b) <= tolerance {
        return i
    }
    return nil
}

/// 统计 `frames` 范围内与期望值不一致的样本数。`anchor` 是第 `anchorFrame` 帧在输出里的位置。
func mismatches(_ output: [Float], anchor: Int, anchorFrame: Int, frames: Range<Int>,
                expected: (Int) -> Float, tolerance: Float = 0) -> Int {
    var count = 0
    for f in frames {
        let index = anchor + (f - anchorFrame)
        if index < 0 || index >= output.count || abs(output[index] - expected(f)) > tolerance { count += 1 }
    }
    return count
}

/// 确定性的随机数发生器（SplitMix64），让模拟结果可重复。
struct SeededRandom: RandomNumberGenerator {
    var state: UInt64

    mutating func next() -> UInt64 {
        state &+= 0x9E37_79B9_7F4A_7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        return z ^ (z >> 31)
    }
}
