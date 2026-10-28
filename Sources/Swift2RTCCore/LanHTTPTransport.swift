import Foundation
import Network

/// A request to a camera on the local network (ONVIF SOAP)
public struct LanRequest: Sendable {
    public var method: String
    public var url: String
    public var headers: [String: String]
    public var body: Data
    /// Seconds for the whole exchange
    public var timeout: TimeInterval

    public init(method: String = "POST", url: String, headers: [String: String] = [:], body: Data = Data(), timeout: TimeInterval = 5) {
        self.method = method
        self.url = url
        self.headers = headers
        self.body = body
        self.timeout = timeout
    }

    /// The header `name`, whatever its case
    public func header(_ name: String) -> String? { headers.first { $0.key.caseInsensitiveCompare(name) == .orderedSame }?.value }

    /// The request target of `url` (path and query) for the request line and HTTP Digest; `/` when it has no path
    public static func requestTarget(_ url: String) -> String {
        guard let components = URLComponents(string: url) else { return "/" }
        let path = components.percentEncodedPath.isEmpty ? "/" : components.percentEncodedPath
        return components.percentEncodedQuery.map { "\(path)?\($0)" } ?? path
    }
}

/// A camera's answer
public struct LanResponse: Sendable {
    public var status: Int
    /// The headers; of repeated ones, the first
    public var headers: [String: String]
    public var body: Data

    public init(status: Int, headers: [String: String] = [:], body: Data = Data()) {
        self.status = status
        self.headers = headers
        self.body = body
    }

    /// The body as UTF-8 text
    public var text: String { String(decoding: body, as: UTF8.self) }

    /// The header `name`, whatever its case
    public func header(_ name: String) -> String? { headers.first { $0.key.caseInsensitiveCompare(name) == .orderedSame }?.value }
}

/// The camera's address is not one the transport may call (`SocketLanTransport`'s `allows`): nothing was sent to it
public struct NotOnLocalNetwork: Error, Sendable {
    public init() {}
}

/// Plain HTTP to cameras (ONVIF's SOAP). `SocketLanTransport` is the default; tests and apps' stubbed backends put a
/// fake camera behind it.
public protocol LanHTTPTransport: AnyObject {
    /// Sends `request` and returns the camera's answer, whatever its status. Throws `NotOnLocalNetwork` when the address
    /// is refused before connecting, and any other error when there was no answer.
    func send(_ request: LanRequest) async throws -> LanResponse
}

/// Plain HTTP/1.1 to cameras on the local network, for ONVIF. Cameras speak SOAP over `http://` (few offer TLS), while an
/// iOS app's URLSession traffic stays under App Transport Security (HTTPS only unless the app adds exceptions). This
/// socket client (Network.framework TCP, which ATS does not cover) sends only to an address `allows` accepts, for
/// example one inside a subnet of the device's current network (`LocalNetwork.allows`) or a private address
/// (`LocalNetwork.allowsCamera`). Every other host is refused before connecting. The host is resolved once and the
/// address that passed the check is the one connected to (no second DNS lookup). One request per connection
/// (`Connection: close`), bodies up to `maxBodyBytes`.
public final class SocketLanTransport: LanHTTPTransport {
    private let allows: (InetAddress) -> Bool
    private let resolve: (String) async throws -> [InetAddress]
    private let maxBodyBytes: Int

    /// - Parameters:
    ///   - allows: which resolved addresses may be called
    ///   - resolve: host name to addresses (`HostResolver.resolve` by default; literals are not looked up)
    ///   - maxBodyBytes: larger answers fail with `URLError(.dataLengthExceedsMaximum)`
    public init(allows: @escaping (InetAddress) -> Bool, resolve: @escaping (String) async throws -> [InetAddress] = HostResolver.resolve, maxBodyBytes: Int = 1 << 20) {
        self.allows = allows
        self.resolve = resolve
        self.maxBodyBytes = maxBodyBytes
    }

    public func send(_ request: LanRequest) async throws -> LanResponse {
        guard let components = URLComponents(string: request.url), components.scheme?.lowercased() == "http", let host = components.host, !host.isEmpty else {
            throw URLError(.unsupportedURL)
        }
        guard let address = try await resolve(host).first(where: allows) else { throw NotOnLocalNetwork() }
        let port = components.port ?? 80
        let target = LanRequest.requestTarget(request.url)
        var head = "\(request.method) \(target) HTTP/1.1\r\n"
        head += "Host: \(port == 80 ? (host.contains(":") ? "[\(host)]" : host) : "\(host.contains(":") ? "[\(host)]" : host):\(port)")\r\n"
        for (name, value) in request.headers.sorted(by: { $0.key < $1.key }) { head += "\(name): \(value)\r\n" }
        head += "Content-Length: \(request.body.count)\r\nConnection: close\r\n\r\n"
        let payload = Data(head.utf8) + request.body
        let connection = TCPConnection(address: address, port: UInt16(clamping: port))
        defer { connection.close() }
        let maxBody = maxBodyBytes
        return try await connection.withDeadline(request.timeout) {
            try await connection.open(timeout: min(4, request.timeout))
            try await connection.send(payload)
            var received = Data()
            while true {
                let chunk = try await connection.receive()
                if let chunk { received.append(chunk) }
                if let response = try LanHTTPParser.parse(received, atEnd: chunk == nil, maxBodyBytes: maxBody) { return response }
                if chunk == nil { throw URLError(.networkConnectionLost) }
            }
        }
    }
}

/// Reads an HTTP/1.1 response: status line, headers, then the body by Content-Length, chunked, or until the camera
/// closes the connection
public enum LanHTTPParser {
    /// A head longer than four times this without its end is refused
    public static let maxLine = 16 * 1024

    /// The response once `data` holds all of it (nil: wait for more; `atEnd`: the connection closed)
    public static func parse(_ data: Data, atEnd: Bool, maxBodyBytes: Int = 1 << 20) throws -> LanResponse? {
        let bytes = [UInt8](data)
        guard let headEnd = find([13, 10, 13, 10], in: bytes, from: 0) else {
            if bytes.count > maxLine * 4 { throw URLError(.cannotParseResponse) }
            if atEnd { throw URLError(.cannotParseResponse) }
            return nil
        }
        let head = String(decoding: bytes[0..<headEnd], as: UTF8.self)
        var lines = head.components(separatedBy: "\r\n")
        let statusLine = lines.removeFirst()
        let parts = statusLine.split(separator: " ")
        guard parts.count >= 2, let status = Int(parts[1]) else { throw URLError(.cannotParseResponse) }
        var headers: [String: String] = [:]
        for line in lines {
            guard let colon = line.firstIndex(of: ":") else { continue }
            let name = line[..<colon].trimmingCharacters(in: .whitespaces)
            let value = line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces)
            // Repeated headers (several WWW-Authenticate challenges): the first one wins
            if !headers.keys.contains(where: { $0.caseInsensitiveCompare(name) == .orderedSame }) { headers[name] = value }
        }
        let response = LanResponse(status: status, headers: headers)
        let bodyStart = headEnd + 4
        let rest = Array(bytes[bodyStart...])
        if response.header("Transfer-Encoding")?.lowercased().contains("chunked") == true {
            guard let body = try chunked(rest, maxBodyBytes: maxBodyBytes) else {
                if atEnd { throw URLError(.networkConnectionLost) }
                return nil
            }
            return LanResponse(status: status, headers: headers, body: Data(body))
        }
        if let lengthText = response.header("Content-Length") {
            guard let length = Int(lengthText), length >= 0 else { throw URLError(.cannotParseResponse) }
            if length > maxBodyBytes { throw URLError(.dataLengthExceedsMaximum) }
            guard rest.count >= length else {
                if atEnd { throw URLError(.networkConnectionLost) }
                return nil
            }
            return LanResponse(status: status, headers: headers, body: Data(rest[0..<length]))
        }
        if rest.count > maxBodyBytes { throw URLError(.dataLengthExceedsMaximum) }
        return atEnd ? LanResponse(status: status, headers: headers, body: Data(rest)) : nil
    }

    /// The decoded chunked body, or nil while incomplete
    private static func chunked(_ bytes: [UInt8], maxBodyBytes: Int) throws -> [UInt8]? {
        var out: [UInt8] = []
        var index = 0
        while true {
            guard let lineEnd = find([13, 10], in: bytes, from: index) else { return nil }
            let sizeText = String(decoding: bytes[index..<lineEnd], as: UTF8.self).split(separator: ";").first.map { $0.trimmingCharacters(in: .whitespaces) } ?? ""
            guard let size = Int(sizeText, radix: 16) else { throw URLError(.cannotParseResponse) }
            index = lineEnd + 2
            if size == 0 { return out }
            if out.count + size > maxBodyBytes { throw URLError(.dataLengthExceedsMaximum) }
            guard bytes.count >= index + size + 2 else { return nil }
            out.append(contentsOf: bytes[index..<(index + size)])
            index += size + 2
        }
    }

    /// The index of the first `pattern` in `bytes` at or after `start`, or nil
    package static func find(_ pattern: [UInt8], in bytes: [UInt8], from start: Int) -> Int? {
        guard bytes.count >= pattern.count, start <= bytes.count - pattern.count else { return nil }
        for index in start...(bytes.count - pattern.count) where bytes[index] == pattern[0] {
            if Array(bytes[index..<(index + pattern.count)]) == pattern { return index }
        }
        return nil
    }
}

/// One TCP connection to a checked address (Network.framework), with async open, send and receive. Closing it (also
/// from a deadline or a cancelled task) ends a pending call at once.
public final class TCPConnection: @unchecked Sendable {
    private let connection: NWConnection
    private let queue = DispatchQueue(label: "swift2rtc.tcp")
    private let lock = NSLock()
    private var closed = false

    public init(address: InetAddress, port: UInt16) {
        let host = NWEndpoint.Host(address.hostWithScope)
        let tcp = NWProtocolTCP.Options()
        tcp.noDelay = true
        connection = NWConnection(host: host, port: NWEndpoint.Port(rawValue: port) ?? 80, using: NWParameters(tls: nil, tcp: tcp))
    }

    /// Waits until the connection is up; a refused or unroutable connection fails at once, a silent one after `timeout`
    public func open(timeout: TimeInterval) async throws {
        try await withDeadline(timeout) {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
                let once = Once()
                connection.stateUpdateHandler = { state in
                    switch state {
                    case .ready: once.run { continuation.resume() }
                    case .failed(let error), .waiting(let error): once.run { continuation.resume(throwing: error) }
                    case .cancelled: once.run { continuation.resume(throwing: CancellationError()) }
                    default: break
                    }
                }
                connection.start(queue: queue)
            }
        }
    }

    /// Sends `data`; returns once the stack took it
    public func send(_ data: Data) async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            connection.send(content: data, completion: .contentProcessed { error in
                if let error { continuation.resume(throwing: error) } else { continuation.resume() }
            })
        }
    }

    /// The next bytes, or nil when the other side closed the connection
    public func receive(maximum: Int = 65_536) async throws -> Data? {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Data?, Error>) in
            connection.receive(minimumIncompleteLength: 1, maximumLength: maximum) { data, _, isComplete, error in
                if let data, !data.isEmpty {
                    continuation.resume(returning: data)
                } else if let error {
                    continuation.resume(throwing: error)
                } else if isComplete {
                    continuation.resume(returning: nil)
                } else {
                    continuation.resume(returning: Data())
                }
            }
        }
    }

    /// Closes the connection (once; later calls do nothing)
    public func close() {
        let first = lock.withLock {
            defer { closed = true }
            return !closed
        }
        if first { connection.cancel() }
    }

    /// Runs `operation`; after `seconds`, or when the task is cancelled, the connection is closed (which ends a pending
    /// call) and the call throws `URLError(.timedOut)`
    public func withDeadline<T: Sendable>(_ seconds: TimeInterval, _ operation: @Sendable () async throws -> T) async throws -> T {
        let timedOut = Flag()
        let timer = Task.detached { [weak self] in
            try? await Task.sleep(for: .seconds(seconds))
            guard !Task.isCancelled else { return }
            timedOut.set()
            self?.close()
        }
        defer { timer.cancel() }
        do {
            return try await withTaskCancellationHandler {
                try await operation()
            } onCancel: { [weak self] in
                self?.close()
            }
        } catch {
            if timedOut.isSet { throw URLError(.timedOut) }
            throw error
        }
    }

    /// Opens a connection and closes it: true when the camera accepted it within `timeout` (a reachability check that
    /// sends nothing)
    public static func probe(_ address: InetAddress, port: Int, timeout: TimeInterval) async -> Bool {
        let connection = TCPConnection(address: address, port: UInt16(clamping: port))
        defer { connection.close() }
        do {
            try await connection.open(timeout: timeout)
            return true
        } catch {
            return false
        }
    }
}

/// Runs a closure once (continuations must resume exactly once)
package final class Once: @unchecked Sendable {
    private let lock = NSLock()
    private var done = false

    package init() {}

    package func run(_ body: () -> Void) {
        let first = lock.withLock {
            defer { done = true }
            return !done
        }
        if first { body() }
    }
}

/// A flag set once, read from any thread
package final class Flag: @unchecked Sendable {
    private let lock = NSLock()
    private var value = false

    package init() {}

    package var isSet: Bool { lock.withLock { value } }
    package func set() { lock.withLock { value = true } }
}
