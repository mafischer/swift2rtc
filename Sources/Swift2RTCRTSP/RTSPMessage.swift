import Foundation

// RTSP 1.0 (RFC 2326) as IP cameras speak it, with RTP interleaved in the TCP connection (section 10.12): the requests the
// client sends, the responses and `$`-framed RTP packets it reads from one byte stream. Pure, so the unit tests replay
// cameras' answers byte by byte.

/// A response of the camera
public struct RTSPResponse: Equatable, Sendable {
    public var status: Int
    public var reason: String
    public var headers: [String: String]
    public var body: Data

    public init(status: Int, reason: String, headers: [String: String], body: Data) {
        self.status = status
        self.reason = reason
        self.headers = headers
        self.body = body
    }

    /// The header `name`, whatever its case
    public func header(_ name: String) -> String? { headers.first { $0.key.caseInsensitiveCompare(name) == .orderedSame }?.value }
    /// The `CSeq` header
    public var cseq: Int? { header("CSeq").flatMap { Int($0.trimmingCharacters(in: .whitespaces)) } }

    /// The `Session` header's id, without `;timeout=`
    public var sessionId: String? {
        header("Session").map { $0.split(separator: ";", maxSplits: 1).first.map { $0.trimmingCharacters(in: .whitespaces) } ?? "" }.flatMap { $0.isEmpty ? nil : $0 }
    }

    /// The session timeout (`Session: id;timeout=60`), 60 s when not given
    public var sessionTimeout: TimeInterval {
        guard let session = header("Session") else { return 60 }
        for part in session.split(separator: ";").dropFirst() {
            let pair = part.split(separator: "=", maxSplits: 1).map { $0.trimmingCharacters(in: .whitespaces) }
            if pair.count == 2, pair[0].lowercased() == "timeout", let value = TimeInterval(pair[1]), value > 0 { return value }
        }
        return 60
    }
}

/// What the byte stream carried next
public enum RTSPFrame: Equatable, Sendable {
    case response(RTSPResponse)
    /// An RTP or RTCP packet on an interleaved channel
    case interleaved(channel: UInt8, payload: Data)
}

/// The byte stream is not RTSP
public enum RTSPError: Error, Equatable, Sendable {
    case malformed(String)
}

/// Splits the TCP byte stream into responses and interleaved packets (`$`, channel, 16-bit length, packet)
public struct RTSPStreamParser {
    private var buffer: [UInt8] = []
    private var start = 0
    /// A response head longer than this is refused
    public static let maxHead = 64 * 1024

    public init() {}

    /// Adds bytes from the connection
    public mutating func append(_ data: Data) {
        if start > 0, start > buffer.count / 2 {
            buffer.removeFirst(start)
            start = 0
        }
        buffer.append(contentsOf: data)
    }

    /// The next complete frame, or nil until more bytes arrive
    public mutating func next() throws -> RTSPFrame? {
        // Junk between frames (some cameras pad): skip to the next `$` or `RTSP/`
        while start < buffer.count, buffer[start] != 0x24, buffer[start] != 0x52 { start += 1 }
        guard start < buffer.count else { return nil }
        if buffer[start] == 0x24 {
            guard buffer.count - start >= 4 else { return nil }
            let channel = buffer[start + 1]
            let length = Int(buffer[start + 2]) << 8 | Int(buffer[start + 3])
            guard buffer.count - start - 4 >= length else { return nil }
            let payload = Data(buffer[(start + 4)..<(start + 4 + length)])
            start += 4 + length
            return .interleaved(channel: channel, payload: payload)
        }
        guard buffer.count - start >= 5 else { return nil }
        guard buffer[start..<(start + 5)].elementsEqual(Array("RTSP/".utf8)) else {
            start += 1
            return try next()
        }
        guard let headEnd = LanHTTPParser.find([13, 10, 13, 10], in: buffer, from: start) else {
            if buffer.count - start > Self.maxHead { throw RTSPError.malformed("head too long") }
            return nil
        }
        let head = String(decoding: buffer[start..<headEnd], as: UTF8.self)
        var lines = head.components(separatedBy: "\r\n")
        let statusLine = lines.removeFirst()
        let parts = statusLine.split(separator: " ", maxSplits: 2)
        guard parts.count >= 2, let status = Int(parts[1]) else { throw RTSPError.malformed("status line") }
        var headers: [String: String] = [:]
        for line in lines {
            guard let colon = line.firstIndex(of: ":") else { continue }
            let name = line[..<colon].trimmingCharacters(in: .whitespaces)
            if headers.keys.contains(where: { $0.caseInsensitiveCompare(name) == .orderedSame }) { continue }
            headers[name] = line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces)
        }
        let length = headers.first { $0.key.caseInsensitiveCompare("Content-Length") == .orderedSame }.flatMap { Int($0.value) } ?? 0
        let bodyStart = headEnd + 4
        guard buffer.count - bodyStart >= length else { return nil }
        let body = Data(buffer[bodyStart..<(bodyStart + length)])
        start = bodyStart + length
        return .response(RTSPResponse(status: status, reason: parts.count > 2 ? String(parts[2]) : "", headers: headers, body: body))
    }
}

/// The requests of the client
public enum RTSPRequest {
    /// The default `User-Agent` (`RTSPSession` takes another)
    public static let defaultUserAgent = "swift2rtc"

    /// `METHOD url RTSP/1.0` with CSeq, User-Agent and `headers` (in a fixed order, so tests compare text)
    public static func make(_ method: String, url: String, cseq: Int, headers: [(String, String)] = [], userAgent: String = defaultUserAgent) -> Data {
        var text = "\(method) \(url) RTSP/1.0\r\nCSeq: \(cseq)\r\nUser-Agent: \(userAgent)\r\n"
        for (name, value) in headers { text += "\(name): \(value)\r\n" }
        text += "\r\n"
        return Data(text.utf8)
    }

    /// RTP and RTCP of one track interleaved in the RTSP connection
    public static func tcpTransport(channel: Int) -> String { "RTP/AVP/TCP;unicast;interleaved=\(channel)-\(channel + 1)" }

    /// The interleaved channels the camera chose (`interleaved=2-3`), else nil
    public static func interleavedChannel(_ transport: String?) -> Int? {
        guard let transport else { return nil }
        for part in transport.split(separator: ";") {
            let pair = part.split(separator: "=", maxSplits: 1).map { $0.trimmingCharacters(in: .whitespaces) }
            if pair.count == 2, pair[0].lowercased() == "interleaved" { return Int(pair[1].split(separator: "-").first ?? "") }
        }
        return nil
    }

    /// A track's control URL against the base (`Content-Base`, `Content-Location`, else the request URL)
    public static func controlURL(_ control: String?, base: String) -> String {
        guard let control, !control.isEmpty, control != "*" else { return base }
        if control.lowercased().hasPrefix("rtsp://") || control.lowercased().hasPrefix("rtsps://") { return control }
        return base.hasSuffix("/") ? base + control : base + "/" + control
    }
}
