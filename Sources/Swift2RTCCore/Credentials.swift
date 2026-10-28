import Foundation

/// A camera's user (ONVIF, RTSP, HTTP Digest). Never logged: its description leaves the password out.
public struct OnvifCredentials: Codable, Equatable, Hashable, Sendable, CustomStringConvertible {
    public var username: String
    public var password: String

    public init(username: String, password: String) {
        self.username = username
        self.password = password
    }

    public var description: String { "OnvifCredentials(username=\(username), password=***)" }
}

/// Why a call to a camera's SOAP services failed. Defined in Core because the SOAP reader (`SoapXML`) throws it too.
public enum OnvifError: Error, Equatable, Sendable {
    /// No answer: the camera is off, the address is wrong, or this device is on another network
    case unreachable
    /// The transport refused the address before sending anything (`NotOnLocalNetwork`)
    case notLocal
    /// HTTP 401/403 (after HTTP Digest, when offered) or a NotAuthorized SOAP fault: wrong user name or password
    case unauthorized
    /// Any other SOAP fault; `reason` is the camera's text
    case fault(code: String?, subcode: String?, reason: String?)
    /// An error status without a SOAP fault
    case http(Int)
    /// Not XML, or not the answer that was asked for
    case invalidResponse(String)

    /// For logs: the kind only (a fault's reason is the camera's text, no secrets, but kept short)
    public var logDescription: String {
        switch self {
        case .unreachable: "unreachable"
        case .notLocal: "not_local"
        case .unauthorized: "unauthorized"
        case .fault: "fault"
        case .http(let status): "http_\(status)"
        case .invalidResponse(let detail): "invalid_response(\(detail))"
        }
    }
}
