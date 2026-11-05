import AVFoundation
import EarPairCore
import Testing

@Suite("音频输出")
struct AudioOutputTests {
    @Test("AVAudioSourceNode 能从接收核心拉到音频（离线渲染，不会出声）")
    func sourceNodeRendersCoreAudio() throws {
        let core = makeCore()
        let factory = PacketFactory()
        for i in 0..<16 { core.ingest(factory.packet(i), at: Double(i) * 0.005) }

        let format = try #require(AVAudioFormat(standardFormatWithSampleRate: 48_000, channels: 2))
        let engine = AVAudioEngine()
        try engine.enableManualRenderingMode(.offline, format: format, maximumFrameCount: 512)
        let node = AudioOutput.makeSourceNode(core: core, format: format)
        engine.attach(node)
        engine.connect(node, to: engine.mainMixerNode, format: format)
        try engine.start()
        defer { engine.stop() }

        let buffer = try #require(AVAudioPCMBuffer(pcmFormat: engine.manualRenderingFormat, frameCapacity: 512))
        var left: [Float] = []
        for _ in 0..<6 {
            let status = try engine.renderOffline(512, to: buffer)
            #expect(status == .success)
            let channels = try #require(buffer.floatChannelData)
            left += Array(UnsafeBufferPointer(start: channels[0], count: Int(buffer.frameLength)))
        }

        // 16 包一次到齐（3840 帧），开播时只保留「目标 + 10 ms」= 3360 帧，所以从第 480 帧开始播
        let anchor = try #require(outputIndex(ofFrame: 1100, in: left, tolerance: 1e-6))
        #expect(mismatches(left, anchor: anchor, anchorFrame: 1100, frames: 1100..<3500,
                           expected: PacketFactory.expectedLeft, tolerance: 1e-6) == 0)
    }
}
