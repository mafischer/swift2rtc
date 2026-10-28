/// How important a log line is
public enum LogLevel: Int, Sendable, Comparable, CustomStringConvertible {
    case debug
    case info
    case error

    public static func < (lhs: LogLevel, rhs: LogLevel) -> Bool { lhs.rawValue < rhs.rawValue }

    public var description: String {
        switch self {
        case .debug: "debug"
        case .info: "info"
        case .error: "error"
        }
    }
}

/// Where the library's few diagnostic lines go (a failed discovery probe, an RTSP stream that stopped, a refused PTZ
/// command). Messages never carry credentials, URLs with user info or the camera's own texts beyond short kinds, so
/// they may go to a public log. The default is `NoopLogger`: the library logs nothing unless given a logger.
///
/// Named `Swift2RTCLogger` rather than `Logger` so it never clashes with `os.Logger` in files that import both.
public protocol Swift2RTCLogger: Sendable {
    /// Records `message` at `level`; called from any thread
    func log(_ level: LogLevel, _ message: String)
}

/// Discards every line (the default)
public struct NoopLogger: Swift2RTCLogger {
    public init() {}

    public func log(_ level: LogLevel, _ message: String) {}
}

extension Swift2RTCLogger where Self == NoopLogger {
    /// No logging
    public static var none: NoopLogger { NoopLogger() }
}
