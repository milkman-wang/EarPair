/// 变速读取器：每输出一帧，输入前进 `ratio` 帧（ratio ≈ 1），用 4 点三次 Hermite（Catmull-Rom）插值。
/// ratio == 1 且相位为 0 时，输出与输入逐样本完全相同。
public struct DriftResampler: Sendable {
    /// 下一个输出帧相对于缓冲读位置的小数偏移，范围 [0, 1)
    public private(set) var phase: Double = 0
    // 缓冲读位置之前的那一帧，插值时要用到
    private var previousLeft: Float = 0
    private var previousRight: Float = 0

    public init() {}

    public mutating func reset() {
        phase = 0
        previousLeft = 0
        previousRight = 0
    }

    /// 输出 `outputFrames` 帧时，需要从缓冲里看到的帧数（needed）和实际消耗的帧数（consumed）。
    public static func requirement(phase: Double, outputFrames: Int, ratio: Double) -> (needed: Int, consumed: Int) {
        let consumed = Int((phase + Double(outputFrames) * ratio).rounded(.down))
        return (consumed + 3, consumed)
    }

    /// `input` 是交错立体声，至少有 `requirement(...).needed` 帧。
    public mutating func process(input: UnsafePointer<Float>, outputFrames n: Int, ratio: Double,
                                 left: UnsafeMutablePointer<Float>, right: UnsafeMutablePointer<Float>) {
        let consumed = Self.requirement(phase: phase, outputFrames: n, ratio: ratio).consumed
        let startPhase = phase
        for k in 0..<n {
            let position = startPhase + Double(k) * ratio
            let i = Int(position)  // position >= 0，截断即向下取整
            let t = Float(position - Double(i))
            let b = i * 2
            let beforeLeft = i == 0 ? previousLeft : input[b - 2]
            let beforeRight = i == 0 ? previousRight : input[b - 1]
            left[k] = Self.hermite(beforeLeft, input[b], input[b + 2], input[b + 4], t)
            right[k] = Self.hermite(beforeRight, input[b + 1], input[b + 3], input[b + 5], t)
        }
        if consumed > 0 {
            previousLeft = input[(consumed - 1) * 2]
            previousRight = input[(consumed - 1) * 2 + 1]
        }
        phase = startPhase + Double(n) * ratio - Double(consumed)
    }

    @inline(__always)
    static func hermite(_ xm1: Float, _ x0: Float, _ x1: Float, _ x2: Float, _ t: Float) -> Float {
        let c1 = 0.5 * (x1 - xm1)
        let c2 = xm1 - 2.5 * x0 + 2 * x1 - 0.5 * x2
        let c3 = 0.5 * (x2 - xm1) + 1.5 * (x0 - x1)
        return ((c3 * t + c2) * t + c1) * t + x0
    }
}
