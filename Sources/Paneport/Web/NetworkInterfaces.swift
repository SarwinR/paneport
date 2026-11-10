import Foundation

enum NetworkInterfaces {
    /// This Mac's IPv4 addresses, excluding loopback and self-assigned (169.254.x.x) ones.
    static func localIPv4Addresses() -> [String] {
        var result: [String] = []
        var interfaces: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&interfaces) == 0 else { return result }
        defer { freeifaddrs(interfaces) }

        var cursor = interfaces
        while let current = cursor {
            defer { cursor = current.pointee.ifa_next }
            guard let address = current.pointee.ifa_addr, address.pointee.sa_family == UInt8(AF_INET) else { continue }
            var host = [CChar](repeating: 0, count: Int(NI_MAXHOST))
            guard getnameinfo(address, socklen_t(address.pointee.sa_len), &host, socklen_t(host.count),
                              nil, 0, NI_NUMERICHOST) == 0 else { continue }
            let text = String(cString: host)
            if !text.hasPrefix("127."), !text.hasPrefix("169.254."), !result.contains(text) {
                result.append(text)
            }
        }
        return result
    }
}
