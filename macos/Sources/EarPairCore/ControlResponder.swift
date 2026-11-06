import Foundation

/// 接收端这一侧的控制包处理（协议见 protocol/control-packet.md）：
/// 记下发送端的名字和回包地址，每秒回一个 STATUS；收到 BYE 立即结束那个流。
/// handle 和 tick 在 UDP 接收线程上调用；其余方法任何线程都可以调用。
public final class ControlResponder: @unchecked Sendable {
    /// 接收端自己的信息，会写进 STATUS
    public struct LocalInfo: Equatable, Sendable {
        public var id: String
        public var name: String
        /// laptop / desktop
        public var kind: String?
        public var app: String
        public var output: String?
        public var transport: String?
        public var muted = false
        public var volume = 1.0

        public init(id: String, name: String, kind: String? = nil, app: String, output: String? = nil,
                    transport: String? = nil, muted: Bool = false, volume: Double = 1) {
            self.id = id
            self.name = name
            self.kind = kind
            self.app = app
            self.output = output
            self.transport = transport
            self.muted = muted
            self.volume = volume
        }
    }

    private struct Peer {
        var name: String?
        var stream: UInt32
        var lastSeen: Double
    }

    /// 多久没收到 HELLO 就不再回 STATUS
    static let peerTimeout = 6.0
    static let statusInterval = 1.0

    private let core: ReceiverCore
    private let send: (Data, UDPEndpoint) -> Void
    private let lock = UnfairLock()
    private var info: LocalInfo
    private var peers: [UDPEndpoint: Peer] = [:]
    private var namesByAddress: [String: String] = [:]
    /// 每个发送端最近一次 HELLO 的来源（地址和端口）：网络断开后往这里联系它
    private var endpoints: [String: UDPEndpoint] = [:]
    private var reconnect: (endpoint: UDPEndpoint, until: Double)?
    private var kindsByAddress: [String: DeviceKind] = [:]
    private var lastStatusAt = -Double.infinity

    public init(core: ReceiverCore, info: LocalInfo, send: @escaping (Data, UDPEndpoint) -> Void) {
        self.core = core
        self.info = info
        self.send = send
    }

    public func update(_ newInfo: LocalInfo) {
        lock.withLock { info = newInfo }
    }

    /// 发送端在 HELLO 里报的名字（比如 DESKTOP-7Q2）；没收到过就是 nil
    public func senderName(for address: String) -> String? {
        lock.withLock { namesByAddress[address] }
    }

    /// 发送端在 HELLO 里报的设备类型；没收到过或者不认识就是 nil
    public func senderKind(for address: String) -> DeviceKind? {
        lock.withLock { kindsByAddress[address] }
    }

    /// 网络断开后主动联系发送端：到 deadline 之前，每秒往它最近一次 HELLO 的来源发一个 STATUS。
    /// 发送端如果因为联系不上 Mac 暂停了，收到就会马上恢复发送。不知道它的地址（没发过 HELLO）时返回 false
    @discardableResult
    public func startReconnecting(to address: String, until deadline: Double) -> Bool {
        lock.withLock {
            guard let endpoint = endpoints[address] else { return false }
            reconnect = (endpoint, deadline)
            return true
        }
    }

    public func stopReconnecting() {
        lock.withLock { reconnect = nil }
    }

    // MARK: - 接收线程

    public func handle(_ bytes: UnsafeRawBufferPointer, from sender: UDPEndpoint, now: Double) {
        guard let (kind, body) = ControlPacket.parse(bytes) else { return }
        switch kind {
        case .hello:
            guard let hello = ControlPacket.decode(HelloMessage.self, from: body) else { return }
            lock.withLock {
                peers[sender] = Peer(name: hello.name, stream: hello.stream ?? 0, lastSeen: now)
                endpoints[sender.address] = sender
                if let name = hello.name, !name.isEmpty { namesByAddress[sender.address] = name }
                if let kind = DeviceKind(protocolValue: hello.kind) { kindsByAddress[sender.address] = kind }
            }
            reply(to: sender, now: now)
        case .bye:
            guard let bye = ControlPacket.decode(ByeMessage.self, from: body) else { return }
            if let stream = bye.stream {
                core.endStream(stream, from: sender.address, reason: EndReason(byeReason: bye.reason))
            }
            _ = lock.withLock { peers.removeValue(forKey: sender) }
        case .status:
            break // 接收端不处理 STATUS
        }
    }

    public func tick(now: Double) {
        guard now - lastStatusAt >= Self.statusInterval else { return }
        lastStatusAt = now
        let (active, target): ([UDPEndpoint], UDPEndpoint?) = lock.withLock {
            peers = peers.filter { now - $0.value.lastSeen < 30 }
            if let current = reconnect, now >= current.until { reconnect = nil }
            return (peers.filter { now - $0.value.lastSeen < Self.peerTimeout }.map(\.key), reconnect?.endpoint)
        }
        for peer in active { reply(to: peer, now: now) }
        if let target, !active.contains(target) { reply(to: target, now: now) }
    }

    private func reply(to peer: UDPEndpoint, now: Double) {
        let status = makeStatus(for: peer.address, now: now)
        if let packet = ControlPacket.encode(.status, status) { send(packet, peer) }
    }

    /// 站在某个发送端的角度描述接收状态
    func makeStatus(for address: String, now: Double) -> StatusMessage {
        let stats = core.statistics(now: now)
        let (local, names) = lock.withLock { (info, namesByAddress) }
        var status = StatusMessage()
        status.id = local.id
        status.name = local.name
        status.kind = local.kind
        status.app = local.app
        status.output = local.output
        status.transport = local.transport
        status.muted = local.muted
        status.volume = local.volume
        if stats.state != .idle, let current = stats.senderAddress {
            if current == address {
                status.state = stats.state == .playing ? "playing" : "buffering"
                status.stream = stats.streamID
                status.bufferMs = (stats.bufferedMs * 10).rounded() / 10
                status.targetMs = stats.targetMs
                status.received = stats.packetsReceived
                status.lost = stats.packetsLost
                status.late = stats.packetsLate
                status.underruns = stats.underruns
            } else {
                status.state = "busy"
                status.busyName = names[current] ?? current
                status.stream = 0
            }
        } else {
            status.state = "idle"
            status.stream = 0
        }
        return status
    }
}
