import Darwin
import Foundation
import Network
import Testing
@testable import Swift2RTCCore
@testable import Swift2RTCOnvif

// MARK: - Waiting

enum WaitError: Error {
    case timeout(String)
}

/// Polls `condition` until it holds (or fails the test after `timeout`)
func waitUntil(_ what: String = "condition", timeout: Duration = .seconds(10), _ condition: () -> Bool) async throws {
    let deadline = ContinuousClock.now + timeout
    while !condition() {
        if ContinuousClock.now > deadline { throw WaitError.timeout(what) }
        try await Task.sleep(for: .milliseconds(20))
    }
}

// MARK: - Fixtures

/// Answers of real cameras (an Amcrest IP8M-2493E and a DoorBird D101S), shared with kotlin2rtc's tests; addresses,
/// endpoint references and message ids are placeholders
enum OnvifFixtures {
    static let directory = Bundle.module.resourceURL!.appending(path: "Fixtures/onvif")

    static func read(_ name: String) throws -> String {
        try String(contentsOf: directory.appending(path: name), encoding: .utf8)
    }

    /// A SOAP envelope the way many cameras write it (SOAP-ENV prefix)
    static func envelope(_ body: String) -> String {
        """
        <?xml version="1.0" encoding="UTF-8"?>
        <SOAP-ENV:Envelope xmlns:SOAP-ENV="http://www.w3.org/2003/05/soap-envelope" xmlns:tt="http://www.onvif.org/ver10/schema" xmlns:tds="http://www.onvif.org/ver10/device/wsdl" xmlns:trt="http://www.onvif.org/ver10/media/wsdl" xmlns:tptz="http://www.onvif.org/ver20/ptz/wsdl" xmlns:ter="http://www.onvif.org/ver10/error">
        <SOAP-ENV:Body>\(body)</SOAP-ENV:Body></SOAP-ENV:Envelope>
        """
    }

    static func soap(_ status: Int = 200, _ body: String, headers: [String: String] = [:]) -> LanResponse {
        LanResponse(status: status, headers: ["Content-Type": OnvifSoap.contentType].merging(headers) { $1 }, body: Data(body.utf8))
    }
}

extension LanRequest {
    /// The first element named `name` in the request's envelope
    func element(_ name: String) -> String? { (try? SoapXML.parse(String(decoding: body, as: UTF8.self)))?.descendant(name)?.text }

    /// The operation (the Body's first element)
    var operation: String? { (try? SoapXML.parse(String(decoding: body, as: UTF8.self)))?.descendant("Body")?.children.first?.name }

    var text: String { String(decoding: body, as: UTF8.self) }
}

// MARK: - Fake cameras

/// A camera answering from a handler; every request is recorded
final class RecordingLanTransport: LanHTTPTransport {
    private(set) var requests: [LanRequest] = []
    var handler: (LanRequest) throws -> LanResponse

    init(_ handler: @escaping (LanRequest) throws -> LanResponse) {
        self.handler = handler
    }

    var last: LanRequest { requests.last! }

    func send(_ request: LanRequest) async throws -> LanResponse {
        requests.append(request)
        return try handler(request)
    }
}

/// A fake ONVIF camera behind a `LanHTTPTransport`: `Fake Nursery Cam` at `host`, user `username` / password `password`
/// (checked through the WS-Security digest, as a camera does), a Full HD main stream with PTZ and a sub stream, and a
/// PTZ node with an optical zoom unless `opticalZoom` is false. Addresses `allows` refuses are not sent to (as
/// `SocketLanTransport`); any other host does not answer.
enum FakeOnvifCamera {
    static let host = "192.168.1.64"
    static let name = "Fake Nursery Cam"
    static let username = "admin"
    static let password = "fake-password"
    static let stream = "rtsp://\(host):554/live/main"

    static let device = DiscoveredDevice(endpoint: "urn:uuid:fake-onvif-camera", name: name, hardware: "FK-1000", host: host, port: 80,
                                         deviceURL: "http://\(host)/onvif/device_service")

    /// The camera's ONVIF services; every request is recorded
    final class Transport: LanHTTPTransport {
        private(set) var requests: [LanRequest] = []
        private let allows: (InetAddress) -> Bool
        /// The PTZ node has a zoom (GetNodes lists zoom spaces); without, pan and tilt only
        private let opticalZoom: Bool
        /// The lens's position (GetStatus, 0 ... 1): a zoom ContinuousMove takes it straight to that end (a fast lens)
        private(set) var zoomLevel = 0.0

        init(allows: @escaping (InetAddress) -> Bool = { $0.isPrivate }, opticalZoom: Bool = true) {
            self.allows = allows
            self.opticalZoom = opticalZoom
        }

        func send(_ request: LanRequest) async throws -> LanResponse {
            let literal = URLComponents(string: request.url)?.host.flatMap(InetAddress.init)
            if let literal, !allows(literal) { throw NotOnLocalNetwork() }
            requests.append(request)
            guard request.url.hasPrefix("http://\(host)/") else { throw URLError(.cannotConnectToHost) }
            let text = String(decoding: request.body, as: UTF8.self)
            guard let body = (try? SoapXML.parse(text))?.descendant("Body")?.children.first?.name else { return response(400, fault("ter:InvalidArgVal", "No body")) }
            if body == "GetSystemDateAndTime" { return response(200, FakeOnvifCamera.systemDateAndTime) }
            guard authorized(text) else { return response(400, fault("ter:NotAuthorized", "Sender not Authorized")) }
            switch body {
            case "GetDeviceInformation": return response(200, envelope(deviceInformation))
            case "GetCapabilities": return response(200, envelope(capabilities))
            case "GetProfiles": return response(200, envelope(profiles))
            case "GetStreamUri": return response(200, envelope(mediaURI("GetStreamUriResponse", stream)))
            case "GetSnapshotUri": return response(200, envelope(mediaURI("GetSnapshotUriResponse", "http://\(host)/onvif/snapshot?channel=1")))
            case "ContinuousMove":
                let zoom = (try? SoapXML.parse(text))?.descendant("Zoom")?.attribute("x").flatMap(Double.init) ?? 0
                if opticalZoom, zoom != 0 { zoomLevel = zoom > 0 ? 1 : 0 }
                return response(200, envelope("<tptz:ContinuousMoveResponse />"))
            case "Stop": return response(200, envelope("<tptz:StopResponse />"))
            case "GetNodes": return response(200, envelope(FakeOnvifCamera.ptzNodes(zoom: opticalZoom)))
            case "GetStatus": return response(200, envelope(FakeOnvifCamera.ptzStatus(zoom: zoomLevel)))
            default: return response(400, fault("ter:ActionNotSupported", "Not supported"))
            }
        }

        /// The UsernameToken of `username` whose digest matches `password`
        private func authorized(_ text: String) -> Bool {
            guard let token = (try? SoapXML.parse(text))?.descendant("UsernameToken"), let nonce = token.child("Nonce").flatMap({ Data(base64Encoded: $0.text) }),
                  let created = token.child("Created")?.text else { return false }
            return token.child("Username")?.text == username && token.child("Password")?.text == OnvifSoap.passwordDigest(password: password, created: created, nonce: nonce)
        }

        private func response(_ status: Int, _ body: String) -> LanResponse {
            LanResponse(status: status, headers: ["Content-Type": OnvifSoap.contentType], body: Data(body.utf8))
        }
    }

    static func envelope(_ body: String) -> String {
        "<?xml version=\"1.0\" encoding=\"UTF-8\"?><env:Envelope xmlns:env=\"http://www.w3.org/2003/05/soap-envelope\" "
            + "xmlns:tt=\"http://www.onvif.org/ver10/schema\" xmlns:tds=\"http://www.onvif.org/ver10/device/wsdl\" "
            + "xmlns:trt=\"http://www.onvif.org/ver10/media/wsdl\" xmlns:tptz=\"http://www.onvif.org/ver20/ptz/wsdl\" "
            + "xmlns:ter=\"http://www.onvif.org/ver10/error\"><env:Body>\(body)</env:Body></env:Envelope>"
    }

    static func fault(_ subcode: String, _ reason: String) -> String {
        envelope("<env:Fault><env:Code><env:Value>env:Sender</env:Value><env:Subcode><env:Value>\(subcode)</env:Value></env:Subcode></env:Code>"
            + "<env:Reason><env:Text xml:lang=\"en\">\(reason)</env:Text></env:Reason></env:Fault>")
    }

    static let systemDateAndTime = envelope("<tds:GetSystemDateAndTimeResponse><tds:SystemDateAndTime><tt:UTCDateTime><tt:Time><tt:Hour>12</tt:Hour>"
        + "<tt:Minute>0</tt:Minute><tt:Second>0</tt:Second></tt:Time><tt:Date><tt:Year>2026</tt:Year><tt:Month>10</tt:Month><tt:Day>25</tt:Day></tt:Date>"
        + "</tt:UTCDateTime></tds:SystemDateAndTime></tds:GetSystemDateAndTimeResponse>")

    /// A PTZ node with pan and tilt, and a zoom when `zoom` (the spaces as cameras list them)
    static func ptzNodes(zoom: Bool) -> String {
        let space = { (name: String, uri: String, axes: String) in "<tt:\(name)><tt:URI>\(uri)</tt:URI>\(axes)</tt:\(name)>" }
        let range = { (axis: String, min: String) in "<tt:\(axis)><tt:Min>\(min)</tt:Min><tt:Max>1</tt:Max></tt:\(axis)>" }
        let panTilt = space("ContinuousPanTiltVelocitySpace", "http://www.onvif.org/ver10/tptz/PanTiltSpaces/VelocityGenericSpace", range("XRange", "-1") + range("YRange", "-1"))
        let zoomSpaces = zoom
            ? space("AbsoluteZoomPositionSpace", "http://www.onvif.org/ver10/tptz/ZoomSpaces/PositionGenericSpace", range("XRange", "0"))
                + space("ContinuousZoomVelocitySpace", "http://www.onvif.org/ver10/tptz/ZoomSpaces/VelocityGenericSpace", range("XRange", "-1"))
            : ""
        return "<tptz:GetNodesResponse><tptz:PTZNode token=\"PTZNODE0\"><tt:Name>PTZ</tt:Name>"
            + "<tt:SupportedPTZSpaces>\(panTilt)\(zoomSpaces)</tt:SupportedPTZSpaces><tt:MaximumNumberOfPresets>16</tt:MaximumNumberOfPresets>"
            + "<tt:HomeSupported>true</tt:HomeSupported></tptz:PTZNode></tptz:GetNodesResponse>"
    }

    static func ptzStatus(zoom: Double) -> String {
        "<tptz:GetStatusResponse><tptz:PTZStatus><tt:Position><tt:PanTilt x=\"0\" y=\"0\" /><tt:Zoom x=\"\(zoom)\" /></tt:Position>"
            + "<tt:MoveStatus><tt:PanTilt>IDLE</tt:PanTilt><tt:Zoom>IDLE</tt:Zoom></tt:MoveStatus><tt:UtcTime>2026-10-25T12:00:00Z</tt:UtcTime>"
            + "</tptz:PTZStatus></tptz:GetStatusResponse>"
    }

    private static func mediaURI(_ response: String, _ uri: String) -> String {
        "<trt:\(response)><trt:MediaUri><tt:Uri>\(uri)</tt:Uri></trt:MediaUri></trt:\(response)>"
    }

    private static let deviceInformation = "<tds:GetDeviceInformationResponse><tds:Manufacturer>Example</tds:Manufacturer>"
        + "<tds:Model>FK-1000</tds:Model><tds:FirmwareVersion>1.0</tds:FirmwareVersion><tds:SerialNumber>FAKE0001</tds:SerialNumber>"
        + "<tds:HardwareId>FK-1000</tds:HardwareId></tds:GetDeviceInformationResponse>"

    private static let capabilities = "<tds:GetCapabilitiesResponse><tds:Capabilities>"
        + "<tt:Media><tt:XAddr>http://\(host)/onvif/media_service</tt:XAddr></tt:Media>"
        + "<tt:PTZ><tt:XAddr>http://\(host)/onvif/ptz_service</tt:XAddr></tt:PTZ>"
        + "</tds:Capabilities></tds:GetCapabilitiesResponse>"

    private static let profiles = "<trt:GetProfilesResponse>"
        + "<trt:Profiles token=\"MainStream\" fixed=\"true\"><tt:Name>Main stream</tt:Name><tt:VideoEncoderConfiguration token=\"V0\">"
        + "<tt:Encoding>H264</tt:Encoding><tt:Resolution><tt:Width>1920</tt:Width><tt:Height>1080</tt:Height></tt:Resolution>"
        + "</tt:VideoEncoderConfiguration><tt:PTZConfiguration token=\"PTZ0\"><tt:Name>PTZ</tt:Name></tt:PTZConfiguration></trt:Profiles>"
        + "<trt:Profiles token=\"SubStream\" fixed=\"true\"><tt:Name>Sub stream</tt:Name><tt:VideoEncoderConfiguration token=\"V1\">"
        + "<tt:Encoding>H264</tt:Encoding><tt:Resolution><tt:Width>640</tt:Width><tt:Height>480</tt:Height></tt:Resolution>"
        + "</tt:VideoEncoderConfiguration></trt:Profiles>"
        + "</trt:GetProfilesResponse>"
}

// MARK: - Local servers

/// A one-request-per-connection HTTP server on 127.0.0.1 (Network.framework); `answer` returns the raw response, or nil
/// to stay silent
final class LoopbackHTTPServer: @unchecked Sendable {
    private let listener: NWListener
    let port: UInt16

    private init(listener: NWListener, port: UInt16) {
        self.listener = listener
        self.port = port
    }

    static func start(answer: @escaping @Sendable (String) -> String?) async throws -> LoopbackHTTPServer {
        let parameters = NWParameters.tcp
        parameters.requiredLocalEndpoint = NWEndpoint.hostPort(host: "127.0.0.1", port: .any)
        let listener = try NWListener(using: parameters)
        let queue = DispatchQueue(label: "loopback-http-listener")
        listener.newConnectionHandler = { connection in
            connection.start(queue: queue)
            nonisolated(unsafe) var received = Data()
            @Sendable func read() {
                connection.receive(minimumIncompleteLength: 1, maximumLength: 65_536) { data, _, complete, _ in
                    if let data { received.append(data) }
                    let text = String(decoding: received, as: UTF8.self)
                    if let headEnd = text.range(of: "\r\n\r\n") {
                        let length = text.components(separatedBy: "\r\n").first { $0.lowercased().hasPrefix("content-length:") }
                            .flatMap { Int($0.split(separator: ":")[1].trimmingCharacters(in: .whitespaces)) } ?? 0
                        if text[headEnd.upperBound...].utf8.count >= length {
                            if let response = answer(text) {
                                connection.send(content: Data(response.utf8), completion: .contentProcessed { _ in connection.cancel() })
                            }
                            return
                        }
                    }
                    if !complete { read() }
                }
            }
            read()
        }
        let port: UInt16 = try await withCheckedThrowingContinuation { continuation in
            let once = Once()
            listener.stateUpdateHandler = { state in
                switch state {
                case .ready: once.run { continuation.resume(returning: listener.port?.rawValue ?? 0) }
                case .failed(let error): once.run { continuation.resume(throwing: error) }
                default: break
                }
            }
            listener.start(queue: queue)
        }
        return LoopbackHTTPServer(listener: listener, port: port)
    }

    func stop() { listener.cancel() }
}

/// A UDP socket on 127.0.0.1 that answers each probe with `answers` (each from the same socket), `rounds` times
final class UDPResponder: @unchecked Sendable {
    let port: UInt16
    private let fd: Int32
    private let task: Task<[String], Never>

    init(answers: [String], rounds: Int) throws {
        let fd = socket(AF_INET, SOCK_DGRAM, IPPROTO_UDP)
        var address = sockaddr_in()
        address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        address.sin_family = sa_family_t(AF_INET)
        address.sin_port = 0
        inet_pton(AF_INET, "127.0.0.1", &address.sin_addr)
        let bound = withUnsafePointer(to: &address) { $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { bind(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) } }
        guard bound == 0 else { throw URLError(.cannotCreateFile) }
        var length = socklen_t(MemoryLayout<sockaddr_in>.size)
        _ = withUnsafeMutablePointer(to: &address) { $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { getsockname(fd, $0, &length) } }
        port = UInt16(bigEndian: address.sin_port)
        self.fd = fd
        task = Task.detached {
            var probes: [String] = []
            var buffer = [UInt8](repeating: 0, count: 65_535)
            for _ in 0..<rounds {
                var descriptor = pollfd(fd: fd, events: Int16(POLLIN), revents: 0)
                guard poll(&descriptor, 1, 3000) > 0 else { break }
                var sender = sockaddr_storage()
                var senderLength = socklen_t(MemoryLayout<sockaddr_storage>.size)
                let count = withUnsafeMutablePointer(to: &sender) {
                    $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { recvfrom(fd, &buffer, buffer.count, 0, $0, &senderLength) }
                }
                guard count > 0 else { break }
                probes.append(String(decoding: buffer[0..<count], as: UTF8.self))
                for answer in answers {
                    let bytes = Array(answer.utf8)
                    _ = withUnsafePointer(to: &sender) { $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { sendto(fd, bytes, bytes.count, 0, $0, senderLength) } }
                }
            }
            return probes
        }
    }

    /// The probes received; closes the socket
    func finish() async -> [String] {
        let probes = await task.value
        close(fd)
        return probes
    }
}
