import Darwin
import Foundation

/// What a camera tells about itself before any login: its WS-Discovery endpoint reference (a stable `urn:uuid:`,
/// unique per device) and the hardware of its onvif:// scopes. Either may be missing.
public struct CameraFingerprint: Equatable, Sendable {
    public var endpoint: String?
    public var hardware: String?

    public init(endpoint: String? = nil, hardware: String? = nil) {
        self.endpoint = endpoint
        self.hardware = hardware
    }

    /// From a ProbeMatch: the parser's fallbacks (device URL for a missing reference, "Network Camera") do not count
    public static func of(_ device: DiscoveredDevice) -> CameraFingerprint {
        let endpoint = device.endpoint == device.deviceURL || device.endpoint.lowercased().hasPrefix("http") ? nil : device.endpoint
        return CameraFingerprint(endpoint: endpoint, hardware: device.hardware == WSDiscoveryMessages.defaultHardware ? nil : device.hardware)
    }
}

/// Where a known camera is reached: its ONVIF device service (empty for an RTSP-only camera) and its RTSP stream
public struct ProbeTarget: Equatable, Sendable {
    /// The device service as stored (its host is replaced by the checked address)
    public var deviceURL: String
    /// The RTSP stream URI as stored (its port is used when there is no device service)
    public var streamURI: String

    public init(deviceURL: String, streamURI: String) {
        self.deviceURL = deviceURL
        self.streamURI = streamURI
    }
}

/// How a camera is checked without its login: does it answer, and which device is it
public protocol CameraProbe: AnyObject {
    /// The camera answers at `address` right now (short timeout, nothing secret sent)
    func answers(_ address: InetAddress, camera: ProbeTarget) async -> Bool
    /// What the device at `address` says it is, without credentials; nil when it says nothing
    func identify(_ address: InetAddress, camera: ProbeTarget) async -> CameraFingerprint?
}

/// Whether the device at a camera's address is that camera, decided before any credentials go to it: off the home
/// network the same private address may be another device
public enum CameraIdentity {
    /// What the comparison concluded
    public enum Trust: Equatable, Sendable {
        /// The endpoint reference recorded for this camera matches
        case verified
        /// Nothing recorded yet, and the device is plausibly the camera: allowed, its reference can be recorded once it plays
        case firstUse
        /// Another endpoint reference than the recorded one: a different device
        case mismatch
        /// Cannot tell: no reference to compare, or nothing recorded and nothing to go by off the camera's subnet
        case unverified
    }

    private static let minimumModel = 4

    /// `urn:uuid:ABC` and `uuid:abc` are the same reference
    public static func normalize(_ endpoint: String?) -> String? {
        guard var text = endpoint?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() else { return nil }
        for prefix in ["urn:", "uuid:"] where text.hasPrefix(prefix) { text.removeFirst(prefix.count) }
        return text.isEmpty ? nil : text
    }

    /// `recorded`: the reference recorded for the camera (nil: none yet). Without one, the first use is allowed on the
    /// camera's own subnet, or elsewhere when the device's hardware scope names the `model` stored for the camera.
    public static func trust(recorded: String?, seen: CameraFingerprint?, onSubnet: Bool, model: String?) -> Trust {
        let endpoint = normalize(seen?.endpoint)
        if let recorded {
            guard let endpoint else { return .unverified }
            return endpoint == normalize(recorded) ? .verified : .mismatch
        }
        return onSubnet || sameModel(model, seen?.hardware) ? .firstUse : .unverified
    }

    /// "IP8M-2493EB" and "ip8m 2493E" name the same model (one a prefix of the other, at least 4 letters or digits)
    public static func sameModel(_ stored: String?, _ hardware: String?) -> Bool {
        let clean = { (text: String?) in String((text ?? "").filter { $0.isLetter || $0.isNumber }).uppercased() }
        let first = clean(stored)
        let second = clean(hardware)
        guard first.count >= minimumModel, second.count >= minimumModel else { return false }
        return first.hasPrefix(second) || second.hasPrefix(first)
    }
}

/// The network `CameraProbe`. Answering: an unauthenticated ONVIF GetSystemDateAndTime to the camera's device service at
/// the checked address (any HTTP answer counts), or a TCP connect to its RTSP port when it has no device service; both
/// within `timeout`. Identity: a WS-Discovery Probe sent by unicast UDP to the address (port 3702; cameras answer it
/// with their endpoint reference and scopes, also across subnets and through NAT; no multicast, so no multicast
/// entitlement), else ONVIF GetEndpointReference. Nothing secret is sent, and only to addresses `allows` accepts (for
/// example `LocalNetwork.allowsCamera`; the transport checks it too).
public final class NetworkCameraProbe: CameraProbe {
    /// The default timeout of a check
    public static let defaultTimeout: TimeInterval = 1.5

    private let transport: any LanHTTPTransport
    private let allows: (InetAddress) -> Bool
    private let timeout: TimeInterval
    private let discoveryPort: UInt16

    public init(transport: any LanHTTPTransport, allows: @escaping (InetAddress) -> Bool, timeout: TimeInterval = NetworkCameraProbe.defaultTimeout,
                discoveryPort: UInt16 = WSDiscovery.port) {
        self.transport = transport
        self.allows = allows
        self.timeout = timeout
        self.discoveryPort = discoveryPort
    }

    public func answers(_ address: InetAddress, camera: ProbeTarget) async -> Bool {
        guard allows(address) else { return false }
        guard !camera.deviceURL.isEmpty else { return await TCPConnection.probe(address, port: Self.rtspPort(camera.streamURI), timeout: timeout) }
        let request = LanRequest(url: RTSPURLs.withHost(camera.deviceURL, address), headers: ["Content-Type": OnvifSoap.contentType],
                                 body: Data(OnvifSoap.envelope(OnvifSoap.getSystemDateAndTime).utf8), timeout: timeout)
        return (try? await transport.send(request)) != nil
    }

    public func identify(_ address: InetAddress, camera: ProbeTarget) async -> CameraFingerprint? {
        guard allows(address) else { return nil }
        let found = await Self.unicastDiscoveryOffActor(address, port: discoveryPort, timeout: timeout)
        if let found { return found }
        guard !camera.deviceURL.isEmpty else { return nil }
        let request = LanRequest(url: RTSPURLs.withHost(camera.deviceURL, address), headers: ["Content-Type": OnvifSoap.contentType],
                                 body: Data(OnvifSoap.envelope(OnvifSoap.getEndpointReference).utf8), timeout: timeout)
        guard let response = try? await transport.send(request), (200..<300).contains(response.status),
              let xml = try? SoapXML.parse(response.text), let guid = OnvifParser.endpointReference(xml) else { return nil }
        return CameraFingerprint(endpoint: guid)
    }

    /// The RTSP port of a stream URI (554 by default)
    public static func rtspPort(_ streamURI: String) -> Int { URLComponents(string: streamURI)?.port ?? 554 }

    /// The ProbeMatch of the device at `address` (the Probe sent twice: UDP may drop one), or nil within `timeout`
    /// [unicastDiscovery] blocks on a UDP socket: run it on the global executor, never on the caller's actor
    @concurrent
    static func unicastDiscoveryOffActor(_ address: InetAddress, port: UInt16, timeout: TimeInterval) async -> CameraFingerprint? {
        unicastDiscovery(address, port: port, timeout: timeout)
    }

    static func unicastDiscovery(_ address: InetAddress, port: UInt16, timeout: TimeInterval) -> CameraFingerprint? {
        let family = address.isV4 ? AF_INET : AF_INET6
        let fd = socket(family, SOCK_DGRAM, IPPROTO_UDP)
        guard fd >= 0 else { return nil }
        defer { close(fd) }
        var storage = sockaddr_storage()
        let length = socketAddress(address, port: port, into: &storage)
        let probe = Data(WSDiscoveryMessages.probe().utf8)
        var sent = false
        for _ in 0..<2 {
            let result = probe.withUnsafeBytes { buffer in
                withUnsafePointer(to: &storage) { pointer in
                    pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { sendto(fd, buffer.baseAddress, buffer.count, 0, $0, length) }
                }
            }
            sent = sent || result >= 0
        }
        guard sent else { return nil }
        let deadline = Date().addingTimeInterval(timeout)
        var buffer = [UInt8](repeating: 0, count: 65_536)
        while Date() < deadline {
            var descriptor = pollfd(fd: fd, events: Int16(POLLIN), revents: 0)
            let wait = Int32(max(0, min(250, deadline.timeIntervalSinceNow * 1000)))
            guard poll(&descriptor, 1, wait) > 0 else { continue }
            var sender = sockaddr_storage()
            var senderLength = socklen_t(MemoryLayout<sockaddr_storage>.size)
            let count = withUnsafeMutablePointer(to: &sender) { pointer in
                pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { recvfrom(fd, &buffer, buffer.count, 0, $0, &senderLength) }
            }
            guard count > 0 else { continue }
            let from = withUnsafeMutablePointer(to: &sender) { pointer in
                pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { InterfaceSubnets.ipAddress($0) }
            }
            // Only the device asked counts
            guard from?.bytes == address.bytes else { continue }
            if let device = WSDiscoveryMessages.parse(String(decoding: buffer[0..<count], as: UTF8.self)).first { return .of(device) }
        }
        return nil
    }

    /// `address`:`port` as a socket address in `storage`; its length
    private static func socketAddress(_ address: InetAddress, port: UInt16, into storage: inout sockaddr_storage) -> socklen_t {
        withUnsafeMutablePointer(to: &storage) { pointer in
            if address.isV4 {
                return pointer.withMemoryRebound(to: sockaddr_in.self, capacity: 1) { v4 in
                    v4.pointee.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
                    v4.pointee.sin_family = sa_family_t(AF_INET)
                    v4.pointee.sin_port = port.bigEndian
                    withUnsafeMutableBytes(of: &v4.pointee.sin_addr) { $0.copyBytes(from: address.bytes) }
                    return socklen_t(MemoryLayout<sockaddr_in>.size)
                }
            }
            return pointer.withMemoryRebound(to: sockaddr_in6.self, capacity: 1) { v6 in
                v6.pointee.sin6_len = UInt8(MemoryLayout<sockaddr_in6>.size)
                v6.pointee.sin6_family = sa_family_t(AF_INET6)
                v6.pointee.sin6_port = port.bigEndian
                v6.pointee.sin6_scope_id = address.scope
                withUnsafeMutableBytes(of: &v6.pointee.sin6_addr) { $0.copyBytes(from: address.bytes) }
                return socklen_t(MemoryLayout<sockaddr_in6>.size)
            }
        }
    }
}
