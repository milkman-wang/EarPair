import AVFoundation
import EarPairCore
import Testing

@Suite("空间音频：校准")
struct SpatialCalibrationTests {
    /// 50 Hz 喂一段：朝向 heading、角速度 speed，持续 seconds 秒
    private func hold(_ c: inout SpatialCalibration, from start: Double, seconds: Double, heading: Double,
                      speed: Double = 1) -> Double {
        var t = start
        while t < start + seconds {
            c.feed(time: t, heading: heading, speed: speed)
            t += 0.02
        }
        return t
    }

    @Test("先稳住看 Mac，再转过去稳住看发送端：两个方向都记下")
    func capturesBothScreens() {
        var c = SpatialCalibration()
        var t = hold(&c, from: 0, seconds: 1.6, heading: 10)
        #expect(c.step == .sender)
        // 头没从 Mac 转开 12° 以上：不记
        t = hold(&c, from: t, seconds: 3, heading: 15)
        #expect(c.step == .sender)
        t = hold(&c, from: t, seconds: 1.6, heading: 62)
        guard case .done(let mac, let sender) = c.step else {
            Issue.record("没记下：\(c.step)")
            return
        }
        #expect(abs(mac - 10) < 0.01)
        #expect(abs(sender - 62) < 0.01)
    }

    @Test("头一直在动：不记，30 秒后失败")
    func movingHeadTimesOut() {
        var c = SpatialCalibration()
        _ = hold(&c, from: 0, seconds: 29, heading: 0, speed: 20)
        #expect(c.step == .mac)
        #expect(c.progress == 0)
        _ = hold(&c, from: 29, seconds: 2, heading: 0, speed: 20)
        #expect(c.step == .failed)
    }

    @Test("稳住一半时进度过半，动一下清零")
    func progressResetsWhenMoving() {
        var c = SpatialCalibration()
        let t = hold(&c, from: 0, seconds: 0.9, heading: 0)
        #expect(c.progress > 0.5 && c.progress < 1)
        c.feed(time: t, heading: 0, speed: 30)
        #expect(c.progress == 0)
    }
}

@Suite("空间音频：增益和开关")
struct SpatialMixTests {
    @Test("看着发送端原样，转开降到 awayGain，中间平滑")
    func gainCurve() {
        #expect(SpatialMix.gain(relative: 0, awayGain: 0.5) == 1)
        #expect(SpatialMix.gain(relative: -20, awayGain: 0.5) == 1)
        #expect(SpatialMix.gain(relative: 50, awayGain: 0.5) == 0.5)
        #expect(SpatialMix.gain(relative: -120, awayGain: 0.2) == 0.2)
        #expect(abs(SpatialMix.gain(relative: 35, awayGain: 0.5) - 0.75) < 1e-9)
        #expect(SpatialMix.gain(relative: 30, awayGain: 0.5) > SpatialMix.gain(relative: 40, awayGain: 0.5))
    }

    @Test("关掉、没校准、没权限、没耳机、发送端不在：按这个顺序说为什么不用")
    func modeDecision() {
        func decide(enabled: Bool = true, calibrated: Bool = true, authorization: HeadTracker.Authorization = .authorized,
                    headphones: Bool = true, senderPresent: Bool = true) -> SpatialMode {
            SpatialMode.decide(enabled: enabled, calibrated: calibrated, authorization: authorization,
                               headphones: headphones, senderPresent: senderPresent)
        }
        #expect(decide() == .active)
        #expect(decide(enabled: false, calibrated: false, senderPresent: false) == .off)
        #expect(decide(calibrated: false, authorization: .denied) == .needsSetup)
        #expect(decide(authorization: .denied, headphones: false) == .noPermission)
        #expect(decide(authorization: .notDetermined) == .active)
        #expect(decide(headphones: false, senderPresent: false) == .noHeadphones)
        #expect(decide(senderPresent: false) == .waitingForSender)
    }
}

@Suite("空间音频：跟踪和摆放")
struct SpatialTrackerTests {
    /// 50 Hz 的头部样本：朝向 yaw（度，左为正），头不动
    private func feed(_ tracker: SpatialTracker, from start: Double, seconds: Double, yaw: Double) -> Double {
        var t = start
        while t < start + seconds {
            tracker.add(HeadTracker.Sample(time: t, timestamp: t, yaw: yaw, pitch: 0, speed: 1, verticalRate: 0))
            t += 0.02
        }
        return t
    }

    /// 0.5 秒里匀速从 from 转到 to（陀螺仪和读数一致，不会被当成读数重置）
    private func turn(_ tracker: SpatialTracker, at start: Double, from: Double, to: Double) -> Double {
        let steps = 25, rate = (to - from) / 0.5
        var t = start
        for k in 1...steps {
            t += 0.02
            tracker.add(HeadTracker.Sample(time: t, timestamp: t, yaw: from + (to - from) * Double(k) / Double(steps),
                                           pitch: 0, speed: abs(rate), verticalRate: rate))
        }
        return t + 0.02
    }

    @Test("校准后：看着 Mac 时发送端在左边 50°、声音降低，Mac 在正前方；看着发送端时反过来")
    func placesSenderAfterCalibration() throws {
        let tracker = SpatialTracker(saved: nil)
        let placements = PlacementLog()
        tracker.onPlace = { sender, mac in placements.append(sender, mac) }
        tracker.setAwayGain(0.4)
        tracker.setActive(true)
        var t = feed(tracker, from: 0, seconds: 1, yaw: 0)
        #expect(placements.last == nil)  // 没校准过：不摆

        tracker.beginCalibration()
        t = feed(tracker, from: t, seconds: 1.8, yaw: 0)
        t = turn(tracker, at: t, from: 0, to: 50)
        t = feed(tracker, from: t, seconds: 1.8, yaw: 50)
        let saved = try #require(tracker.commitCalibration())
        #expect(abs(saved.angle - 50) < 0.5)

        t = turn(tracker, at: t, from: 50, to: 0)
        t = feed(tracker, from: t, seconds: 2, yaw: 0)
        let facingMac = try #require(placements.last)
        #expect(abs(facingMac.sender.centerRight - -50) < 1)
        #expect(abs(facingMac.sender.gain - 0.4) < 1e-6)
        #expect(abs(facingMac.mac.centerRight) < 1)
        #expect(facingMac.mac.gain == 1)

        t = turn(tracker, at: t, from: 0, to: 50)
        t = feed(tracker, from: t, seconds: 2, yaw: 50)
        let facingSender = try #require(placements.last)
        #expect(abs(facingSender.sender.centerRight) < 1)
        #expect(facingSender.sender.gain == 1)
        // Mac 在右边 50°，声音降低
        #expect(abs(facingSender.mac.centerRight - 50) < 1)
        #expect(abs(facingSender.mac.gain - 0.4) < 1e-6)
        #expect(tracker.status().facing == .windows)
    }

    @Test("头部数据停了又开（读数从头算）：方向接得上，转向发送端时它在正前方")
    func restartedMotionKeepsDirections() throws {
        let tracker = SpatialTracker(saved: nil)
        let placements = PlacementLog()
        tracker.onPlace = { sender, mac in placements.append(sender, mac) }
        tracker.setActive(true)
        tracker.beginCalibration()
        var t = feed(tracker, from: 0, seconds: 1.8, yaw: 0)
        t = turn(tracker, at: t, from: 0, to: 50)
        t = feed(tracker, from: t, seconds: 1.8, yaw: 50)
        try #require(tracker.commitCalibration() != nil)
        t = turn(tracker, at: t, from: 50, to: 0)
        t = feed(tracker, from: t, seconds: 2, yaw: 0)

        // 看着 Mac 时关掉又打开：停 3 秒，新的读数从 -37° 起（同一个朝向）
        tracker.motionRestarted()
        t = feed(tracker, from: t + 3, seconds: 2, yaw: -37)
        let facingMac = try #require(placements.last)
        #expect(abs(facingMac.mac.centerRight) < 1)
        #expect(abs(facingMac.sender.centerRight - -50) < 1)

        t = turn(tracker, at: t, from: -37, to: 13)
        _ = feed(tracker, from: t, seconds: 2, yaw: 13)
        let facingSender = try #require(placements.last)
        #expect(abs(facingSender.sender.centerRight) < 1)
        #expect(tracker.status().facing == .windows)
    }

    @Test("存下来的校准：下次打开不用再校准")
    func savedCalibrationIsRestored() {
        let saved = SpatialTracker.Saved(angle: -40, main: .mac, map: ScreenAnchors.seeds(angle: -40, main: .mac))
        let tracker = SpatialTracker(saved: saved)
        #expect(tracker.status().calibrated)
        #expect(tracker.status().angle == -40)
        #expect(tracker.saved()?.angle == -40)
        #expect(SpatialTracker(saved: nil).saved() == nil)
    }
}

/// 摆放回调在调用方线程上记下来
private final class PlacementLog: @unchecked Sendable {
    private let lock = NSLock()
    private var items: [(sender: SpatialPlacement, mac: SpatialPlacement)] = []

    func append(_ sender: SpatialPlacement, _ mac: SpatialPlacement) {
        lock.lock()
        items.append((sender, mac))
        lock.unlock()
    }

    var last: (sender: SpatialPlacement, mac: SpatialPlacement)? {
        lock.lock()
        defer { lock.unlock() }
        return items.last
    }
}

@Suite("空间音频：音频图")
struct SpatialOutputTests {
    @Test("左右两路拆给两个音源，不管先拉哪一路，都和直接渲染逐样本一致")
    func splitterMatchesDirectRender() throws {
        let direct = makeCore(), split = makeCore()
        let factory = PacketFactory()
        for i in 0..<40 {
            direct.ingest(factory.packet(i), at: Double(i) * 0.005)
            split.ingest(factory.packet(i), at: Double(i) * 0.005)
        }
        let splitter = StereoSplitter(core: split)
        var left = [Float](repeating: 0, count: 256), right = left
        for block in 0..<12 {
            let expected = direct.renderStereo(256)
            left.withUnsafeMutableBufferPointer { l in
                right.withUnsafeMutableBufferPointer { r in
                    // 两个节点被拉的先后不固定：轮流换顺序
                    if block % 2 == 0 {
                        _ = splitter.pull(right: false, into: l.baseAddress!, frames: 256)
                        _ = splitter.pull(right: true, into: r.baseAddress!, frames: 256)
                    } else {
                        _ = splitter.pull(right: true, into: r.baseAddress!, frames: 256)
                        _ = splitter.pull(right: false, into: l.baseAddress!, frames: 256)
                    }
                }
            }
            #expect(left == expected.left)
            #expect(right == expected.right)
        }
    }

    @Test("发送端放在右边时右耳更响，放在左边时左耳更响（离线渲染，不会出声）")
    func soundComesFromThePlacedSide() throws {
        let rightSide = try renderedLevels(centerRight: 70)
        #expect(rightSide.right > rightSide.left * 1.3)
        let leftSide = try renderedLevels(centerRight: -70)
        #expect(leftSide.left > leftSide.right * 1.3)
    }

    /// 1 kHz 正弦经过空间音频图，返回左右耳的均方根。边渲染边喂包（一次喂太多的话，开播时多出来的会被丢掉）
    private func renderedLevels(centerRight: Double,
                                algorithm: AVAudio3DMixingRenderingAlgorithm? = nil) throws -> (left: Double, right: Double) {
        let core = makeCore()
        var factory = PacketFactory()
        factory.sine = (1000, 0.3)
        var sent = 0
        func feed(untilFrames frames: Int) {
            while sent * factory.framesPerPacket < frames {
                core.ingest(factory.packet(sent), at: Double(sent) * 0.005)
                sent += 1
            }
        }
        feed(untilFrames: 3_840)

        let stereo = try #require(AVAudioFormat(standardFormatWithSampleRate: 48_000, channels: 2))
        let mono = try #require(AVAudioFormat(standardFormatWithSampleRate: 48_000, channels: 1))
        let engine = AVAudioEngine()
        try engine.enableManualRenderingMode(.offline, format: stereo, maximumFrameCount: 512)
        let environment = AVAudioEnvironmentNode()
        let speakers = SpeakerPair()
        speakers.use(AudioOutput.attachSpatialGraph(to: engine, environment: environment, core: core,
                                                    stereo: stereo, mono: mono, algorithm: algorithm))
        speakers.place(centerRight: centerRight, gain: 1)
        try engine.start()
        defer { engine.stop() }

        let buffer = try #require(AVAudioPCMBuffer(pcmFormat: engine.manualRenderingFormat, frameCapacity: 512))
        var sum = (left: 0.0, right: 0.0)
        for block in 0..<40 {
            feed(untilFrames: 3_840 + (block + 1) * 512)
            #expect(try engine.renderOffline(512, to: buffer) == .success)
            guard block >= 10 else { continue }  // 跳过开头（缓冲、HRTF 滤波器还没稳定）
            let channels = try #require(buffer.floatChannelData)
            for i in 0..<Int(buffer.frameLength) {
                sum.left += Double(channels[0][i] * channels[0][i])
                sum.right += Double(channels[1][i] * channels[1][i])
            }
        }
        #expect(sum.left + sum.right > 0)
        return (sum.left.squareRoot(), sum.right.squareRoot())
    }
}

@Suite("空间音频：Mac 自己的声音")
struct MacSoundTests {
    /// 写一块（不交错的立体声）：左声道是 value，右声道是 -value
    private func write(_ ring: CaptureRing, frames: Int, value: Float) throws {
        let format = try #require(AVAudioFormat(standardFormatWithSampleRate: 48_000, channels: 2))
        let buffer = try #require(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(frames)))
        buffer.frameLength = AVAudioFrameCount(frames)
        let channels = try #require(buffer.floatChannelData)
        for i in 0..<frames {
            channels[0][i] = value
            channels[1][i] = -value
        }
        ring.write(buffer.audioBufferList, interleaved: false, channels: 2)
    }

    private func read(_ ring: CaptureRing, frames: Int) -> (left: [Float], right: [Float], sound: Bool) {
        var left = [Float](repeating: .nan, count: frames), right = left
        let sound = left.withUnsafeMutableBufferPointer { l in
            right.withUnsafeMutableBufferPointer { r in ring.read(left: l.baseAddress!, right: r.baseAddress!, frames: frames) }
        }
        return (left, right, sound)
    }

    @Test("先攒 25 ms 才出声；读空了重新攒；攒太多丢掉旧的")
    func ringBuffersAndTrims() throws {
        let ring = CaptureRing(sampleRate: 48_000)
        try write(ring, frames: 512, value: 0.5)
        var out = read(ring, frames: 256)
        #expect(!out.sound)
        #expect(out.left.allSatisfy { $0 == 0 })

        try write(ring, frames: 1024, value: 0.5)  // 一共 1536 帧，超过 1200 帧的目标
        out = read(ring, frames: 256)
        #expect(out.sound)
        #expect(out.left.allSatisfy { $0 == 0.5 } && out.right.allSatisfy { $0 == -0.5 })

        // 读空：剩下的放完，后面补静音，然后重新攒
        out = read(ring, frames: 2048)
        #expect(out.left[0] == 0.5 && out.left[2047] == 0)
        try write(ring, frames: 512, value: 0.25)
        #expect(!read(ring, frames: 256).sound)

        // 攒到超过目标 50 ms（2400 帧）以上：丢掉旧的，只留目标那么多，新的在后面
        try write(ring, frames: 4096, value: 0.25)
        try write(ring, frames: 1200, value: 0.75)
        out = read(ring, frames: 1200)
        #expect(out.left.allSatisfy { $0 == 0.75 })
    }

    @Test("Mac 的声音放在右边时右耳更响（来源是 44.1 kHz 的假声音，离线渲染）")
    func macSoundComesFromThePlacedSide() throws {
        let right = try levels(macCenter: 70)
        #expect(right.right > right.left * 1.3)
        let left = try levels(macCenter: -70)
        #expect(left.left > left.right * 1.3)
    }

    private func levels(macCenter: Double) throws -> (left: Double, right: Double) {
        let core = makeCore()  // 没有发送端的声音：只听 Mac 那一路
        let stereo = try #require(AVAudioFormat(standardFormatWithSampleRate: 48_000, channels: 2))
        let mono = try #require(AVAudioFormat(standardFormatWithSampleRate: 48_000, channels: 1))
        let engine = AVAudioEngine()
        try engine.enableManualRenderingMode(.offline, format: stereo, maximumFrameCount: 512)
        let environment = AVAudioEnvironmentNode()
        let nodes = AudioOutput.attachSpatialGraph(to: engine, environment: environment, core: core, stereo: stereo,
                                                   mono: mono, mac: SineSource())
        #expect(nodes.count == 4)
        let sender = SpeakerPair(), mac = SpeakerPair()
        sender.use(Array(nodes.prefix(2)))
        mac.use(Array(nodes.dropFirst(2)))
        mac.place(centerRight: macCenter, gain: 1)
        try engine.start()
        defer { engine.stop() }
        let buffer = try #require(AVAudioPCMBuffer(pcmFormat: engine.manualRenderingFormat, frameCapacity: 512))
        var sum = (left: 0.0, right: 0.0)
        for block in 0..<40 {
            #expect(try engine.renderOffline(512, to: buffer) == .success)
            guard block >= 10 else { continue }
            let channels = try #require(buffer.floatChannelData)
            for i in 0..<Int(buffer.frameLength) {
                sum.left += Double(channels[0][i] * channels[0][i])
                sum.right += Double(channels[1][i] * channels[1][i])
            }
        }
        #expect(sum.left + sum.right > 0)
        return (sum.left.squareRoot(), sum.right.squareRoot())
    }
}

/// 假的 Mac 声音：44.1 kHz、1 kHz 正弦，左右相同
private final class SineSource: StereoSource, @unchecked Sendable {
    let sampleRate = 44_100.0
    private var phase = 0.0

    func read(left: UnsafeMutablePointer<Float>, right: UnsafeMutablePointer<Float>, frames: Int) -> Bool {
        for i in 0..<frames {
            let v = Float(0.3 * sin(phase))
            left[i] = v
            right[i] = v
            phase += 2 * .pi * 1000 / sampleRate
        }
        return true
    }

    func stop() {}
}
