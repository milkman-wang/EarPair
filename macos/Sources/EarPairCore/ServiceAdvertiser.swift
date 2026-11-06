import dnssd
import Foundation
import os

private let bonjourLog = Logger(subsystem: "app.earpair", category: "bonjour")

/// 用 Bonjour（mDNS / DNS-SD）在局域网里广播“这台 Mac 在 UDP 某端口接收 EarPair”，
/// Windows 端据此自动列出可选的 Mac，不用手动输入 IP。服务类型 _earpair._udp，实例名是电脑名。
public final class ServiceAdvertiser {
    public static let serviceType = "_earpair._udp"

    private var service: DNSServiceRef?

    public init() {}

    deinit { stop() }

    /// 开始广播。name 为 nil 时用系统的电脑名（并在电脑名变化时自动跟着变）；id 是接收端的固定 id；
    /// kind 是 laptop / desktop，Windows 端在连接之前就能画对图标。
    public func start(port: UInt16, name: String? = nil, id: String? = nil, kind: DeviceKind? = nil) {
        stop()
        // TXT 记录：协议版本，方便以后不兼容时区分
        var txt = TXTRecordRef()
        TXTRecordCreate(&txt, 0, nil)
        defer { TXTRecordDeallocate(&txt) }
        let version = "1"
        _ = version.withCString { TXTRecordSetValue(&txt, "v", UInt8(strlen($0)), $0) }
        if let id {
            _ = id.withCString { TXTRecordSetValue(&txt, "id", UInt8(strlen($0)), $0) }
        }
        if let kind {
            _ = kind.rawValue.withCString { TXTRecordSetValue(&txt, "kind", UInt8(strlen($0)), $0) }
        }

        var ref: DNSServiceRef?
        // 注册结果（成功的名字，或者被拒绝之类的错误）只记进系统日志，方便排查
        let reply: DNSServiceRegisterReply = { _, _, error, name, _, _, _ in
            if error == kDNSServiceErr_NoError {
                bonjourLog.info("Bonjour 广播：\(name.map { String(cString: $0) } ?? "?", privacy: .public)")
            } else {
                bonjourLog.error("Bonjour 广播失败：\(error)")
            }
        }
        let error = DNSServiceRegister(&ref, 0, 0, name, Self.serviceType, nil, nil,
                                       port.bigEndian, TXTRecordGetLength(&txt), TXTRecordGetBytesPtr(&txt),
                                       reply, nil)
        guard error == kDNSServiceErr_NoError, let ref else {
            bonjourLog.error("Bonjour 注册失败：\(error)")
            return
        }
        // 注册结果通过 mDNSResponder 的回调送回；这里不需要结果，只要把连接挂在主队列上即可
        DNSServiceSetDispatchQueue(ref, .main)
        service = ref
    }

    public func stop() {
        if let service {
            DNSServiceRefDeallocate(service)
            self.service = nil
        }
    }
}
