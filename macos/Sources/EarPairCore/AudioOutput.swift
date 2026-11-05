import AVFoundation

/// 用 AVAudioEngine 把 ReceiverCore 的输出送到系统默认输出设备（比如 AirPods）。
/// 系统混音器会把它和 Mac 上其他 App 的声音混在一起播放。只在主线程使用。
public final class AudioOutput {
    private let engine = AVAudioEngine()
    private let core: ReceiverCore
    private var sourceNode: AVAudioSourceNode?
    private var format: AVAudioFormat?
    private var wantsRunning = false
    private var configurationObserver: NSObjectProtocol?

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
    }

    public var isRunning: Bool { engine.isRunning }

    /// 以给定采样率开始播放；采样率变了就重建音源节点。
    public func start(sampleRate: Double) throws {
        wantsRunning = true
        if sourceNode == nil || format?.sampleRate != sampleRate {
            rebuild(sampleRate: sampleRate)
        }
        core.setOutputSampleRate(sampleRate)
        if !engine.isRunning {
            engine.prepare()
            try engine.start()
        }
    }

    /// 停止播放，释放音频设备（AirPods 可以休眠或切到别的设备）。
    public func stop() {
        wantsRunning = false
        engine.stop()
    }

    private func rebuild(sampleRate: Double) {
        engine.stop()
        if let sourceNode { engine.detach(sourceNode) }
        guard let format = AVAudioFormat(standardFormatWithSampleRate: sampleRate, channels: 2) else { return }
        let node = Self.makeSourceNode(core: core, format: format)
        engine.attach(node)
        engine.connect(node, to: engine.mainMixerNode, format: format)
        sourceNode = node
        self.format = format
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
        // 输出设备变了（比如连上或断开 AirPods）：引擎会自己停下，需要重新连接并启动
        guard wantsRunning, let sourceNode, let format else { return }
        engine.connect(sourceNode, to: engine.mainMixerNode, format: format)
        engine.prepare()
        try? engine.start()
    }
}
