import AVFoundation
import os

private let outputLog = Logger(subsystem: "app.earpair", category: "output")

/// 用 AVAudioEngine 把 ReceiverCore 的输出送到系统默认输出设备（比如 AirPods）。
/// 系统混音器会把它和 Mac 上其他 App 的声音混在一起播放。除了 place(sender:mac:)，只在主线程使用。
///
/// 空间音频时，发送端的左右两路各放一只虚拟音箱，交给 AVAudioEnvironmentNode 按头的方向渲染（它只给单声道输入做空间化）。
/// 还可以把这台 Mac 上其他 App 的声音截下来（MacAudioCapture，原声静音），同样拆成两只虚拟音箱放在 Mac 的方向。
/// 只在空间音频开着、引擎在跑的时候截取；停止播放、关掉空间音频或者引擎起不来时马上停止截取，Mac 的声音恢复原样。
public final class AudioOutput {
    private let engine = AVAudioEngine()
    private let core: ReceiverCore
    private var format: AVAudioFormat?
    private var wantsRunning = false
    private var configurationObserver: NSObjectProtocol?
    private var spatial = false
    private var wantsMacAudio = false
    private var capture: StereoSource?
    /// 现在的音频图是按什么搭的：采样率、是不是空间音频、接的是哪一路 Mac 声音
    private var built: (rate: Double, spatial: Bool, mac: ObjectIdentifier?)?
    private var plainNode: AVAudioSourceNode?
    private let environment = AVAudioEnvironmentNode()
    private let senderSpeakers = SpeakerPair()
    private let macSpeakers = SpeakerPair()

    /// 截取 Mac 声音失败（比如没有权限）时调用，参数是原因。主线程
    public var onMacAudioFailure: ((String) -> Void)?
    /// 截取 Mac 声音用的来源（测试可以换成假的）
    public var makeMacSource: () throws -> StereoSource = AudioOutput.systemCapture

    public init(core: ReceiverCore) {
        self.core = core
        configurationObserver = NotificationCenter.default.addObserver(
            forName: .AVAudioEngineConfigurationChange, object: engine, queue: .main
        ) { [weak self] _ in
            self?.restartAfterConfigurationChange()
        }
    }

    deinit {
        if let configurationObserver {
            NotificationCenter.default.removeObserver(configurationObserver)
        }
        engine.stop()
        capture?.stop()
    }

    public var isRunning: Bool { engine.isRunning }

    public var isSpatial: Bool { spatial }

    /// 正在截取 Mac 的声音
    public var isCapturingMac: Bool { capture != nil }

    /// 以给定采样率开始播放；采样率变了就重建音频图。
    public func start(sampleRate: Double) throws {
        wantsRunning = true
        if format?.sampleRate != sampleRate {
            format = AVAudioFormat(standardFormatWithSampleRate: sampleRate, channels: 2)
        }
        core.setOutputSampleRate(sampleRate)
        try reconcile()
    }

    /// 停止播放，释放音频设备（AirPods 可以休眠或切到别的设备）。
    public func stop() {
        wantsRunning = false
        engine.stop()
        try? reconcile()
    }

    /// 切换空间音频。正在播放时重建音频图，会断一下（几十毫秒）
    public func setSpatial(_ on: Bool) {
        guard on != spatial else { return }
        spatial = on
        try? reconcile()
    }

    /// 空间音频时要不要把 Mac 自己的声音也截下来摆进去
    public func setMacAudio(_ on: Bool) {
        guard on != wantsMacAudio else { return }
        wantsMacAudio = on
        try? reconcile()
    }

    /// 摆放虚拟音箱：中心在 centerRight 度（右为正，0 是正前方），增益 gain（0…1）。任何线程都可以调用
    public func place(sender: SpatialPlacement, mac: SpatialPlacement) {
        senderSpeakers.place(centerRight: sender.centerRight, gain: sender.gain)
        macSpeakers.place(centerRight: mac.centerRight, gain: mac.gain)
    }

    /// 让截取、音频图、引擎和现在想要的状态一致。截取在新的音频图接好之后才停，原声恢复时不会两边都没声音
    private func reconcile() throws {
        var retired: StereoSource?
        let needsCapture = spatial && wantsMacAudio && wantsRunning
        if needsCapture, capture == nil {
            do {
                capture = try makeMacSource()
            } catch {
                outputLog.error("截取 Mac 的声音失败：\(error.localizedDescription, privacy: .public)")
                wantsMacAudio = false
                onMacAudioFailure?(error.localizedDescription)
            }
        } else if !needsCapture, let current = capture {
            retired = current
            capture = nil
        }
        defer { retired?.stop() }
        guard let format else { return }
        let wanted = (rate: format.sampleRate, spatial: spatial, mac: capture.map(ObjectIdentifier.init))
        if built.map({ $0.rate != wanted.rate || $0.spatial != wanted.spatial || $0.mac != wanted.mac }) ?? true {
            rebuild(format: format)
            built = wanted
        }
        guard wantsRunning, !engine.isRunning else { return }
        do {
            engine.prepare()
            try engine.start()
        } catch {
            // 引擎起不来：不能让 Mac 的声音一直静音
            capture?.stop()
            capture = nil
            built = nil
            throw error
        }
    }

    private func rebuild(format stereo: AVAudioFormat) {
        engine.stop()
        if let plainNode { engine.detach(plainNode) }
        plainNode = nil
        for node in senderSpeakers.take() + macSpeakers.take() { engine.detach(node) }
        if environment.engine != nil { engine.detach(environment) }
        guard let mono = AVAudioFormat(standardFormatWithSampleRate: stereo.sampleRate, channels: 1) else { return }
        if spatial {
            let nodes = Self.attachSpatialGraph(to: engine, environment: environment, core: core, stereo: stereo,
                                                mono: mono, mac: capture)
            senderSpeakers.use(Array(nodes.prefix(2)))
            macSpeakers.use(Array(nodes.dropFirst(2)))
        } else {
            let node = Self.makeSourceNode(core: core, format: stereo)
            engine.attach(node)
            engine.connect(node, to: engine.mainMixerNode, format: stereo)
            plainNode = node
        }
    }

    /// 截取这台 Mac 的声音（macOS 14.2 起）
    public static func systemCapture() throws -> StereoSource {
        guard #available(macOS 14.2, *) else { throw MacAudioError.unsupported }
        return try MacAudioCapture()
    }

    /// 在 engine 上接好空间音频的音频图：ReceiverCore → 左右两只虚拟音箱（单声道音源）→ environment → 主混音器；
    /// 有 mac 时再接两只放 Mac 的声音（按它自己的采样率，environment 会转换）。
    /// 返回音箱：发送端的左、右，然后（有的话）Mac 的左、右，用 SpeakerPair 摆放。
    /// algorithm 为 nil 时：有个性化 HRTF 就用它（.auto），否则用高质量的通用 HRTF
    public static func attachSpatialGraph(to engine: AVAudioEngine, environment: AVAudioEnvironmentNode,
                                          core: ReceiverCore, stereo: AVAudioFormat, mono: AVAudioFormat,
                                          mac: StereoSource? = nil,
                                          algorithm: AVAudio3DMixingRenderingAlgorithm? = nil) -> [AVAudioSourceNode] {
        engine.attach(environment)
        environment.outputType = .headphones
        environment.listenerPosition = AVAudio3DPoint(x: 0, y: 0, z: 0)
        environment.listenerVectorOrientation = AVAudio3DVectorOrientation(
            forward: AVAudio3DVector(x: 0, y: 0, z: -1), up: AVAudio3DVector(x: 0, y: 1, z: 0))
        // 一点小房间的混响，声音更像从外面来的，而不是在脑袋里
        environment.reverbParameters.enable = true
        environment.reverbParameters.loadFactoryReverbPreset(.mediumRoom)
        environment.reverbParameters.level = -12
        let auto = NSNumber(value: AVAudio3DMixingRenderingAlgorithm.auto.rawValue)
        let algorithm = algorithm ?? (environment.applicableRenderingAlgorithms.contains(auto) ? .auto : .HRTFHQ)

        var nodes: [AVAudioSourceNode] = []
        func attachPair(_ splitter: StereoSplitter, format: AVAudioFormat) {
            for right in [false, true] {
                let node = AVAudioSourceNode(format: format) { isSilence, _, frameCount, bufferList -> OSStatus in
                    let buffers = UnsafeMutableAudioBufferListPointer(bufferList)
                    guard let out = buffers.first?.mData?.assumingMemoryBound(to: Float.self) else { return noErr }
                    let produced = splitter.pull(right: right, into: out, frames: Int(frameCount))
                    isSilence.pointee = ObjCBool(!produced)
                    return noErr
                }
                engine.attach(node)
                engine.connect(node, to: environment, format: format)
                node.renderingAlgorithm = algorithm
                node.sourceMode = .pointSource
                node.pointSourceInHeadMode = .mono
                node.reverbBlend = 0.15
                nodes.append(node)
            }
        }
        attachPair(StereoSplitter(core: core), format: mono)
        if let mac, let macFormat = AVAudioFormat(standardFormatWithSampleRate: mac.sampleRate, channels: 1) {
            attachPair(StereoSplitter { left, right, frames in mac.read(left: left, right: right, frames: frames) },
                       format: macFormat)
        }
        engine.connect(environment, to: engine.mainMixerNode, format: stereo)
        return nodes
    }

    /// 创建从 ReceiverCore 拉数据的音源节点。`format` 必须是 2 声道、非交错的 Float32。
    public static func makeSourceNode(core: ReceiverCore, format: AVAudioFormat) -> AVAudioSourceNode {
        AVAudioSourceNode(format: format) { isSilence, _, frameCount, bufferList -> OSStatus in
            let buffers = UnsafeMutableAudioBufferListPointer(bufferList)
            guard buffers.count >= 2,
                  let left = buffers[0].mData?.assumingMemoryBound(to: Float.self),
                  let right = buffers[1].mData?.assumingMemoryBound(to: Float.self) else {
                return noErr
            }
            let produced = core.render(left: left, right: right, frames: Int(frameCount))
            isSilence.pointee = ObjCBool(!produced)
            return noErr
        }
    }

    private func restartAfterConfigurationChange() {
        // 输出设备变了（比如连上或断开 AirPods）：引擎会自己停下，按原来的格式重新接好再启动
        guard wantsRunning else { return }
        built = nil
        try? reconcile()
    }
}

/// 一只虚拟音箱组摆在哪：中心方向（度，右为正）和增益（0…1）
public struct SpatialPlacement: Equatable, Sendable {
    public var centerRight: Double
    public var gain: Double

    public init(centerRight: Double, gain: Double) {
        self.centerRight = centerRight
        self.gain = gain
    }
}

/// 一次渲染出左右两路，分给两个单声道音源节点。
/// 两个节点在同一个渲染线程、同一轮里各被拉一次：先来的渲染这一块，另一个取走同一块里自己那一路。
public final class StereoSplitter: @unchecked Sendable {
    public typealias Render = (UnsafeMutablePointer<Float>, UnsafeMutablePointer<Float>, Int) -> Bool
    static let capacity = 16_384
    private let render: Render
    private let left = UnsafeMutablePointer<Float>.allocate(capacity: capacity)
    private let right = UnsafeMutablePointer<Float>.allocate(capacity: capacity)
    private var frames = 0
    private var produced = false
    private var takenLeft = true
    private var takenRight = true

    public init(render: @escaping Render) {
        self.render = render
        left.initialize(repeating: 0, count: Self.capacity)
        right.initialize(repeating: 0, count: Self.capacity)
    }

    public convenience init(core: ReceiverCore) {
        self.init { left, right, frames in core.render(left: left, right: right, frames: frames) }
    }

    deinit {
        left.deallocate()
        right.deallocate()
    }

    /// 取一路：right 为 false 是左声道。返回这一块有没有声音
    public func pull(right wantsRight: Bool, into out: UnsafeMutablePointer<Float>, frames n: Int) -> Bool {
        guard n <= Self.capacity else {
            out.update(repeating: 0, count: n)
            return false
        }
        if (wantsRight ? takenRight : takenLeft) || n != frames {
            produced = render(left, right, n)
            frames = n
            takenLeft = false
            takenRight = false
        }
        out.update(from: wantsRight ? right : left, count: n)
        if wantsRight { takenRight = true } else { takenLeft = true }
        return produced
    }
}

/// 一对虚拟音箱：头部数据的队列摆放，主线程重建音频图时换节点
public final class SpeakerPair: @unchecked Sendable {
    private let lock = UnfairLock()
    private var nodes: [AVAudioSourceNode] = []
    private var center = 0.0
    private var gain = 1.0

    public init() {}

    public func use(_ nodes: [AVAudioSourceNode]) {
        lock.withLock { self.nodes = nodes }
        apply()
    }

    /// 拿走现在的节点（要从引擎上拆下来）
    func take() -> [AVAudioSourceNode] {
        lock.withLock {
            defer { nodes = [] }
            return nodes
        }
    }

    public func place(centerRight: Double, gain: Double) {
        lock.withLock {
            center = centerRight
            self.gain = min(max(gain, 0), 1)
        }
        apply()
    }

    private func apply() {
        let (nodes, center, gain) = lock.withLock { (self.nodes, self.center, self.gain) }
        for (index, node) in nodes.enumerated() {
            // 1 米外。右手坐标系：听者朝 −Z，+X 是右边
            let degrees = center + (index == 0 ? -1 : 1) * SpatialMix.halfWidth
            let radians = degrees * .pi / 180
            node.position = AVAudio3DPoint(x: Float(sin(radians)), y: 0, z: Float(-cos(radians)))
            node.volume = Float(gain)
        }
    }
}
