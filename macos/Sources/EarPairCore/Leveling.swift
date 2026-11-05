import Foundation

/// 双二阶滤波器（转置直接 II 型）。
struct Biquad: Sendable {
    private var b0 = 1.0, b1 = 0.0, b2 = 0.0, a1 = 0.0, a2 = 0.0
    private var z1 = 0.0, z2 = 0.0

    init() {}

    init(b0: Double, b1: Double, b2: Double, a0: Double, a1: Double, a2: Double) {
        self.b0 = b0 / a0
        self.b1 = b1 / a0
        self.b2 = b2 / a0
        self.a1 = a1 / a0
        self.a2 = a2 / a0
    }

    @inline(__always)
    mutating func process(_ x: Double) -> Double {
        let y = b0 * x + z1
        z1 = b1 * x - a1 * y + z2
        z2 = b2 * x - a2 * y
        return y
    }

    /// RBJ 高架滤波器
    static func highShelf(sampleRate: Double, frequency: Double, gainDB: Double, q: Double) -> Biquad {
        let a = pow(10, gainDB / 40)
        let w0 = 2 * Double.pi * frequency / sampleRate
        let cosine = cos(w0)
        let twoSqrtAAlpha = 2 * sqrt(a) * sin(w0) / (2 * q)
        return Biquad(
            b0: a * ((a + 1) + (a - 1) * cosine + twoSqrtAAlpha),
            b1: -2 * a * ((a - 1) + (a + 1) * cosine),
            b2: a * ((a + 1) + (a - 1) * cosine - twoSqrtAAlpha),
            a0: (a + 1) - (a - 1) * cosine + twoSqrtAAlpha,
            a1: 2 * ((a - 1) - (a + 1) * cosine),
            a2: (a + 1) - (a - 1) * cosine - twoSqrtAAlpha)
    }

    /// RBJ 高通滤波器
    static func highPass(sampleRate: Double, frequency: Double, q: Double) -> Biquad {
        let w0 = 2 * Double.pi * frequency / sampleRate
        let cosine = cos(w0)
        let alpha = sin(w0) / (2 * q)
        return Biquad(b0: (1 + cosine) / 2, b1: -(1 + cosine), b2: (1 + cosine) / 2,
                      a0: 1 + alpha, a1: -2 * cosine, a2: 1 - alpha)
    }
}

/// 音量平衡：用 BS.1770 的 K 计权估计听感响度（LUFS），把增益慢慢调到让响度接近目标值。
/// 不同电脑、声卡、内容的音量差别由它抹平。静音时不调整，增益变化有速度上限，避免忽大忽小。
public struct LoudnessLeveler: Sendable {
    public var targetLUFS = -16.0
    public var maxBoostDB = 15.0
    public var maxCutDB = 12.0
    /// 增益上调 / 下调的最快速度（dB/秒）
    public var riseRate = 2.0
    public var fallRate = 8.0
    /// 低于这个响度当作静音，不更新估计
    public var gateLUFS = -50.0
    /// 响度估计的时间常数（秒）
    public var integrationTime = 2.0

    public private(set) var gainDB = 0.0
    public private(set) var loudnessLUFS: Double?

    private var meanSquare: Double?
    private var sampleRate = 0.0
    private var shelfLeft = Biquad(), passLeft = Biquad()
    private var shelfRight = Biquad(), passRight = Biquad()

    public init() {}

    /// 新的流开始时调用：按采样率重算 K 计权滤波器。保留已经学到的增益。
    public mutating func prepare(sampleRate: Double) {
        self.sampleRate = sampleRate
        // 这组参数在 48 kHz 下与 BS.1770 给出的系数一致，其他采样率按同样的模拟原型换算
        let shelf = Biquad.highShelf(sampleRate: sampleRate, frequency: 1681.9744509555319,
                                     gainDB: 3.99984385397, q: 0.7071752369554193)
        let pass = Biquad.highPass(sampleRate: sampleRate, frequency: 38.13547087613982, q: 0.5003270373253953)
        shelfLeft = shelf
        shelfRight = shelf
        passLeft = pass
        passRight = pass
    }

    /// 分析一块（增益之前的）信号，更新增益，返回这一块结束时应达到的线性增益。
    public mutating func process(left: UnsafePointer<Float>, right: UnsafePointer<Float>, frames: Int) -> Float {
        guard sampleRate > 0, frames > 0 else { return Float(pow(10, gainDB / 20)) }
        var sum = 0.0
        for i in 0..<frames {
            let l = passLeft.process(shelfLeft.process(Double(left[i])))
            let r = passRight.process(shelfRight.process(Double(right[i])))
            sum += l * l + r * r
        }
        let blockMeanSquare = sum / Double(frames)
        let dt = Double(frames) / sampleRate
        if -0.691 + 10 * log10(blockMeanSquare + 1e-20) > gateLUFS {
            let smoothed: Double
            if let previous = meanSquare {
                smoothed = previous + (1 - exp(-dt / integrationTime)) * (blockMeanSquare - previous)
            } else {
                smoothed = blockMeanSquare
            }
            meanSquare = smoothed
            let loudness = -0.691 + 10 * log10(smoothed)
            loudnessLUFS = loudness
            let desired = min(max(targetLUFS - loudness, -maxCutDB), maxBoostDB)
            if desired > gainDB {
                gainDB = min(desired, gainDB + riseRate * dt)
            } else {
                gainDB = max(desired, gainDB - fallRate * dt)
            }
        }
        return Float(pow(10, gainDB / 20))
    }
}

/// 峰值限幅：超过上限的样本立刻压到上限，随后平滑恢复，防止调大音量后爆音。
/// 信号没超过上限时完全不改动样本。
public struct PeakLimiter: Sendable {
    /// 上限，默认 −1 dBFS
    public var ceiling: Float = 0.891
    public var releaseTime = 0.1
    private var envelope: Float = 1
    private var releaseCoefficient: Float = 0.0002

    public init() {}

    public mutating func prepare(sampleRate: Double) {
        releaseCoefficient = Float(1 - exp(-1 / (releaseTime * sampleRate)))
    }

    /// 就地处理一帧，返回这一帧是否被压缩了
    @inline(__always)
    public mutating func process(_ left: inout Float, _ right: inout Float) -> Bool {
        let peak = max(abs(left), abs(right))
        let allowed: Float = peak > ceiling ? ceiling / peak : 1
        var next = envelope + (1 - envelope) * releaseCoefficient
        if next > 0.99999 { next = 1 }
        envelope = min(next, allowed)
        guard envelope < 1 else { return false }
        left *= envelope
        right *= envelope
        return true
    }
}
