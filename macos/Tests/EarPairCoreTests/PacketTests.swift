import EarPairCore
import Testing

@Suite("数据包格式")
struct PacketTests {
    let vectorHeader = PacketHeader(streamID: 0x0102_0304, sequence: 7, sampleTime: 480,
                                    sampleRate: 48_000, channels: 2, frameCount: 2)
    let vectorSamples: [Int16] = [1000, -1000, 32767, -32768]

    @Test("编码结果与 protocol/audio-packet.md 里的测试向量一致")
    func matchesProtocolTestVector() throws {
        let bytes = PacketHeader.encode(vectorHeader, samples: vectorSamples)
        let expected: [UInt8] = [
            0x45, 0x41, 0x52, 0x50, 0x01, 0x00, 0x01, 0x02, 0x04, 0x03, 0x02, 0x01, 0x07, 0x00, 0x00, 0x00,
            0xE0, 0x01, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x80, 0xBB, 0x00, 0x00, 0x02, 0x00, 0x00, 0x00,
            0xE8, 0x03, 0x18, 0xFC, 0xFF, 0x7F, 0x00, 0x80,
        ]
        #expect(bytes == expected)
        let parsed = try bytes.withUnsafeBytes { try PacketHeader.parse($0) }
        #expect(parsed == vectorHeader)
    }

    @Test("格式不对的包会被拒绝")
    func rejectsMalformedPackets() {
        let good = PacketHeader.encode(vectorHeader, samples: vectorSamples)
        func parse(_ bytes: [UInt8]) throws { _ = try bytes.withUnsafeBytes { try PacketHeader.parse($0) } }
        func modified(_ index: Int, _ value: UInt8) -> [UInt8] {
            var copy = good
            copy[index] = value
            return copy
        }

        #expect(throws: PacketError.tooShort) { try parse(Array(good.prefix(20))) }
        #expect(throws: PacketError.badMagic) { try parse(modified(0, 0x00)) }
        #expect(throws: PacketError.unsupportedVersion(2)) { try parse(modified(4, 2)) }
        #expect(throws: PacketError.unsupportedCodec(9)) { try parse(modified(6, 9)) }
        #expect(throws: PacketError.badChannelCount(0)) { try parse(modified(7, 0)) }
        #expect(throws: PacketError.badFrameCount(0)) {
            var copy = good
            copy[28] = 0
            try parse(copy)
        }
        #expect(throws: PacketError.lengthMismatch(expected: 40, actual: 38)) { try parse(Array(good.prefix(38))) }
    }
}
