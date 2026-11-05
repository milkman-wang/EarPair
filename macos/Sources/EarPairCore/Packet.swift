import Foundation

/// EarPair 音频包 v1 的包头。字段布局见 protocol/audio-packet.md，多字节字段一律小端序。
public struct PacketHeader: Equatable, Sendable {
    public static let size = 32
    public static let version: UInt8 = 1
    public static let maxFrameCount = 4096
    /// ASCII "EARP"
    public static let magic: [UInt8] = [0x45, 0x41, 0x52, 0x50]

    public enum Codec: UInt8, Sendable {
        /// 16-bit 有符号整数 PCM，各声道交错
        case pcm16 = 1
    }

    public var flags: UInt8
    public var codec: Codec
    public var channels: UInt8
    public var streamID: UInt32
    public var sequence: UInt32
    public var sampleTime: UInt64
    public var sampleRate: UInt32
    public var frameCount: UInt16

    public init(streamID: UInt32, sequence: UInt32, sampleTime: UInt64, sampleRate: UInt32,
                channels: UInt8 = 2, frameCount: UInt16, codec: Codec = .pcm16, flags: UInt8 = 0) {
        self.flags = flags
        self.codec = codec
        self.channels = channels
        self.streamID = streamID
        self.sequence = sequence
        self.sampleTime = sampleTime
        self.sampleRate = sampleRate
        self.frameCount = frameCount
    }

    public var payloadSize: Int { Int(frameCount) * Int(channels) * 2 }
    public var packetSize: Int { Self.size + payloadSize }
}

public enum PacketError: Error, Equatable {
    case tooShort
    case badMagic
    case unsupportedVersion(UInt8)
    case unsupportedCodec(UInt8)
    case badChannelCount(UInt8)
    case badSampleRate(UInt32)
    case badFrameCount(UInt16)
    case lengthMismatch(expected: Int, actual: Int)
}

extension PacketHeader {
    /// 解析并校验一个完整的包（包头 + 数据）。
    public static func parse(_ bytes: UnsafeRawBufferPointer) throws -> PacketHeader {
        guard bytes.count >= size else { throw PacketError.tooShort }
        guard bytes[0] == magic[0], bytes[1] == magic[1], bytes[2] == magic[2], bytes[3] == magic[3] else {
            throw PacketError.badMagic
        }
        guard bytes[4] == version else { throw PacketError.unsupportedVersion(bytes[4]) }
        guard let codec = Codec(rawValue: bytes[6]) else { throw PacketError.unsupportedCodec(bytes[6]) }
        let channels = bytes[7]
        guard (1...8).contains(channels) else { throw PacketError.badChannelCount(channels) }

        let header = PacketHeader(
            streamID: bytes.readLE(UInt32.self, at: 8),
            sequence: bytes.readLE(UInt32.self, at: 12),
            sampleTime: bytes.readLE(UInt64.self, at: 16),
            sampleRate: bytes.readLE(UInt32.self, at: 24),
            channels: channels,
            frameCount: bytes.readLE(UInt16.self, at: 28),
            codec: codec,
            flags: bytes[5])

        guard (8_000...192_000).contains(header.sampleRate) else { throw PacketError.badSampleRate(header.sampleRate) }
        guard header.frameCount >= 1, Int(header.frameCount) <= maxFrameCount else {
            throw PacketError.badFrameCount(header.frameCount)
        }
        guard bytes.count == header.packetSize else {
            throw PacketError.lengthMismatch(expected: header.packetSize, actual: bytes.count)
        }
        return header
    }

    /// 把包头写进 `buffer` 的前 32 字节。
    public func write(to buffer: UnsafeMutableRawBufferPointer) {
        precondition(buffer.count >= Self.size)
        for i in 0..<4 { buffer[i] = Self.magic[i] }
        buffer[4] = Self.version
        buffer[5] = flags
        buffer[6] = codec.rawValue
        buffer[7] = channels
        buffer.writeLE(streamID, at: 8)
        buffer.writeLE(sequence, at: 12)
        buffer.writeLE(sampleTime, at: 16)
        buffer.writeLE(sampleRate, at: 24)
        buffer.writeLE(frameCount, at: 28)
        buffer.writeLE(UInt16(0), at: 30)
    }

    /// 编码一个完整的包（测试和工具用）。`samples` 是交错的 16-bit 样本，个数必须等于 frameCount × channels。
    public static func encode(_ header: PacketHeader, samples: [Int16]) -> [UInt8] {
        precondition(samples.count == Int(header.frameCount) * Int(header.channels))
        var bytes = [UInt8](repeating: 0, count: header.packetSize)
        bytes.withUnsafeMutableBytes { buffer in
            header.write(to: buffer)
            for (i, sample) in samples.enumerated() {
                buffer.writeLE(sample, at: size + i * 2)
            }
        }
        return bytes
    }
}

extension UnsafeRawBufferPointer {
    @inline(__always)
    func readLE<T: FixedWidthInteger>(_: T.Type, at offset: Int) -> T {
        T(littleEndian: loadUnaligned(fromByteOffset: offset, as: T.self))
    }
}

extension UnsafeMutableRawBufferPointer {
    @inline(__always)
    func writeLE<T: FixedWidthInteger>(_ value: T, at offset: Int) {
        storeBytes(of: value.littleEndian, toByteOffset: offset, as: T.self)
    }
}
