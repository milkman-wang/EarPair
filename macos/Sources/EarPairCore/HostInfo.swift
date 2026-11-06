import Foundation
import IOKit.ps
import SystemConfiguration

/// 这台 Mac 的名字和类型（界面上的音频路线、局域网广播用）。
public enum HostInfo {
    /// 系统设置 › 通用 › 关于本机里的名字，比如“milkman的MacBook Air”
    public static var computerName: String {
        if let name = SCDynamicStoreCopyComputerName(nil, nil) as String?, !name.isEmpty { return name }
        return Host.current().localizedName ?? "Mac"
    }

    /// 有内置电池的就是笔记本
    public static let isLaptop: Bool = {
        guard let info = IOPSCopyPowerSourcesInfo()?.takeRetainedValue(),
              let sources = IOPSCopyPowerSourcesList(info)?.takeRetainedValue() as? [CFTypeRef] else { return false }
        return sources.contains { source in
            guard let description = IOPSGetPowerSourceDescription(info, source)?.takeUnretainedValue() as? [String: Any]
            else { return false }
            return description[kIOPSTypeKey] as? String == kIOPSInternalBatteryType
        }
    }()

    public static var kind: DeviceKind { isLaptop ? .laptop : .desktop }
}

extension HostInfo {
    /// 反查 IP 对应的主机名（比如 Windows 电脑的“DESKTOP-7Q2”），去掉 .local / .lan 之类的后缀。
    /// 会阻塞（最多几秒），只在后台调用；查不到返回 nil。
    public static func hostName(for ip: String) -> String? {
        var hints = addrinfo(ai_flags: AI_NUMERICHOST, ai_family: AF_UNSPEC, ai_socktype: 0, ai_protocol: 0,
                             ai_addrlen: 0, ai_canonname: nil, ai_addr: nil, ai_next: nil)
        var result: UnsafeMutablePointer<addrinfo>?
        guard getaddrinfo(ip, nil, &hints, &result) == 0, let info = result else { return nil }
        defer { freeaddrinfo(result) }
        var host = [CChar](repeating: 0, count: Int(NI_MAXHOST))
        guard getnameinfo(info.pointee.ai_addr, info.pointee.ai_addrlen, &host, socklen_t(host.count),
                          nil, 0, NI_NAMEREQD) == 0 else { return nil }
        let name = host.withUnsafeBufferPointer { String(cString: $0.baseAddress!) }
        guard let first = name.split(separator: ".").first, !first.isEmpty, first != Substring(ip) else { return nil }
        return String(first)
    }
}
