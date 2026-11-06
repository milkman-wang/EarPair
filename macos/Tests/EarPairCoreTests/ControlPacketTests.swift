import EarPairCore
import Foundation
import Testing

/// 收集 ControlResponder 发出的包
private final class Outbox: @unchecked Sendable {
    var sent: [(data: Data, to: UDPEndpoint)] = []

    var statuses: [(message: StatusMessage, to: UDPEndpoint)] {
        sent.compactMap { item in
            item.data.withUnsafeBytes { bytes in
                guard let (kind, body) = ControlPacket.parse(bytes), kind == .status,
                      let status = ControlPacket.decode(StatusMessage.self, from: body) else { return nil }
                return (status, item.to)
            }
        }
    }
}

private func send(_ responder: ControlResponder, _ kind: ControlPacket.Kind, _ message: some Encodable,
                  from endpoint: UDPEndpoint, at now: Double) {
    let packet = ControlPacket.encode(kind, message)!
    packet.withUnsafeBytes { responder.handle($0, from: endpoint, now: now) }
}

private func makeResponder(_ core: ReceiverCore, _ outbox: Outbox) -> ControlResponder {
    ControlResponder(core: core, info: .init(id: "5f0e3c2a9b7d4e1f8a6c2b9d0e1f3a4b", name: "测试 Mac", app: "0.2.0",
                                             output: "AirPods Pro", transport: "bluetooth")) { data, endpoint in
        outbox.sent.append((data, endpoint))
    }
}

@Suite("控制包（EARC）")
struct ControlPacketTests {
    @Test("BYE 和协议文档里的测试向量逐字节一致")
    func byeTestVector() throws {
        let packet = try #require(ControlPacket.encode(.bye, body: Data(#"{"stream":16909060}"#.utf8)))
        let expected: [UInt8] = [0x45, 0x41, 0x52, 0x43, 0x01, 0x05, 0x13, 0x00, 0x7B, 0x22, 0x73, 0x74, 0x72, 0x65,
                                 0x61, 0x6D, 0x22, 0x3A, 0x31, 0x36, 0x39, 0x30, 0x39, 0x30, 0x36, 0x30, 0x7D]
        #expect(Array(packet) == expected)
        let parsed = packet.withUnsafeBytes { ControlPacket.parse($0) }
        #expect(parsed?.kind == .bye)
        #expect(parsed.flatMap { ControlPacket.decode(ByeMessage.self, from: $0.body) } == ByeMessage(stream: 16_909_060))
    }

    @Test("长度不符、版本不对、类型不认识、不是 EARC 的包都丢掉；多余的 JSON 字段忽略")
    func rejectsMalformed() {
        let good = ControlPacket.encode(.hello, body: Data(#"{"name":"PC","extra":[1,2]}"#.utf8))!
        func parse(_ bytes: [UInt8]) -> (kind: ControlPacket.Kind, body: Data)? { bytes.withUnsafeBytes { ControlPacket.parse($0) } }
        #expect(parse(Array(good))?.kind == .hello)
        #expect(ControlPacket.decode(HelloMessage.self, from: parse(Array(good))!.body)?.name == "PC")
        #expect(parse(Array(good) + [0x20]) == nil, "长度字段和实际长度不符")
        var version = Array(good)
        version[4] = 2
        #expect(parse(version) == nil, "版本不对")
        var kind = Array(good)
        kind[5] = 9
        #expect(parse(kind) == nil, "类型不认识")
        var audio = Array(good)
        audio[3] = 0x50 // EARP
        #expect(parse(audio) == nil, "音频包")
        #expect(ControlPacket.encode(.status, body: Data(count: 1400)) == nil, "超过 1400 字节")
    }

    @Test("HELLO 立即回 STATUS；之后每秒回一次，6 秒没有 HELLO 就不再回")
    func helloGetsStatus() {
        let core = makeCore()
        let outbox = Outbox()
        let responder = makeResponder(core, outbox)
        let pc = UDPEndpoint(address: "10.0.0.2", port: 51_234)
        send(responder, .hello, HelloMessage(sender: "abc", name: "DESKTOP-7Q2", app: "0.2.0", stream: 0), from: pc, at: 0)
        #expect(outbox.statuses.count == 1)
        #expect(outbox.statuses.first?.to == pc)
        #expect(outbox.statuses.first?.message.state == "idle")
        #expect(outbox.statuses.first?.message.name == "测试 Mac")
        #expect(responder.senderName(for: "10.0.0.2") == "DESKTOP-7Q2")

        for t in stride(from: 0.25, through: 10.0, by: 0.25) { responder.tick(now: t) }
        // 立即回的 1 次 + 0.25、1.25 … 5.25 秒各 1 次；6.25 秒时 HELLO 已经超过 6 秒，不再回
        #expect(outbox.statuses.count == 7)
    }

    @Test("对正在播的发送端回 buffering / playing；对另一台电脑回 busy 和正在播的那台的名字")
    func playingAndBusy() {
        let core = makeCore()
        let outbox = Outbox()
        let responder = makeResponder(core, outbox)
        let pc = UDPEndpoint(address: "10.0.0.2", port: 50_000)
        let other = UDPEndpoint(address: "10.0.0.9", port: 50_001)
        let factory = PacketFactory()
        send(responder, .hello, HelloMessage(name: "DESKTOP-7Q2", stream: factory.streamID), from: pc, at: 0)
        core.ingest(factory.packet(0), from: "10.0.0.2", at: 0.01)
        send(responder, .hello, HelloMessage(name: "DESKTOP-7Q2", stream: factory.streamID), from: pc, at: 0.02)
        #expect(outbox.statuses.last?.message.state == "buffering")
        #expect(outbox.statuses.last?.message.stream == factory.streamID)

        send(responder, .hello, HelloMessage(name: "LAPTOP-2", stream: 7), from: other, at: 0.03)
        let busy = outbox.statuses.last
        #expect(busy?.to == other)
        #expect(busy?.message.state == "busy")
        #expect(busy?.message.busyName == "DESKTOP-7Q2")
    }

    @Test("BYE 让当前流立即结束，不等 1 秒超时；别人发的 BYE 不算")
    func byeEndsStream() {
        let core = makeCore()
        let responder = makeResponder(core, Outbox())
        let factory = PacketFactory()
        core.ingest(factory.packet(0), from: "10.0.0.2", at: 0)
        #expect(core.statistics(now: 0).state == .buffering)

        send(responder, .bye, ByeMessage(stream: factory.streamID), from: UDPEndpoint(address: "10.0.0.9", port: 1), at: 0.1)
        #expect(core.statistics(now: 0.1).state == .buffering, "不是这个发送端的 BYE")
        send(responder, .bye, ByeMessage(stream: 12_345), from: UDPEndpoint(address: "10.0.0.2", port: 1), at: 0.1)
        #expect(core.statistics(now: 0.1).state == .buffering, "不是当前流")
        send(responder, .bye, ByeMessage(stream: factory.streamID), from: UDPEndpoint(address: "10.0.0.2", port: 1), at: 0.2)
        #expect(core.statistics(now: 0.2).state == .idle)
    }

    @Test("BYE 之后同一路流迟到的包都忽略，显示“已停止”；同一台电脑换了新流照常开始")
    func lateAfterBye() {
        let core = makeCore()
        let responder = makeResponder(core, Outbox())
        var factory = PacketFactory()
        let pc = UDPEndpoint(address: "10.0.0.2", port: 1)
        for i in 0..<5 { core.ingest(factory.packet(i), from: "10.0.0.2", at: Double(i) * 0.005) }
        send(responder, .bye, ByeMessage(stream: factory.streamID), from: pc, at: 0.03)
        var stats = core.statistics(now: 0.03)
        #expect(stats.state == .idle)
        #expect(stats.endedBySender)

        // 还在路上的包：不再“连上”一次
        #expect(core.ingest(factory.packet(5), from: "10.0.0.2", at: 0.035) == .ignored)
        #expect(core.ingest(factory.packet(6), from: "10.0.0.2", at: 0.04) == .ignored)
        stats = core.statistics(now: 0.04)
        #expect(stats.state == .idle)
        #expect(stats.endedBySender)
        #expect(stats.packetsIgnored == 2)

        // 再打开开关：新的 streamID
        factory.streamID = 0x1234_5678
        #expect(core.ingest(factory.packet(0), from: "10.0.0.2", at: 1) == .accepted)
        stats = core.statistics(now: 1)
        #expect(stats.state == .buffering)
        #expect(stats.streamID == 0x1234_5678)
        #expect(!stats.endedBySender)
    }

    @Test("超时断开不算发送端停止")
    func timeoutIsNotStop() {
        let core = makeCore()
        let factory = PacketFactory()
        core.ingest(factory.packet(0), from: "10.0.0.2", at: 0)
        core.housekeeping(now: 2)
        let stats = core.statistics(now: 2)
        #expect(stats.state == .idle)
        #expect(!stats.endedBySender)
        // 超时之后同一路流又来了包（比如网络恢复）：照常重新开始
        #expect(core.ingest(factory.packet(1), from: "10.0.0.2", at: 2.1) == .accepted)
    }

    @Test("HELLO 测试向量；kind 往返编解码，不认识的值当作未知；STATUS 带上接收端的 kind 和 headphones")
    func kindField() throws {
        let probe = try #require(ControlPacket.encode(.hello, HelloMessage(stream: 1)))
        #expect(Array(probe) == [0x45, 0x41, 0x52, 0x43, 0x01, 0x03, 0x0C, 0x00, 0x7B, 0x22, 0x73, 0x74, 0x72, 0x65,
                                 0x61, 0x6D, 0x22, 0x3A, 0x31, 0x7D])

        let hello = HelloMessage(sender: "abc", name: "LAPTOP-Q8", kind: "laptop", app: "0.2.0", stream: 7)
        let packet = try #require(ControlPacket.encode(.hello, hello))
        let body = try #require(packet.withUnsafeBytes { ControlPacket.parse($0) }?.body)
        #expect(ControlPacket.decode(HelloMessage.self, from: body) == hello)
        #expect(DeviceKind(protocolValue: "laptop") == .laptop)
        #expect(DeviceKind(protocolValue: "tablet") == nil)
        #expect(DeviceKind(protocolValue: nil) == nil)

        let core = makeCore()
        let outbox = Outbox()
        let responder = ControlResponder(core: core, info: .init(id: "id", name: "测试 Mac", kind: "desktop", app: "0.2.0",
                                                                 output: "外置耳机", transport: "headphones")) { data, endpoint in
            outbox.sent.append((data, endpoint))
        }
        let pc = UDPEndpoint(address: "10.0.0.5", port: 50_000)
        send(responder, .hello, hello, from: pc, at: 0)
        #expect(responder.senderKind(for: "10.0.0.5") == .laptop)
        let status = try #require(outbox.statuses.last?.message)
        #expect(status.kind == "desktop")
        #expect(status.transport == "headphones")

        // 旧版本（没有 kind）和多出来的字段
        let legacy = ControlPacket.encode(.hello, body: Data(#"{"name":"OLD-PC","stream":0,"future":{"x":1}}"#.utf8))!
        legacy.withUnsafeBytes { responder.handle($0, from: UDPEndpoint(address: "10.0.0.6", port: 1), now: 0.1) }
        #expect(responder.senderName(for: "10.0.0.6") == "OLD-PC")
        #expect(responder.senderKind(for: "10.0.0.6") == nil)
    }
}
