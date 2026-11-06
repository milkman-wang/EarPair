import Foundation

/// 控制包 v1（EARC）：8 字节包头 + JSON。格式见 protocol/control-packet.md。
public enum ControlPacket {
    public static let magic: [UInt8] = [0x45, 0x41, 0x52, 0x43] // "EARC"
    public static let version: UInt8 = 1
    public static let headerSize = 8
    public static let maxSize = 1400

    public enum Kind: UInt8, Sendable {
        case hello = 3
        case status = 4
        case bye = 5
    }

    /// 前 4 个字节是不是 EARC（音频包是 EARP）
    public static func isControl(_ bytes: UnsafeRawBufferPointer) -> Bool {
        bytes.count >= 4 && bytes[0] == magic[0] && bytes[1] == magic[1] && bytes[2] == magic[2] && bytes[3] == magic[3]
    }

    /// 解析包头，返回类型和消息体；格式不对、版本不对、类型不认识都返回 nil
    public static func parse(_ bytes: UnsafeRawBufferPointer) -> (kind: Kind, body: Data)? {
        guard bytes.count >= headerSize, bytes.count <= maxSize, isControl(bytes), bytes[4] == version,
              let kind = Kind(rawValue: bytes[5]) else { return nil }
        let length = Int(bytes[6]) | Int(bytes[7]) << 8
        guard bytes.count == headerSize + length else { return nil }
        return (kind, Data(bytes[headerSize...]))
    }

    public static func encode(_ kind: Kind, body: Data) -> Data? {
        guard headerSize + body.count <= maxSize else { return nil }
        var data = Data(magic)
        data.append(version)
        data.append(kind.rawValue)
        data.append(UInt8(body.count & 0xFF))
        data.append(UInt8(body.count >> 8))
        data.append(body)
        return data
    }

    public static func encode<Message: Encodable>(_ kind: Kind, _ message: Message) -> Data? {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        guard let body = try? encoder.encode(message) else { return nil }
        return encode(kind, body: body)
    }

    public static func decode<Message: Decodable>(_ type: Message.Type, from body: Data) -> Message? {
        try? JSONDecoder().decode(type, from: body)
    }
}

/// 设备类型：控制包和 Bonjour TXT 里的 kind 字段。不认识的值当作未知
public enum DeviceKind: String, Sendable {
    case laptop
    case desktop

    public init?(protocolValue: String?) {
        guard let protocolValue, let kind = DeviceKind(rawValue: protocolValue) else { return nil }
        self = kind
    }
}

/// 发送端 → 接收端：我是谁、正在发哪个流。stream 为 0 表示还没在发（只是问一下接收端在不在）
public struct HelloMessage: Codable, Equatable, Sendable {
    public var sender: String?
    public var name: String?
    /// laptop / desktop
    public var kind: String?
    public var app: String?
    public var stream: UInt32?

    public init(sender: String? = nil, name: String? = nil, kind: String? = nil, app: String? = nil,
                stream: UInt32? = nil) {
        self.sender = sender
        self.name = name
        self.kind = kind
        self.app = app
        self.stream = stream
    }
}

/// 接收端 → 发送端：接收状态
public struct StatusMessage: Codable, Equatable, Sendable {
    public var id: String?
    public var name: String?
    /// 接收端是 laptop 还是 desktop
    public var kind: String?
    public var app: String?
    public var stream: UInt32?
    /// buffering / playing / idle / busy
    public var state: String?
    public var busyName: String?
    public var bufferMs: Double?
    public var targetMs: Double?
    public var received: Int?
    public var lost: Int?
    public var late: Int?
    public var underruns: Int?
    public var output: String?
    /// builtin / headphones（内置输出走耳机口）/ bluetooth / usb / airplay / hdmi / other
    public var transport: String?
    public var muted: Bool?
    public var volume: Double?

    public init() {}
}

/// 发送端停止发送
public struct ByeMessage: Codable, Equatable, Sendable {
    public var stream: UInt32?

    public init(stream: UInt32?) {
        self.stream = stream
    }
}
