import Foundation

/// 根据缓冲水位微调播放速度，抵消发送端和本机声卡的时钟差。
///
/// PI 控制：误差 = 平滑后的缓冲时长 − 目标时长（秒）。返回的 ratio > 1 表示比标称速度略快地消耗缓冲。
/// 默认参数下闭环自然频率约 0.1 rad/s、阻尼约 0.8：几十秒内收敛，不会让音高来回晃。
public struct DriftController: Sendable {
    public var proportionalGain = 0.16
    public var integralGain = 0.01
    /// 播放速度最多偏离 ±0.2%（约 3.5 音分，基本听不出来）
    public var maxDeviation = 0.002
    /// 缓冲水位的低通时间常数（秒），用来滤掉按包到达造成的锯齿
    public var levelSmoothing = 0.5
    /// （重新）开始后先只用比例控制这么多秒，等水位稳住再积分。
    /// 否则开播那一刻的水位波动会被积分成一个假的时钟偏差，要几十秒才消掉。
    public var integralHold = 5.0

    private var smoothedLevel: Double?
    private var integral = 0.0
    private var holdRemaining = 5.0
    public private(set) var ratio = 1.0

    public init() {}

    public mutating func reset() {
        smoothedLevel = nil
        integral = 0
        ratio = 1
        holdRemaining = integralHold
    }

    /// 缓冲被整体丢弃或清空后调用：重置水位滤波，暂停一会儿积分，保留已经学到的时钟偏差。
    public mutating func resetLevel() {
        smoothedLevel = nil
        holdRemaining = integralHold
    }

    /// 长期时钟偏差估计（ppm）。正数表示发送端比本机快。
    public var estimatedPPM: Double { integral * integralGain * 1e6 }

    public mutating func update(levelFrames: Int, targetFrames: Int, blockFrames: Int, sampleRate: Double) -> Double {
        let dt = Double(blockFrames) / sampleRate
        let level = Double(levelFrames) / sampleRate
        let target = Double(targetFrames) / sampleRate

        let smoothed: Double
        if let previous = smoothedLevel {
            smoothed = previous + (1 - exp(-dt / levelSmoothing)) * (level - previous)
        } else {
            smoothed = level
        }
        smoothedLevel = smoothed

        let error = smoothed - target
        if holdRemaining > 0 {
            holdRemaining -= dt
        } else {
            let integralLimit = maxDeviation / integralGain
            integral = min(max(integral + error * dt, -integralLimit), integralLimit)
        }

        let correction = proportionalGain * error + integralGain * integral
        ratio = 1 + min(max(correction, -maxDeviation), maxDeviation)
        return ratio
    }
}
