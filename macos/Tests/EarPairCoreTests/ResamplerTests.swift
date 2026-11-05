import EarPairCore
import Foundation
import Testing

@Suite("变速插值")
struct ResamplerTests {
    /// 用给定速度比把交错立体声 `input` 按 `block` 帧一块地读出来，返回左声道。
    func resample(_ input: [Float], ratio: Double, block: Int, outputFrames: Int) -> [Float] {
        var resampler = DriftResampler()
        var output = [Float](repeating: 0, count: outputFrames)
        var right = [Float](repeating: 0, count: block)
        var readFrame = 0
        var written = 0
        input.withUnsafeBufferPointer { source in
            while written + block <= outputFrames {
                let need = DriftResampler.requirement(phase: resampler.phase, outputFrames: block, ratio: ratio)
                precondition((readFrame + need.needed) * 2 <= input.count)
                output.withUnsafeMutableBufferPointer { out in
                    right.withUnsafeMutableBufferPointer { r in
                        resampler.process(input: source.baseAddress! + readFrame * 2, outputFrames: block,
                                          ratio: ratio, left: out.baseAddress! + written, right: r.baseAddress!)
                    }
                }
                readFrame += need.consumed
                written += block
            }
        }
        return output
    }

    @Test("速度比为 1 时输出与输入完全相同")
    func unityRatioIsIdentity() {
        let frames = 5000
        var input = [Float](repeating: 0, count: frames * 2)
        for f in 0..<frames {
            input[f * 2] = Float(f % 977) / 977
            input[f * 2 + 1] = -Float(f % 613) / 613
        }
        let output = resample(input, ratio: 1, block: 256, outputFrames: 4096)
        #expect((0..<4096).allSatisfy { output[$0] == input[$0 * 2] })
    }

    @Test("速度比 1.002 时，1 kHz 正弦的插值误差小于 1e-3", arguments: [1.002, 0.998, 1.0001])
    func tracksSineAtOffsetRatio(ratio: Double) {
        let omega = 2 * Double.pi * 1000 / 48_000
        let frames = 12_000
        var input = [Float](repeating: 0, count: frames * 2)
        for f in 0..<frames {
            let value = Float(sin(omega * Double(f)))
            input[f * 2] = value
            input[f * 2 + 1] = value
        }
        let output = resample(input, ratio: ratio, block: 512, outputFrames: 10_240)
        var worst: Float = 0
        // 前几帧用到的"前一帧"是 0，跳过
        for k in 8..<output.count {
            let ideal = Float(sin(omega * Double(k) * ratio))
            worst = max(worst, abs(output[k] - ideal))
        }
        #expect(worst < 1e-3, "最大误差 \(worst)")
    }
}
