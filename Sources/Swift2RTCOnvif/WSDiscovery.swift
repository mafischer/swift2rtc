import Darwin
import Foundation

/// Finds the cameras on this network; empty when none answered in time
public protocol DeviceDiscovery: AnyObject {
    /// The cameras that answered within `timeout` seconds, one entry per device
    func discover(timeout: TimeInterval) async throws -> [DiscoveredDevice]
}

/// Why a search could not run
public enum DiscoveryError: Error, Equatable, Sendable {
    /// The system refused to send the multicast probe. On iOS the app lacks the multicast networking entitlement
    /// (`com.apple.developer.networking.multicast`, granted by Apple on request), or Local Network access is off.
    case multicastNotPermitted
}

/// The WS-Discovery Probe and its ProbeMatches
public enum WSDiscoveryMessages {
    /// The name of a camera whose scopes name none
    public static let defaultName = "ONVIF Camera"
    /// The hardware of a camera whose scopes name none
    public static let defaultHardware = "Network Camera"

    /// A Probe for NetworkVideoTransmitter (every ONVIF camera)
    public static func probe(messageId: String = "urn:uuid:\(UUID().uuidString.lowercased())") -> String {
        """
        <?xml version="1.0" encoding="utf-8"?>
        <e:Envelope xmlns:e="http://www.w3.org/2003/05/soap-envelope" xmlns:w="http://schemas.xmlsoap.org/ws/2004/08/addressing" xmlns:d="http://schemas.xmlsoap.org/ws/2005/04/discovery" xmlns:dn="http://www.onvif.org/ver10/network/wsdl">
          <e:Header>
            <w:MessageID>\(messageId)</w:MessageID>
            <w:To>urn:schemas-xmlsoap-org:ws:2005:04:discovery</w:To>
            <w:Action>http://schemas.xmlsoap.org/ws/2005/04/discovery/Probe</w:Action>
          </e:Header>
          <e:Body>
            <d:Probe>
              <d:Types>dn:NetworkVideoTransmitter</d:Types>
            </d:Probe>
          </e:Body>
        </e:Envelope>
        """
    }

    /// The cameras in a ProbeMatches answer: the first HTTP address of XAddrs (IPv4 preferred), the name and hardware
    /// from the onvif:// scopes (URL-decoded; "ONVIF Camera" / "Network Camera" without), port 80 by default. Not XML or
    /// no match: empty.
    public static func parse(_ text: String) -> [DiscoveredDevice] {
        guard let xml = try? SoapXML.parse(text) else { return [] }
        return xml.descendants("ProbeMatch").compactMap { match in
            let addresses = (match.child("XAddrs")?.text ?? "").split(whereSeparator: \.isWhitespace).compactMap { address -> URLComponents? in
                guard let components = URLComponents(string: String(address)), components.scheme?.lowercased() == "http", components.host?.isEmpty == false else { return nil }
                return components
            }
            guard let uri = addresses.first(where: { !($0.host ?? "").contains(":") }) ?? addresses.first, let host = uri.host else { return nil }
            let scopes = (match.child("Scopes")?.text ?? "").split(whereSeparator: \.isWhitespace).map(String.init)
            let scope = { (kind: String) -> String? in
                guard let entry = scopes.first(where: { $0.contains("/\(kind)/") }), let range = entry.range(of: "/\(kind)/") else { return nil }
                let raw = String(entry[range.upperBound...])
                let value = raw.removingPercentEncoding ?? raw
                return value.trimmingCharacters(in: .whitespaces).isEmpty ? nil : value
            }
            let endpoint = match.path("EndpointReference", "Address")?.text ?? ""
            let url = uri.string ?? ""
            return DiscoveredDevice(endpoint: endpoint.isEmpty ? url : endpoint, name: scope("name") ?? defaultName, hardware: scope("hardware") ?? defaultHardware,
                                    host: host.trimmingCharacters(in: CharacterSet(charactersIn: "[]")), port: uri.port ?? 80, deviceURL: url)
        }
    }
}

/// WS-Discovery over UDP: the Probe to 239.255.255.250:3702 (sent twice, UDP may drop one), then every ProbeMatch until
/// the timeout, one entry per device. Answers from addresses `accept` refuses (for example outside the device's
/// subnets, `LocalNetwork.allowsFromAnyThread`) are ignored, by sender and by address. `target` is a unicast responder
/// in tests.
///
/// On an iPhone, sending multicast needs the multicast networking entitlement (iOS 14+; the Simulator does not enforce
/// it) and the user's Local Network permission. Without them `sendto` fails and the search throws
/// `DiscoveryError.multicastNotPermitted`: the caller can then ask for the address by hand.
public final class WSDiscovery: DeviceDiscovery, Sendable {
    /// The WS-Discovery multicast group
    public static let multicastAddress = "239.255.255.250"
    /// The WS-Discovery port
    public static let port: UInt16 = 3702
    /// A good default for `discover(timeout:)`
    public static let defaultTimeout: TimeInterval = 3

    private let accept: @Sendable (InetAddress) -> Bool
    private let target: (host: String, port: UInt16)
    private let logger: any Swift2RTCLogger

    /// - Parameters:
    ///   - accept: which senders and advertised addresses count
    ///   - target: where the probe goes (the multicast group by default)
    ///   - logger: where a refused probe is reported
    public init(accept: @escaping @Sendable (InetAddress) -> Bool, target: (host: String, port: UInt16) = (WSDiscovery.multicastAddress, WSDiscovery.port),
                logger: any Swift2RTCLogger = NoopLogger()) {
        self.accept = accept
        self.target = target
        self.logger = logger
    }

    public func discover(timeout: TimeInterval) async throws -> [DiscoveredDevice] {
        let accept = accept
        let target = target
        let logger = logger
        let probe = Data(WSDiscoveryMessages.probe().utf8)
        return try await Task.detached {
            try Self.run(probe: probe, target: target, timeout: timeout, accept: accept, logger: logger)
        }.value
    }

    private static func run(probe: Data, target: (host: String, port: UInt16), timeout: TimeInterval, accept: (InetAddress) -> Bool,
                            logger: any Swift2RTCLogger) throws -> [DiscoveredDevice] {
        let fd = socket(AF_INET, SOCK_DGRAM, IPPROTO_UDP)
        guard fd >= 0 else { throw DiscoveryError.multicastNotPermitted }
        defer { close(fd) }
        // Cameras answer on the local link only
        var ttl: UInt8 = 1
        setsockopt(fd, IPPROTO_IP, IP_MULTICAST_TTL, &ttl, socklen_t(MemoryLayout<UInt8>.size))
        var destination = sockaddr_in()
        destination.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        destination.sin_family = sa_family_t(AF_INET)
        destination.sin_port = target.port.bigEndian
        inet_pton(AF_INET, target.host, &destination.sin_addr)
        var sent = 0
        for _ in 0..<2 {
            let result = probe.withUnsafeBytes { buffer in
                withUnsafePointer(to: &destination) { pointer in
                    pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { sendto(fd, buffer.baseAddress, buffer.count, 0, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) }
                }
            }
            if result >= 0 { sent += 1 }
        }
        guard sent > 0 else {
            logger.log(.info, "Camera discovery: probe refused (errno \(errno))")
            throw DiscoveryError.multicastNotPermitted
        }
        var found: [String: DiscoveredDevice] = [:]
        var order: [String] = []
        let deadline = Date().addingTimeInterval(timeout)
        var buffer = [UInt8](repeating: 0, count: 65_536)
        while Date() < deadline {
            try Task.checkCancellation()
            var descriptor = pollfd(fd: fd, events: Int16(POLLIN), revents: 0)
            let wait = Int32(max(0, min(250, deadline.timeIntervalSinceNow * 1000)))
            guard poll(&descriptor, 1, wait) > 0 else { continue }
            var sender = sockaddr_storage()
            var length = socklen_t(MemoryLayout<sockaddr_storage>.size)
            let count = withUnsafeMutablePointer(to: &sender) { pointer in
                pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { recvfrom(fd, &buffer, buffer.count, 0, $0, &length) }
            }
            guard count > 0 else { continue }
            let from = withUnsafeMutablePointer(to: &sender) { pointer in
                pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { InterfaceSubnets.ipAddress($0) }
            }
            guard let from, accept(from) else { continue }
            for device in WSDiscoveryMessages.parse(String(decoding: buffer[0..<count], as: UTF8.self)) {
                if let literal = InetAddress(device.host), !accept(literal) { continue }
                if found[device.endpoint] == nil, !found.values.contains(where: { $0.deviceURL == device.deviceURL }) {
                    found[device.endpoint] = device
                    order.append(device.endpoint)
                }
            }
        }
        return order.compactMap { found[$0] }
    }
}
