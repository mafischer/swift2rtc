import Darwin
import Foundation
import Network
import Observation

/// An IPv4 or IPv6 address as bytes (with the IPv6 scope, e.g. the interface of a link-local address)
public struct InetAddress: Hashable, Sendable, CustomStringConvertible {
    /// 4 bytes (IPv4) or 16 (IPv6), network order
    public let bytes: [UInt8]
    /// The IPv6 scope (interface index), 0 when none
    public var scope: UInt32 = 0

    public init(bytes: [UInt8], scope: UInt32 = 0) {
        self.bytes = bytes
        self.scope = scope
    }

    /// An IPv4 or IPv6 literal ("192.168.1.5", "fe80::1", "[fe80::1]", "fe80::1%en0"); nil for host names
    public init?(_ literal: String) {
        var text = literal
        if text.hasPrefix("["), text.hasSuffix("]") { text = String(text.dropFirst().dropLast()) }
        var scopeId: UInt32 = 0
        if let percent = text.firstIndex(of: "%") {
            let name = String(text[text.index(after: percent)...])
            scopeId = UInt32(name) ?? if_nametoindex(name)
            text = String(text[..<percent])
        }
        var v4 = in_addr()
        if inet_pton(AF_INET, text, &v4) == 1 {
            self.bytes = withUnsafeBytes(of: &v4) { Array($0) }
            return
        }
        var v6 = in6_addr()
        if text.contains(":"), inet_pton(AF_INET6, text, &v6) == 1 {
            self.bytes = withUnsafeBytes(of: &v6) { Array($0) }
            self.scope = scopeId
            return
        }
        return nil
    }

    public var isV4: Bool { bytes.count == 4 }
    public var isLoopback: Bool { isV4 ? bytes[0] == 127 : bytes == [UInt8](repeating: 0, count: 15) + [1] }
    public var isMulticast: Bool { isV4 ? (bytes[0] & 0xF0) == 0xE0 : bytes[0] == 0xFF }
    public var isUnspecified: Bool { bytes.allSatisfy { $0 == 0 } }
    public var isLinkLocal: Bool { isV4 ? (bytes[0] == 169 && bytes[1] == 254) : (bytes[0] == 0xFE && (bytes[1] & 0xC0) == 0x80) }

    /// A private address: IPv4 10/8, 172.16/12, 192.168/16, link-local 169.254/16 and shared 100.64/10 (carrier NAT,
    /// VPNs such as Tailscale); IPv6 unique local fc00::/7 and link-local fe80::/10
    public var isPrivate: Bool {
        if isLoopback || isMulticast || isUnspecified { return false }
        if !isV4 { return (bytes[0] & 0xFE) == 0xFC || isLinkLocal }
        let first = bytes[0]
        let second = bytes[1]
        return first == 10 || (first == 172 && (16...31).contains(second)) || (first == 192 && second == 168) || isLinkLocal
            || (first == 100 && (64...127).contains(second))
    }

    /// "192.168.1.5", "fe80::1" (no scope)
    public var description: String {
        var buffer = [CChar](repeating: 0, count: Int(INET6_ADDRSTRLEN))
        var copy = bytes
        let family = isV4 ? AF_INET : AF_INET6
        guard inet_ntop(family, &copy, &buffer, socklen_t(buffer.count)) != nil else { return "?" }
        return Self.string(buffer)
    }

    /// A C string buffer up to its terminating zero
    private static func string(_ buffer: [CChar]) -> String {
        String(decoding: buffer.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) }, as: UTF8.self)
    }

    /// As a host in a URL: IPv6 in brackets
    public var urlHost: String { isV4 ? description : "[\(description)]" }

    /// For a connection: IPv6 with its scope (`fe80::1%en0`)
    public var hostWithScope: String {
        guard !isV4, scope != 0 else { return description }
        var name = [CChar](repeating: 0, count: Int(IF_NAMESIZE))
        guard if_indextoname(scope, &name) != nil else { return description }
        return "\(description)%\(Self.string(name))"
    }
}

/// One address of this device on its network with its prefix, e.g. 192.168.1.23/24
public struct LinkSubnet: Equatable, Sendable, CustomStringConvertible {
    public var address: InetAddress
    public var prefixLength: Int

    public init(address: InetAddress, prefixLength: Int) {
        self.address = address
        self.prefixLength = prefixLength
    }

    /// `other` is in this subnet: same family, the first `prefixLength` bits equal
    public func contains(_ other: InetAddress) -> Bool {
        let mine = address.bytes
        let theirs = other.bytes
        guard mine.count == theirs.count, (1...mine.count * 8).contains(prefixLength) else { return false }
        // An IPv6 link-local address is only meaningful on its own link: the scope must match when both carry one
        if !address.isV4, address.isLinkLocal, other.scope != 0, address.scope != 0, other.scope != address.scope { return false }
        let fullBytes = prefixLength / 8
        for index in 0..<fullBytes where mine[index] != theirs[index] { return false }
        let rest = prefixLength % 8
        if rest == 0 { return true }
        let mask = UInt8((0xFF << (8 - rest)) & 0xFF)
        return mine[fullBytes] & mask == theirs[fullBytes] & mask
    }

    public var description: String { "\(address)/\(prefixLength)" }

    /// "192.168.1.23/24"; traps on anything else (for literals in tests and configuration)
    public static func parse(_ text: String) -> LinkSubnet {
        let parts = text.split(separator: "/")
        return LinkSubnet(address: InetAddress(String(parts[0]))!, prefixLength: Int(parts[1])!)
    }
}

/// The subnets of the device's current network, and where ONVIF's plain HTTP and RTSP may go (`allowsCamera`): an
/// address in one of these subnets or in a private range (a camera answering on another subnet, through a VPN or a NAT,
/// is still a camera on a private network); never the internet. Whether the device is on a camera's subnet (`allows`)
/// also tells why a silent camera is offline. Updated live from NWPathMonitor (`start`): the addresses and netmasks
/// (getifaddrs) of the interfaces the current path can use; tests set it with `subnetsChanged`. Loopback, multicast and
/// unspecified addresses never qualify, whatever the subnets.
@MainActor
@Observable
public final class LocalNetwork {
    public private(set) var subnets: [LinkSubnet]
    /// Incremented on every change, so lists re-check their cameras
    public private(set) var generation = 0
    @ObservationIgnored private var monitor: NWPathMonitor?
    /// The same subnets for other threads (discovery's socket, an RTSP player): `allowsFromAnyThread`
    @ObservationIgnored private let snapshot: LockedValue<[LinkSubnet]>

    public init(subnets: [LinkSubnet] = []) {
        self.subnets = subnets
        snapshot = LockedValue(subnets)
    }

    /// Replaces the subnets (from `start`'s monitor, or by hand)
    public func subnetsChanged(_ subnets: [LinkSubnet]) {
        guard subnets != self.subnets else { return }
        self.subnets = subnets
        snapshot.value = subnets
        generation += 1
    }

    /// `allows` for code off the main actor
    public nonisolated func allowsFromAnyThread(_ address: InetAddress) -> Bool { Self.allows(address, in: snapshot.value) }

    public var isConnected: Bool { !subnets.isEmpty }

    /// For messages: the IPv4 subnets ("192.168.1.23/24"), else the IPv6 ones
    public func describe() -> String {
        let v4 = subnets.filter(\.address.isV4)
        return (v4.isEmpty ? subnets : v4).map(\.description).joined(separator: ", ")
    }

    /// `address` is inside one of `subnets` (and not loopback, multicast or unspecified)
    public nonisolated static func allows(_ address: InetAddress, in subnets: [LinkSubnet]) -> Bool {
        if address.isLoopback || address.isMulticast || address.isUnspecified { return false }
        return subnets.contains { $0.contains(address) }
    }

    /// `address` is inside one of the current subnets
    public func allows(_ address: InetAddress) -> Bool { Self.allows(address, in: subnets) }

    /// The first of `addresses` (one DNS answer) that is on this network, or nil
    public func pick(_ addresses: [InetAddress]) -> InetAddress? { addresses.first(where: allows) }

    /// `address` is a camera this device may talk to in plain HTTP or RTSP: on one of its subnets, or at a private
    /// address (`InetAddress.isPrivate`) while the device has a network. Every other address (the internet) is refused.
    public nonisolated static func allowsCamera(_ address: InetAddress, in subnets: [LinkSubnet]) -> Bool {
        allows(address, in: subnets) || (!subnets.isEmpty && address.isPrivate)
    }

    /// `allowsCamera` with the current subnets
    public func allowsCamera(_ address: InetAddress) -> Bool { Self.allowsCamera(address, in: subnets) }

    /// The first of `addresses` a camera may have (`allowsCamera`), on this network first, or nil
    public func pickCamera(_ addresses: [InetAddress]) -> InetAddress? { pick(addresses) ?? addresses.first(where: allowsCamera) }

    /// Follows the current network with NWPathMonitor
    public func start() {
        guard monitor == nil else { return }
        let monitor = NWPathMonitor()
        monitor.pathUpdateHandler = { [weak self] path in
            let subnets = path.status == .satisfied ? InterfaceSubnets.read(names: Set(path.availableInterfaces.map(\.name))) : []
            DispatchQueue.main.async { MainActor.assumeIsolated { self?.subnetsChanged(subnets) } }
        }
        monitor.start(queue: DispatchQueue(label: "swift2rtc.local-network"))
        self.monitor = monitor
    }
}

/// The addresses and prefixes of network interfaces (getifaddrs)
public enum InterfaceSubnets {
    /// The subnets of the interfaces named `names` (nil: every interface that is up), IPv4 and IPv6, without loopback
    public static func read(names: Set<String>?) -> [LinkSubnet] {
        var list: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&list) == 0, let first = list else { return [] }
        defer { freeifaddrs(list) }
        var result: [LinkSubnet] = []
        for pointer in sequence(first: first, next: { $0.pointee.ifa_next }) {
            let entry = pointer.pointee
            let name = String(cString: entry.ifa_name)
            guard names?.contains(name) ?? true, (entry.ifa_flags & UInt32(IFF_UP)) != 0, (entry.ifa_flags & UInt32(IFF_LOOPBACK)) == 0,
                  let address = entry.ifa_addr, let mask = entry.ifa_netmask else { continue }
            guard let ip = ipAddress(address), let maskBytes = ipAddress(mask)?.bytes, maskBytes.count == ip.bytes.count else { continue }
            let prefix = maskBytes.reduce(0) { $0 + $1.nonzeroBitCount }
            result.append(LinkSubnet(address: ip, prefixLength: prefix))
        }
        return result
    }

    /// The IPv4 or IPv6 address of a socket address, or nil for other families
    package static func ipAddress(_ sockaddrPointer: UnsafeMutablePointer<sockaddr>) -> InetAddress? {
        switch Int32(sockaddrPointer.pointee.sa_family) {
        case AF_INET:
            return sockaddrPointer.withMemoryRebound(to: sockaddr_in.self, capacity: 1) { pointer in
                var addr = pointer.pointee.sin_addr
                return InetAddress(bytes: withUnsafeBytes(of: &addr) { Array($0) })
            }
        case AF_INET6:
            return sockaddrPointer.withMemoryRebound(to: sockaddr_in6.self, capacity: 1) { pointer in
                var addr = pointer.pointee.sin6_addr
                return InetAddress(bytes: withUnsafeBytes(of: &addr) { Array($0) }, scope: pointer.pointee.sin6_scope_id)
            }
        default:
            return nil
        }
    }
}

/// Host names resolved with getaddrinfo, off the caller's thread
public enum HostResolver {
    /// The addresses of `host` (a literal is returned as is, without a lookup); throws `URLError(.cannotFindHost)`
    public static func resolve(_ host: String) async throws -> [InetAddress] {
        if let literal = InetAddress(host) { return [literal] }
        return try await Task.detached {
            var hints = addrinfo(ai_flags: AI_ADDRCONFIG, ai_family: AF_UNSPEC, ai_socktype: SOCK_STREAM, ai_protocol: 0, ai_addrlen: 0,
                                 ai_canonname: nil, ai_addr: nil, ai_next: nil)
            var result: UnsafeMutablePointer<addrinfo>?
            guard getaddrinfo(host, nil, &hints, &result) == 0, let first = result else { throw URLError(.cannotFindHost) }
            defer { freeaddrinfo(result) }
            var addresses: [InetAddress] = []
            for entry in sequence(first: first, next: { $0.pointee.ai_next }) {
                if let address = entry.pointee.ai_addr, let ip = InterfaceSubnets.ipAddress(address), !addresses.contains(ip) { addresses.append(ip) }
            }
            return addresses
        }.value
    }
}

/// A value behind a lock, for reads from any thread
package final class LockedValue<Value: Sendable>: @unchecked Sendable {
    private let lock = NSLock()
    private var stored: Value

    package init(_ value: Value) {
        stored = value
    }

    package var value: Value {
        get { lock.withLock { stored } }
        set { lock.withLock { stored = newValue } }
    }
}
