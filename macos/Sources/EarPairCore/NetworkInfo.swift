import Darwin
import SystemConfiguration

/// 本机的一个局域网地址
public struct LocalAddress: Hashable, Sendable {
    /// 网卡在系统设置里的名字，比如“Wi-Fi”“以太网”
    public var name: String
    public var address: String

    public init(name: String, address: String) {
        self.name = name
        self.address = address
    }
}

public enum NetworkInfo {
    /// 本机的局域网 IPv4 地址，按网卡排序（en0 通常是 Wi-Fi 或内置网口）。
    /// 跳过回环、未启用的网卡，以及代理 / VPN / 虚拟机软件建的虚拟网卡：Windows 电脑连不到那些地址。
    /// 只有虚拟网卡有地址时，退回列出全部。
    public static func localAddresses() -> [LocalAddress] {
        var head: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&head) == 0, let first = head else { return [] }
        defer { freeifaddrs(head) }

        var all: [(interface: String, address: String)] = []
        for pointer in sequence(first: first, next: { $0.pointee.ifa_next }) {
            let entry = pointer.pointee
            guard let address = entry.ifa_addr, address.pointee.sa_family == sa_family_t(AF_INET) else { continue }
            let flags = Int32(entry.ifa_flags)
            guard flags & IFF_UP != 0, flags & IFF_LOOPBACK == 0 else { continue }
            var host = [CChar](repeating: 0, count: Int(NI_MAXHOST))
            guard getnameinfo(address, socklen_t(address.pointee.sa_len), &host, socklen_t(host.count),
                              nil, 0, NI_NUMERICHOST) == 0 else { continue }
            let interface = String(cString: entry.ifa_name)
            let text = host.withUnsafeBufferPointer { String(cString: $0.baseAddress!) }
            all.append((interface, text))
        }

        func rank(_ interface: String) -> Int { interface.hasPrefix("en") ? 0 : 1 }
        all.sort { (rank($0.interface), $0.interface) < (rank($1.interface), $1.interface) }

        let names = hardwareInterfaceNames()
        let physical = all.compactMap { entry in
            names[entry.interface].map { LocalAddress(name: $0, address: entry.address) }
        }
        return physical.isEmpty ? all.map { LocalAddress(name: $0.interface, address: $0.address) } : physical
    }

    public static func localIPv4Addresses() -> [String] {
        localAddresses().map(\.address)
    }

    /// 系统认识的网卡（Wi-Fi、以太网、雷雳网桥……）：BSD 名 → 显示名
    private static func hardwareInterfaceNames() -> [String: String] {
        guard let interfaces = SCNetworkInterfaceCopyAll() as? [SCNetworkInterface] else { return [:] }
        var names: [String: String] = [:]
        for interface in interfaces {
            guard let bsdName = SCNetworkInterfaceGetBSDName(interface) as String?,
                  let displayName = SCNetworkInterfaceGetLocalizedDisplayName(interface) as String? else { continue }
            names[bsdName] = displayName
        }
        return names
    }
}
