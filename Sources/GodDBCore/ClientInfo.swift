import Foundation

/// 이 PC 와 사용자 정보 (감사 로그용). 외부 서비스에 묻지 않고 PC 안에서만 구한다.
public enum ClientInfo {
    public struct Address: Equatable, Sendable {
        public let interface: String
        public let ip: String
        /// utun / ppp / ipsec 은 보통 VPN
        public var isVPN: Bool { ["utun", "ppp", "ipsec", "tun", "tap"].contains { interface.hasPrefix($0) } }
    }

    /// macOS 로그인 계정
    public static var userName: String { NSUserName() }
    /// 계정의 전체 이름 (없으면 빈 문자열)
    public static var fullName: String { NSFullUserName() }

    /// 컴퓨터 이름 (공유 설정의 이름, 없으면 호스트 이름)
    public static var computerName: String {
        if let n = Host.current().localizedName, !n.isEmpty { return n }
        return ProcessInfo.processInfo.hostName
    }

    public static var hostName: String { ProcessInfo.processInfo.hostName }

    public static var osVersion: String {
        let v = ProcessInfo.processInfo.operatingSystemVersion
        return "macOS \(v.majorVersion).\(v.minorVersion).\(v.patchVersion)"
    }

    /// 로그 줄마다 붙이는 "사용자@컴퓨터" (공백은 - 로)
    public static let identity: String = {
        let host = computerName.replacingOccurrences(of: " ", with: "-")
        return "\(userName)@\(host)"
    }()

    /// 이 PC 의 IP 들 (루프백, 링크로컬 제외). IPv4 먼저.
    public static func addresses() -> [Address] {
        var out: [Address] = []
        var ifaddr: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&ifaddr) == 0, let first = ifaddr else { return [] }
        defer { freeifaddrs(ifaddr) }
        var cursor: UnsafeMutablePointer<ifaddrs>? = first
        while let p = cursor {
            defer { cursor = p.pointee.ifa_next }
            let flags = Int32(p.pointee.ifa_flags)
            guard flags & IFF_UP != 0, flags & IFF_LOOPBACK == 0, let sa = p.pointee.ifa_addr else { continue }
            let family = Int32(sa.pointee.sa_family)
            guard family == AF_INET || family == AF_INET6 else { continue }
            var buf = [CChar](repeating: 0, count: Int(NI_MAXHOST))
            let len = socklen_t(family == AF_INET ? MemoryLayout<sockaddr_in>.size : MemoryLayout<sockaddr_in6>.size)
            guard getnameinfo(sa, len, &buf, socklen_t(buf.count), nil, 0, NI_NUMERICHOST) == 0 else { continue }
            var ip = String(cString: buf)
            if let pct = ip.firstIndex(of: "%") { ip = String(ip[..<pct]) }
            if ip.lowercased().hasPrefix("fe80") { continue }
            out.append(Address(interface: String(cString: p.pointee.ifa_name), ip: ip))
        }
        return out.sorted { ($0.ip.contains(":") ? 1 : 0, $0.interface) < ($1.ip.contains(":") ? 1 : 0, $1.interface) }
    }

    /// 상대 호스트로 나갈 때 쓰이는 이 PC 의 IP (라우팅 표 기준, 실제로 패킷은 보내지 않음)
    public static func sourceIP(toward host: String, port: Int) -> String? {
        for target in HostResolver.addresses(host: host, port: port) {
            var hints = addrinfo()
            hints.ai_socktype = SOCK_DGRAM
            hints.ai_flags = AI_NUMERICHOST
            var res: UnsafeMutablePointer<addrinfo>?
            guard getaddrinfo(target, String(port), &hints, &res) == 0, let ai = res else { continue }
            defer { freeaddrinfo(res) }
            let fd = socket(ai.pointee.ai_family, SOCK_DGRAM, 0)
            guard fd >= 0 else { continue }
            defer { close(fd) }
            guard connect(fd, ai.pointee.ai_addr, ai.pointee.ai_addrlen) == 0 else { continue }
            var storage = sockaddr_storage()
            var len = socklen_t(MemoryLayout<sockaddr_storage>.size)
            let ok = withUnsafeMutablePointer(to: &storage) {
                $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { getsockname(fd, $0, &len) }
            } == 0
            guard ok else { continue }
            var buf = [CChar](repeating: 0, count: Int(NI_MAXHOST))
            let named = withUnsafePointer(to: &storage) {
                $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                    getnameinfo($0, len, &buf, socklen_t(buf.count), nil, 0, NI_NUMERICHOST)
                }
            }
            if named == 0 {
                let ip = String(cString: buf)
                return ip.split(separator: "%").first.map(String.init) ?? ip
            }
        }
        return nil
    }

    /// 앱 시작 로그 상세
    public static func summary() -> String {
        let ips = addresses().map { "\($0.ip) (\($0.interface)\($0.isVPN ? ", VPN" : ""))" }
        return [
            "user: \(userName)" + (fullName.isEmpty || fullName == userName ? "" : " (\(fullName))"),
            "computer: \(computerName)",
            "host: \(hostName)",
            "os: \(osVersion)",
            "ip: " + (ips.isEmpty ? "-" : ips.joined(separator: ", ")),
        ].joined(separator: "\n")
    }

    /// 접속할 때 남길 한 줄: 이 PC 에서 나가는 IP (SSH 면 바스티온으로 나가는 IP)
    public static func connectionNote(host: String, port: Int, ssh: SSHConfig?) -> String {
        if let ssh {
            let ip = sourceIP(toward: ssh.host, port: ssh.port) ?? "?"
            return "client \(ip) → ssh \(ssh.host):\(ssh.port) → \(host):\(port)"
        }
        let ip = sourceIP(toward: host, port: port) ?? "?"
        return "client \(ip) → \(host):\(port)"
    }
}
