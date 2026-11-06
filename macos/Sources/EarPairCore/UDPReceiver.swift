import Darwin
import Foundation
import os

private let networkLog = Logger(subsystem: "app.earpair", category: "udp")

public enum UDPReceiverError: Error, LocalizedError {
    case socketFailed(String)
    case bindFailed(port: UInt16, code: Int32, reason: String)

    /// 端口号先转成文字再放进句子：按数字插值会被加上千位分隔符（“47,800”）
    public var errorDescription: String? {
        switch self {
        case .socketFailed(let reason):
            return String(localized: "Can’t create a UDP socket: \(reason)", bundle: .module)
        case .bindFailed(let port, let code, _) where code == EADDRINUSE:
            let number = String(port)
            return String(localized: "Port \(number) is in use by another app, so EarPair can’t receive sound from Windows.",
                          bundle: .module)
        case .bindFailed(let port, _, let reason):
            let number = String(port)
            return String(localized: "Can’t listen on port \(number): \(reason)", bundle: .module)
        }
    }
}

/// UDP 对端：IPv4 地址和端口
public struct UDPEndpoint: Hashable, Sendable {
    public var address: String
    public var port: UInt16
    fileprivate var raw: in_addr_t

    public init(address: String, port: UInt16) {
        self.address = address
        self.port = port
        raw = inet_addr(address)
    }

    fileprivate init(_ socket: sockaddr_in, text: String) {
        address = text
        port = UInt16(bigEndian: socket.sin_port)
        raw = socket.sin_addr.s_addr
    }
}

/// 在独立线程上阻塞接收 UDP 包（IPv4，所有网卡）。音频包（EARP）交给 onPacket，控制包（EARC）交给 onControl。
public final class UDPReceiver: @unchecked Sendable {
    /// 收到一个音频包：数据、发送端 IP、单调时钟（秒）。在接收线程上调用。
    public typealias PacketHandler = (_ bytes: UnsafeRawBufferPointer, _ sender: String, _ now: Double) -> Void
    /// 收到一个控制包：数据、发送端地址和端口、单调时钟。在接收线程上调用。
    public typealias ControlHandler = (_ bytes: UnsafeRawBufferPointer, _ sender: UDPEndpoint, _ now: Double) -> Void
    /// 每隔约 0.25 秒调用一次（不管有没有包），用来做超时判断。在接收线程上调用。
    public typealias TickHandler = (_ now: Double) -> Void

    public let port: UInt16
    private let onPacket: PacketHandler
    private let onControl: ControlHandler?
    private let onTick: TickHandler
    private let lock = UnfairLock()
    private var running = false
    private var socketFD: Int32 = -1

    public init(port: UInt16, onPacket: @escaping PacketHandler, onControl: ControlHandler? = nil,
                onTick: @escaping TickHandler) {
        self.port = port
        self.onPacket = onPacket
        self.onControl = onControl
        self.onTick = onTick
    }

    /// 从接收端口发一个包（回 STATUS 用）。在接收线程的回调里调用最安全；套接字没开时什么也不做。
    @discardableResult
    public func send(_ data: Data, to endpoint: UDPEndpoint) -> Bool {
        let fd = lock.withLock { running ? socketFD : -1 }
        guard fd >= 0 else { return false }
        var address = sockaddr_in()
        address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        address.sin_family = sa_family_t(AF_INET)
        address.sin_port = endpoint.port.bigEndian
        address.sin_addr.s_addr = endpoint.raw
        let sent = data.withUnsafeBytes { bytes in
            withUnsafePointer(to: address) {
                $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                    sendto(fd, bytes.baseAddress, bytes.count, 0, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
                }
            }
        }
        if sent != data.count {
            let code = errno
            networkLog.error("回包到 \(endpoint.address, privacy: .public):\(endpoint.port) 失败：\(String(cString: strerror(code)), privacy: .public)")
        }
        return sent == data.count
    }

    public func start() throws {
        let fd = socket(AF_INET, SOCK_DGRAM, IPPROTO_UDP)
        guard fd >= 0 else { throw UDPReceiverError.socketFailed(Self.errnoDescription()) }

        var yes: Int32 = 1
        setsockopt(fd, SOL_SOCKET, SO_REUSEADDR, &yes, socklen_t(MemoryLayout<Int32>.size))
        var receiveBufferSize: Int32 = 1 << 20
        setsockopt(fd, SOL_SOCKET, SO_RCVBUF, &receiveBufferSize, socklen_t(MemoryLayout<Int32>.size))
        // 200 ms 超时：没有包时也能定期醒来，检查是否该退出
        var timeout = timeval(tv_sec: 0, tv_usec: 200_000)
        setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &timeout, socklen_t(MemoryLayout<timeval>.size))

        var address = sockaddr_in()
        address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        address.sin_family = sa_family_t(AF_INET)
        address.sin_port = port.bigEndian
        address.sin_addr.s_addr = 0  // INADDR_ANY
        let bound = withUnsafePointer(to: address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                bind(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        guard bound == 0 else {
            let code = errno
            let reason = Self.errnoDescription()
            close(fd)
            throw UDPReceiverError.bindFailed(port: port, code: code, reason: reason)
        }

        lock.withLock {
            running = true
            socketFD = fd
        }
        let thread = Thread { [self] in receiveLoop(fd: fd) }
        thread.name = "EarPair UDP receiver"
        thread.qualityOfService = .userInteractive
        thread.start()
    }

    /// 停止接收。接收线程最多 0.2 秒后退出并关闭套接字。
    public func stop() {
        lock.withLock { running = false }
    }

    private var isRunning: Bool { lock.withLock { running } }

    private func receiveLoop(fd: Int32) {
        let capacity = 65_536
        let buffer = UnsafeMutableRawPointer.allocate(byteCount: capacity, alignment: 16)
        defer {
            buffer.deallocate()
            lock.withLock { socketFD = -1 }
            close(fd)
        }
        var lastTick = 0.0
        var cachedAddress: in_addr_t = 0
        var cachedText = ""

        while isRunning {
            var from = sockaddr_in()
            var fromLength = socklen_t(MemoryLayout<sockaddr_in>.size)
            let count = withUnsafeMutablePointer(to: &from) {
                $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                    recvfrom(fd, buffer, capacity, 0, $0, &fromLength)
                }
            }
            let now = MonotonicClock.now()
            if count > 0 {
                if from.sin_addr.s_addr != cachedAddress || cachedText.isEmpty {
                    cachedAddress = from.sin_addr.s_addr
                    cachedText = Self.ipString(from.sin_addr)
                }
                let bytes = UnsafeRawBufferPointer(start: buffer, count: count)
                if let onControl, ControlPacket.isControl(bytes) {
                    onControl(bytes, UDPEndpoint(from, text: cachedText), now)
                } else {
                    onPacket(bytes, cachedText, now)
                }
            }
            if now - lastTick >= 0.25 {
                lastTick = now
                onTick(now)
            }
        }
    }

    private static func ipString(_ address: in_addr) -> String {
        var address = address
        var text = [CChar](repeating: 0, count: Int(INET_ADDRSTRLEN))
        guard inet_ntop(AF_INET, &address, &text, socklen_t(INET_ADDRSTRLEN)) != nil else { return "?" }
        return text.withUnsafeBufferPointer { String(cString: $0.baseAddress!) }
    }

    private static func errnoDescription() -> String {
        String(cString: strerror(errno))
    }
}
