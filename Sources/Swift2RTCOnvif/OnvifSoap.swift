import CryptoKit
import Foundation
import Security

/// The SOAP requests of the ONVIF client: the envelope, namespaces and WS-Security UsernameToken (password digest) that
/// kotlin2rtc builds too, so both agree on the wire (the unit tests pin the same vectors). Values that come from the
/// user or the camera (user name, profile token) are XML-escaped.
public enum OnvifSoap {
    /// The Content-Type of every request (SOAP 1.2)
    public static let contentType = "application/soap+xml; charset=utf-8"

    private static let wsse = "http://docs.oasis-open.org/wss/2004/01/oasis-200401-wss-wssecurity-secext-1.0.xsd"
    private static let wsu = "http://docs.oasis-open.org/wss/2004/01/oasis-200401-wss-wssecurity-utility-1.0.xsd"
    private static let passwordDigestType = "http://docs.oasis-open.org/wss/2004/01/oasis-200401-wss-username-token-profile-1.0#PasswordDigest"
    private static let base64Binary = "http://docs.oasis-open.org/wss/2004/01/oasis-200401-wss-soap-message-security-1.0#Base64Binary"
    private static let panTiltSpace = "http://www.onvif.org/ver10/tptz/PanTiltSpaces/VelocityGenericSpace"
    private static let zoomSpace = "http://www.onvif.org/ver10/tptz/ZoomSpaces/VelocityGenericSpace"

    /// WS-Security PasswordDigest: Base64(SHA-1(nonce + created + password))
    public static func passwordDigest(password: String, created: String, nonce: Data) -> String {
        var data = nonce
        data.append(Data(created.utf8))
        data.append(Data(password.utf8))
        return Data(Insecure.SHA1.hash(data: data)).base64EncodedString()
    }

    /// The UsernameToken's timestamp: UTC with milliseconds, as JavaScript's toISOString
    public static func created(_ date: Date) -> String {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        formatter.timeZone = TimeZone(identifier: "UTC")
        return formatter.string(from: date)
    }

    /// A fresh 16-byte nonce for every request (replay protection)
    public static func nonce() -> Data {
        var bytes = [UInt8](repeating: 0, count: 16)
        _ = SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes)
        return Data(bytes)
    }

    /// The WS-Security header: the password itself is never in it, only its digest
    public static func securityHeader(_ credentials: OnvifCredentials, created: String, nonce: Data) -> String {
        let digest = passwordDigest(password: credentials.password, created: created, nonce: nonce)
        return """
        <s:Header>
          <Security s:mustUnderstand="1" xmlns="\(wsse)">
            <UsernameToken>
              <Username>\(SoapXML.escape(credentials.username))</Username>
              <Password Type="\(passwordDigestType)">\(digest)</Password>
              <Nonce EncodingType="\(base64Binary)">\(nonce.base64EncodedString())</Nonce>
              <Created xmlns="\(wsu)">\(created)</Created>
            </UsernameToken>
          </Security>
        </s:Header>
        """
    }

    /// The envelope around `body`; with `security` (a `securityHeader`) when the camera has a user
    public static func envelope(_ body: String, security: String? = nil) -> String {
        var text = "<?xml version=\"1.0\" encoding=\"utf-8\"?>\n"
        text += "<s:Envelope xmlns:s=\"http://www.w3.org/2003/05/soap-envelope\" xmlns:tt=\"http://www.onvif.org/ver10/schema\" "
        text += "xmlns:tds=\"http://www.onvif.org/ver10/device/wsdl\" xmlns:trt=\"http://www.onvif.org/ver10/media/wsdl\" "
        text += "xmlns:tptz=\"http://www.onvif.org/ver20/ptz/wsdl\">\n"
        if let security { text += security + "\n" }
        text += "<s:Body>\n\(body)\n</s:Body>\n</s:Envelope>"
        return text
    }

    // MARK: Bodies

    /// Device: the camera's clock (allowed without login)
    public static let getSystemDateAndTime = "<tds:GetSystemDateAndTime />"
    /// Device: manufacturer, model, firmware, serial number
    public static let getDeviceInformation = "<tds:GetDeviceInformation />"
    /// Unauthenticated (PRE_AUTH in ONVIF Core): the device's endpoint reference, optional (Amcrest/Dahua do not implement it)
    public static let getEndpointReference = "<tds:GetEndpointReference />"
    /// Device: the services' addresses (ONVIF 1.x style)
    public static let getCapabilities = "<tds:GetCapabilities><tds:Category>All</tds:Category></tds:GetCapabilities>"
    /// Device: the services' addresses by namespace (ONVIF 2.x style)
    public static let getServices = "<tds:GetServices><tds:IncludeCapability>false</tds:IncludeCapability></tds:GetServices>"
    /// Media: the media profiles
    public static let getProfiles = "<trt:GetProfiles />"

    /// Media: the RTSP URI (RTP unicast over RTSP) of a profile
    public static func getStreamUri(_ profileToken: String) -> String {
        """
        <trt:GetStreamUri>
          <trt:StreamSetup>
            <tt:Stream>RTP-Unicast</tt:Stream>
            <tt:Transport>
              <tt:Protocol>RTSP</tt:Protocol>
            </tt:Transport>
          </trt:StreamSetup>
          <trt:ProfileToken>\(SoapXML.escape(profileToken))</trt:ProfileToken>
        </trt:GetStreamUri>
        """
    }

    /// Media: the JPEG snapshot URI of a profile
    public static func getSnapshotUri(_ profileToken: String) -> String {
        "<trt:GetSnapshotUri><trt:ProfileToken>\(SoapXML.escape(profileToken))</trt:ProfileToken></trt:GetSnapshotUri>"
    }

    /// PTZ: move at `velocity` until Stop
    public static func continuousMove(_ profileToken: String, _ velocity: PtzVelocity) -> String {
        """
        <tptz:ContinuousMove>
          <tptz:ProfileToken>\(SoapXML.escape(profileToken))</tptz:ProfileToken>
          <tptz:Velocity>
            <tt:PanTilt x="\(number(velocity.pan))" y="\(number(velocity.tilt))" space="\(panTiltSpace)" />
            <tt:Zoom x="\(number(velocity.zoom))" space="\(zoomSpace)" />
          </tptz:Velocity>
        </tptz:ContinuousMove>
        """
    }

    /// PTZ: stop pan, tilt and zoom
    public static func stop(_ profileToken: String) -> String {
        """
        <tptz:Stop>
          <tptz:ProfileToken>\(SoapXML.escape(profileToken))</tptz:ProfileToken>
          <tptz:PanTilt>true</tptz:PanTilt>
          <tptz:Zoom>true</tptz:Zoom>
        </tptz:Stop>
        """
    }

    /// PTZ GetNodes: the PTZ nodes and their spaces (does the camera zoom optically)
    public static let getNodes = "<tptz:GetNodes />"

    /// PTZ GetStatus: where the camera points and its lens's zoom
    public static func getStatus(_ profileToken: String) -> String {
        "<tptz:GetStatus><tptz:ProfileToken>\(SoapXML.escape(profileToken))</tptz:ProfileToken></tptz:GetStatus>"
    }

    /// "0.5", "-0.25", "0.0": as Kotlin prints a Double, so kotlin2rtc and swift2rtc send the same text
    public static func number(_ value: Double) -> String {
        value == value.rounded() ? String(format: "%.1f", value) : String(value)
    }
}
