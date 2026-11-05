import EarPairCore
import Foundation

/// 不出声的"声卡"：按实时节奏（可以模拟时钟偏差）从 ReceiverCore 拉数据，可选录下来。用于测试。
final class NullOutput: @unchecked Sendable {
    let sampleRate: Double
    private let core: ReceiverCore
    private let clockPPM: Double
    private let recording: Bool
    private let blockFrames = 512
    private let lock = NSLock()
    private var running = false
    private var recorded: [Int16] = []
    private let finished = DispatchSemaphore(value: 0)

    init(core: ReceiverCore, sampleRate: Double, clockPPM: Double, recording: Bool) {
        self.core = core
        self.sampleRate = sampleRate
        self.clockPPM = clockPPM
        self.recording = recording
    }

    func start() {
        lock.withLock { running = true }
        let thread = Thread { [self] in loop() }
        thread.name = "EarPair null output"
        thread.qualityOfService = .userInteractive
        thread.start()
    }

    /// 停止并等渲染线程退出
    func stop() {
        let wasRunning = lock.withLock { () -> Bool in
            defer { running = false }
            return running
        }
        if wasRunning { finished.wait() }
    }

    func writeWAV(to path: String) throws {
        let samples = lock.withLock { recorded }
        try WAVWriter.write(samples: samples, channels: 2, sampleRate: Int(sampleRate),
                            to: URL(fileURLWithPath: path))
    }

    private var isRunning: Bool { lock.withLock { running } }

    private func loop() {
        let left = UnsafeMutablePointer<Float>.allocate(capacity: blockFrames)
        let right = UnsafeMutablePointer<Float>.allocate(capacity: blockFrames)
        defer {
            left.deallocate()
            right.deallocate()
            finished.signal()
        }
        // 每块的间隔按"本机声卡时钟"计算；clockPPM > 0 表示本机比标称快
        let period = Double(blockFrames) / (sampleRate * (1 + clockPPM / 1e6))
        var deadline = MonotonicClock.now()
        while isRunning {
            core.render(left: left, right: right, frames: blockFrames)
            if recording {
                lock.withLock {
                    for i in 0..<blockFrames {
                        recorded.append(Self.toInt16(left[i]))
                        recorded.append(Self.toInt16(right[i]))
                    }
                }
            }
            deadline += period
            let wait = deadline - MonotonicClock.now()
            if wait > 0 { Thread.sleep(forTimeInterval: wait) }
        }
    }

    private static func toInt16(_ sample: Float) -> Int16 {
        Int16(max(-32768, min(32767, (sample * 32768).rounded())))
    }
}

enum WAVWriter {
    /// 写 16-bit PCM WAV（样本交错）。
    static func write(samples: [Int16], channels: Int, sampleRate: Int, to url: URL) throws {
        var data = Data()
        func append<T: FixedWidthInteger>(_ value: T) {
            withUnsafeBytes(of: value.littleEndian) { data.append(contentsOf: $0) }
        }
        let dataSize = samples.count * 2
        data.append(contentsOf: Array("RIFF".utf8))
        append(UInt32(36 + dataSize))
        data.append(contentsOf: Array("WAVEfmt ".utf8))
        append(UInt32(16))
        append(UInt16(1))  // PCM
        append(UInt16(channels))
        append(UInt32(sampleRate))
        append(UInt32(sampleRate * channels * 2))
        append(UInt16(channels * 2))
        append(UInt16(16))
        data.append(contentsOf: Array("data".utf8))
        append(UInt32(dataSize))
        for sample in samples { append(sample) }
        try data.write(to: url)
    }
}
