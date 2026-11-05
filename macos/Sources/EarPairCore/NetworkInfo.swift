import Darwin

public enum NetworkInfo {
    /// 本机的局域网 IPv4 地址（跳过回环和未启用的网卡），有线 / Wi‑Fi（en*）排在前面。
    public static func localIPv4Addresses() -> [String] {
        var head: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&head) == 0, let first = head else { return [] }
        defer { freeifaddrs(head) }

        var found: [(name: String, address: String)] = []
        for pointer in sequence(first: first, next: { $0.pointee.ifa_next }) {
            let entry = pointer.pointee
            guard let address = entry.ifa_addr, address.pointee.sa_family == sa_family_t(AF_INET) else { continue }
            let flags = Int32(entry.ifa_flags)
            guard flags & IFF_UP != 0, flags & IFF_LOOPBACK == 0 else { continue }
            var host = [CChar](repeating: 0, count: Int(NI_MAXHOST))
            guard getnameinfo(address, socklen_t(address.pointee.sa_len), &host, socklen_t(host.count),
                              nil, 0, NI_NUMERICHOST) == 0 else { continue }
            let name = String(cString: entry.ifa_name)
            let text = host.withUnsafeBufferPointer { String(cString: $0.baseAddress!) }
            found.append((name, text))
        }
        func rank(_ name: String) -> Int { name.hasPrefix("en") ? 0 : 1 }
        return found
            .sorted { (rank($0.name), $0.name) < (rank($1.name), $1.name) }
            .map(\.address)
    }
}
