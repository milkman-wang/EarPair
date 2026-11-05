/// 交错立体声 Float 环形缓冲。本身不加锁，只在 ReceiverCore 的锁内使用。
final class StereoRing {
    /// 容量（帧）
    let capacity: Int
    private let samples: UnsafeMutablePointer<Float>
    // 两个下标都是单调递增的帧计数，取模后才是存储位置
    private var readIndex = 0
    private var writeIndex = 0

    init(capacity: Int) {
        precondition(capacity > 0)
        self.capacity = capacity
        samples = .allocate(capacity: capacity * 2)
        samples.initialize(repeating: 0, count: capacity * 2)
    }

    deinit { samples.deallocate() }

    /// 已缓冲、还没播放的帧数
    var count: Int { writeIndex - readIndex }

    func clear() { readIndex = writeIndex }

    /// 写入 `frames` 帧。空间不够时先丢掉最旧的数据，返回丢掉的帧数。
    @discardableResult
    func write(_ source: UnsafePointer<Float>, frames: Int) -> Int {
        precondition(frames <= capacity)
        let dropped = makeRoom(for: frames)
        var done = 0
        while done < frames {
            let position = (writeIndex + done) % capacity
            let n = min(frames - done, capacity - position)
            (samples + position * 2).update(from: source + done * 2, count: n * 2)
            done += n
        }
        writeIndex += frames
        return dropped
    }

    /// 写入 `frames` 帧静音，返回因空间不够丢掉的帧数。
    @discardableResult
    func writeSilence(frames: Int) -> Int {
        let frames = min(frames, capacity)
        let dropped = makeRoom(for: frames)
        var done = 0
        while done < frames {
            let position = (writeIndex + done) % capacity
            let n = min(frames - done, capacity - position)
            (samples + position * 2).update(repeating: 0, count: n * 2)
            done += n
        }
        writeIndex += frames
        return dropped
    }

    /// 给最近写入、还没播放的最多 `frames` 帧做线性淡出（用于丢包前，避免爆音）。
    func fadeOutNewest(frames: Int) {
        let n = min(frames, count)
        guard n > 0 else { return }
        for j in 0..<n {
            let position = (writeIndex - n + j) % capacity
            let gain = Float(n - 1 - j) / Float(n)
            samples[position * 2] *= gain
            samples[position * 2 + 1] *= gain
        }
    }

    /// 把最旧的 `frames` 帧复制到 `destination`（不消耗）。调用方保证 count >= frames。
    func peek(into destination: UnsafeMutablePointer<Float>, frames: Int) {
        precondition(frames <= count)
        var done = 0
        while done < frames {
            let position = (readIndex + done) % capacity
            let n = min(frames - done, capacity - position)
            (destination + done * 2).update(from: samples + position * 2, count: n * 2)
            done += n
        }
    }

    /// 丢弃最旧的 `frames` 帧
    func discard(frames: Int) {
        readIndex += min(frames, count)
    }

    private func makeRoom(for frames: Int) -> Int {
        let overflow = count + frames - capacity
        guard overflow > 0 else { return 0 }
        readIndex += overflow
        return overflow
    }
}
