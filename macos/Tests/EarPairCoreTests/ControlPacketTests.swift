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
        #expect(stats.endReason == .stopped, "不带 reason 的 BYE 当作手动停止")

        // 还在路上的包：不再“连上”一次
        #expect(core.ingest(factory.packet(5), from: "10.0.0.2", at: 0.035) == .ignored)
        #expect(core.ingest(factory.packet(6), from: "10.0.0.2", at: 0.04) == .ignored)
        stats = core.statistics(now: 0.04)
        #expect(stats.state == .idle)
        #expect(stats.endReason == .stopped)
        #expect(stats.packetsIgnored == 2)

        // 再打开开关：新的 streamID
        factory.streamID = 0x1234_5678
        #expect(core.ingest(factory.packet(0), from: "10.0.0.2", at: 1) == .accepted)
        stats = core.statistics(now: 1)
        #expect(stats.state == .buffering)
        #expect(stats.streamID == 0x1234_5678)
        #expect(stats.endReason == nil)
    }

    @Test("超时断开算网络问题，不算发送端停止")
    func timeoutIsNotStop() {
        let core = makeCore()
        let factory = PacketFactory()
        core.ingest(factory.packet(0), from: "10.0.0.2", at: 0)
        core.housekeeping(now: 2)
        let stats = core.statistics(now: 2)
        #expect(stats.state == .idle)
        #expect(stats.endReason == .network)
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

    @Test("BYE 的 reason：network、device 分开记；不认识的当作手动停止")
    func byeReasons() {
        for (reason, expected) in [("network", EndReason.network), ("device", .device), ("user", .stopped),
                                   ("busy", .stopped), ("新的原因", .stopped)] {
            let core = makeCore()
            let responder = makeResponder(core, Outbox())
            let factory = PacketFactory()
            core.ingest(factory.packet(0), from: "10.0.0.2", at: 0)
            send(responder, .bye, ByeMessage(stream: factory.streamID, reason: reason),
                 from: UDPEndpoint(address: "10.0.0.2", port: 1), at: 0.01)
            #expect(core.statistics(now: 0.01).endReason == expected, "reason \(reason)")
        }
        let packet = ControlPacket.encode(.bye, ByeMessage(stream: 7, reason: "network"))!
        let body = packet.withUnsafeBytes { ControlPacket.parse($0) }!.body
        #expect(String(decoding: body, as: UTF8.self) == #"{"reason":"network","stream":7}"#)
    }

    @Test("网络断开后主动联系发送端：每秒往它上次 HELLO 的来源发 STATUS，到时间或者取消就停")
    func reconnectPings() {
        let core = makeCore()
        let outbox = Outbox()
        let responder = makeResponder(core, outbox)
        let pc = UDPEndpoint(address: "10.0.0.2", port: 50_123)
        #expect(!responder.startReconnecting(to: "10.0.0.2", until: 100), "没发过 HELLO，不知道往哪发")

        send(responder, .hello, HelloMessage(name: "DESKTOP-PC", stream: 0), from: pc, at: 0)
        #expect(responder.startReconnecting(to: "10.0.0.2", until: 20))
        let before = outbox.statuses.count
        for t in stride(from: 10.0, through: 25.0, by: 0.25) { responder.tick(now: t) } // HELLO 早已过期
        let pings = outbox.statuses.dropFirst(before)
        #expect(pings.count == 10, "10…19 秒每秒一次，20 秒到期")
        #expect(pings.allSatisfy { $0.to == pc && $0.message.state == "idle" })

        #expect(responder.startReconnecting(to: "10.0.0.2", until: 100))
        responder.tick(now: 30)
        responder.stopReconnecting()
        let afterStop = outbox.statuses.count
        for t in stride(from: 31.0, through: 40.0, by: 1) { responder.tick(now: t) }
        #expect(outbox.statuses.count == afterStop, "取消之后不再发")
    }

    @Test("通知：连上、手动停止、设备断开立即发；网络断开 3 秒内恢复不发，否则发“断了”和“重新连上”或“没能连上”")
    func connectionNotices() {
        var policy = ConnectionNoticePolicy()
        #expect(policy.update(to: .connecting, now: 0).isEmpty)
        #expect(policy.update(to: .playing, now: 0.2) == [.connected])
        #expect(policy.update(to: .connecting, now: 5).isEmpty, "播放中偶尔缓冲：不算断开")
        #expect(policy.update(to: .playing, now: 5.1).isEmpty)

        // 网络抖一下，2 秒就恢复：什么都不发
        #expect(policy.update(to: .lost, now: 10).isEmpty)
        #expect(policy.tick(now: 11.9).isEmpty)
        #expect(policy.update(to: .playing, now: 12).isEmpty)

        // 断了 3 秒还没恢复：发“断了”；之后重新连上
        #expect(policy.update(to: .lost, now: 20).isEmpty)
        #expect(policy.tick(now: 22.9).isEmpty)
        #expect(policy.tick(now: 23) == [.connectionLost])
        #expect(policy.tick(now: 30).isEmpty, "只发一次")
        #expect(policy.update(to: .connecting, now: 31).isEmpty)
        #expect(policy.update(to: .playing, now: 31.2) == [.reconnected])

        // 断了以后一直没回来：60 秒后回到等待，发“没能重新连上”
        #expect(policy.update(to: .lost, now: 40).isEmpty)
        #expect(policy.tick(now: 43) == [.connectionLost])
        #expect(policy.update(to: .waiting, now: 100) == [.gaveUp])

        // 手动停止、设备断开
        #expect(policy.update(to: .playing, now: 200) == [.connected])
        #expect(policy.update(to: .stopped, now: 210) == [.stopped])
        #expect(policy.update(to: .waiting, now: 270).isEmpty)
        #expect(policy.update(to: .playing, now: 300) == [.connected])
        #expect(policy.update(to: .deviceLost, now: 310) == [.deviceLost])

        // 重新缓冲期间到了 3 秒：不发“断了”
        var buffering = ConnectionNoticePolicy()
        _ = buffering.update(to: .playing, now: 0)
        _ = buffering.update(to: .lost, now: 1)
        _ = buffering.update(to: .connecting, now: 3.5)
        #expect(buffering.tick(now: 4.5).isEmpty)
        #expect(buffering.update(to: .playing, now: 4.6).isEmpty)
    }
}

@Suite("待机（发送端没有声音时停发音频包）")
struct StandbyTests {
    private let pc = "10.0.0.2"

    /// 播放 0.2 秒（0–39 号包），然后发送端说待机：恢复后第一个包是 40 号
    private func playThenStandby(_ core: ReceiverCore, _ factory: PacketFactory) {
        for i in 0..<40 {
            core.ingest(factory.packet(i), from: pc, at: Double(i) * 0.005)
            _ = core.renderStereo(240)
        }
        #expect(core.statistics(now: 0.2).state == .playing)
        core.enterStandby(stream: factory.streamID, from: pc, resumeSequence: 40, now: 0.21)
    }

    /// 40 号包起接着发（发送端停了一会儿，序号和采样时间是接着的）
    private func resume(_ core: ReceiverCore, _ factory: PacketFactory, at start: Double) {
        for i in 40..<60 {
            core.ingest(factory.packet(i), from: pc, at: start + Double(i - 40) * 0.005)
            _ = core.renderStereo(240)
        }
    }

    @Test("待机时不按 1 秒没包算断开、不算卡顿；6 秒收不到 HELLO 才算网络断开")
    func standbyKeepsStream() {
        let core = makeCore()
        let factory = PacketFactory()
        playThenStandby(core, factory)
        let underruns = core.statistics(now: 0.21).underruns
        for t in stride(from: 0.3, through: 5.0, by: 0.1) {
            _ = core.renderStereo(480)
            core.housekeeping(now: t)
        }
        #expect(core.statistics(now: 5).state == .standby)
        #expect(core.statistics(now: 5).underruns == underruns, "待机不算卡顿")
        core.enterStandby(stream: factory.streamID, from: pc, resumeSequence: 40, now: 5) // 每 2 秒一次的 HELLO
        core.housekeeping(now: 10.9)
        #expect(core.statistics(now: 10.9).state == .standby, "上次 HELLO 之后还不到 6 秒")
        core.housekeeping(now: 11.1)
        let stats = core.statistics(now: 11.1)
        #expect(stats.state == .idle && stats.endReason == .network, "HELLO 停了 6 秒：发送端不见了")
    }

    @Test("从 seq 号包恢复：重新缓冲后播放，不算丢包也不算抖动；暂停前发出、晚到的包忽略")
    func resumeFromSequence() {
        let core = makeCore()
        let factory = PacketFactory()
        playThenStandby(core, factory)
        #expect(core.ingest(factory.packet(39), from: pc, at: 0.3) == .ignored, "暂停前最后一个包晚到")
        #expect(core.statistics(now: 0.3).state == .standby)
        resume(core, factory, at: 3)
        let stats = core.statistics(now: 3.1)
        #expect(stats.state == .playing)
        #expect(stats.packetsLost == 0, "接着发的包不算丢")
        #expect(stats.jitterMs < 5, "停了 3 秒不算到达抖动")
    }

    @Test("待机的发送端照样占着 Mac：别的电脑的包忽略，6 秒没有 HELLO 之后才让它接手")
    func standbyHoldsReceiver() {
        let core = makeCore()
        let factory = PacketFactory()
        playThenStandby(core, factory)
        var other = PacketFactory()
        other.streamID = 0x0102_0304
        #expect(core.ingest(other.packet(0), from: "10.0.0.9", at: 3) == .ignored)
        #expect(core.statistics(now: 3).state == .standby)
        core.housekeeping(now: 6.3) // 上次 HELLO 在 0.21 秒
        #expect(core.statistics(now: 6.3).state == .idle)
        #expect(core.ingest(other.packet(1), from: "10.0.0.9", at: 6.4) == .accepted)
        #expect(core.statistics(now: 6.4).senderAddress == "10.0.0.9")
    }

    @Test("待机中电脑换了 IP（比如插上网线）：同一个流的包照样恢复")
    func resumeFromNewAddress() {
        let core = makeCore()
        let factory = PacketFactory()
        playThenStandby(core, factory)
        for i in 40..<60 {
            core.ingest(factory.packet(i), from: "10.0.0.7", at: 3 + Double(i - 40) * 0.005)
            _ = core.renderStereo(240)
        }
        let stats = core.statistics(now: 3.1)
        #expect(stats.state == .playing)
        #expect(stats.jitterMs < 5)
    }

    @Test("恢复之后晚到的待机 HELLO 不会再把流停下")
    func staleStandbyHello() {
        let core = makeCore()
        let factory = PacketFactory()
        playThenStandby(core, factory)
        resume(core, factory, at: 3)
        core.enterStandby(stream: factory.streamID, from: pc, resumeSequence: 40, now: 3.2)
        #expect(core.statistics(now: 3.2).state == .playing)
    }

    @Test("HELLO 里的 standby 让当前流待机；STATUS 报 standby 并声明支持待机；别的流的 HELLO 不管；BYE 照常停止")
    func helloStandbyAndStatus() throws {
        let core = makeCore()
        let outbox = Outbox()
        let responder = makeResponder(core, outbox)
        let factory = PacketFactory()
        let endpoint = UDPEndpoint(address: pc, port: 50_123)
        for i in 0..<40 {
            core.ingest(factory.packet(i), from: pc, at: Double(i) * 0.005)
            _ = core.renderStereo(240)
        }
        send(responder, .hello, HelloMessage(name: "DESKTOP-PC", stream: factory.streamID &+ 1, standby: true, seq: 40),
             from: endpoint, at: 0.21)
        #expect(core.statistics(now: 0.21).state == .playing, "别的流")

        send(responder, .hello, HelloMessage(name: "DESKTOP-PC", stream: factory.streamID, standby: true, seq: 40),
             from: endpoint, at: 0.22)
        #expect(core.statistics(now: 0.22).state == .standby)
        let status = try #require(outbox.statuses.last?.message)
        #expect(status.state == "standby" && status.stream == factory.streamID)
        #expect(status.features == ["standby"])

        send(responder, .bye, ByeMessage(stream: factory.streamID, reason: "user"), from: endpoint, at: 1)
        let stats = core.statistics(now: 1)
        #expect(stats.state == .idle && stats.endReason == .stopped)

        // Windows 发来的 JSON
        let wire = ControlPacket.decode(HelloMessage.self, from: Data(#"{"stream":7,"standby":true,"seq":42}"#.utf8))
        #expect(wire == HelloMessage(stream: 7, standby: true, seq: 42))
    }
}
