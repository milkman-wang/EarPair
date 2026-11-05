import Darwin
import Foundation

public enum UDPReceiverError: Error, LocalizedError {
    case socketFailed(String)
    case bindFailed(port: UInt16, reason: String)

    public var errorDescription: String? {
        switch self {
        case .socketFailed(let reason): return "无法创建 UDP 套接字：\(reason)"
        case .bindFailed(let port, let reason): return "无法监听 UDP \(port) 端口：\(reason)"
        }
    }
}

/// 在独立线程上阻塞接收 UDP 包（IPv4，所有网卡）。
public final class UDPReceiver: @unchecked Sendable {
    /// 收到一个包：数据、发送端 IP、单调时钟（秒）。在接收线程上调用。
    public typealias PacketHandler = (_ bytes: UnsafeRawBufferPointer, _ sender: String, _ now: Double) -> Void
    /// 每隔约 0.25 秒调用一次（不管有没有包），用来做超时判断。在接收线程上调用。
    public typealias TickHandler = (_ now: Double) -> Void

    public let port: UInt16
    private let onPacket: PacketHandler
    private let onTick: TickHandler
    private let lock = UnfairLock()
    private var running = false

    public init(port: UInt16, onPacket: @escaping PacketHandler, onTick: @escaping TickHandler) {
        self.port = port
        self.onPacket = onPacket
        self.onTick = onTick
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
            let reason = Self.errnoDescription()
            close(fd)
            throw UDPReceiverError.bindFailed(port: port, reason: reason)
        }

        lock.withLock { running = true }
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
                onPacket(UnsafeRawBufferPointer(start: buffer, count: count), cachedText, now)
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
