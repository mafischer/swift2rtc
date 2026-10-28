import Foundation

/// One ONVIF camera (the device service at `deviceURL`): the camera's clock for the WS-Security timestamp
/// (GetSystemDateAndTime), device information, GetServices when GetCapabilities is refused, profiles, stream and
/// snapshot URIs, PTZ, HTTP Digest when the camera asks for it, and distinct errors for no answer, not on this network,
/// refused credentials and SOAP faults (`OnvifError`).
///
/// Every authenticated request carries a UsernameToken (password digest, fresh nonce); a `401` with a Digest challenge
/// is answered once with an `Authorization` header (Amcrest/Dahua do that). The `transport` is usually a
/// `SocketLanTransport`; tests put a fake camera behind it.
///
/// Not thread-safe: use one client from one actor (its async methods run on the caller's actor).
public final class OnvifClient {
    /// Seconds for an ONVIF call
    public static let timeout: TimeInterval = 4
    /// Seconds for a PTZ call (a press must feel immediate)
    public static let ptzTimeout: TimeInterval = 3

    /// The device service
    public let deviceURL: String
    private let transport: any LanHTTPTransport
    private let credentials: OnvifCredentials?
    private let now: () -> Date

    /// The camera's clock minus ours, for the UsernameToken's Created (cameras refuse timestamps far off their clock)
    public private(set) var clockOffset: TimeInterval = 0
    /// `syncClock` ran (successfully or not): it is not asked again
    public private(set) var clockSynced = false
    private var nonceCount = 0

    /// - Parameters:
    ///   - transport: plain HTTP to the camera
    ///   - deviceURL: the device service, e.g. `http://192.168.1.64/onvif/device_service`
    ///   - credentials: the camera's ONVIF user, or nil for unauthenticated calls
    ///   - now: the clock (tests)
    public init(transport: any LanHTTPTransport, deviceURL: String, credentials: OnvifCredentials?, now: @escaping () -> Date = Date.init) {
        self.transport = transport
        self.deviceURL = deviceURL
        self.credentials = credentials
        self.now = now
    }

    /// GetSystemDateAndTime, unauthenticated (allowed by the ONVIF spec before any login): the camera's UTC clock sets
    /// `clockOffset`. A camera that does not answer it keeps our clock; no answer at all or another network throws.
    @discardableResult
    public func syncClock() async throws -> Date? {
        clockSynced = true
        let xml: SoapElement
        do {
            xml = try await call(deviceURL, OnvifSoap.getSystemDateAndTime, authenticated: false)
        } catch let error as OnvifError where error == .unreachable || error == .notLocal {
            throw error
        } catch {
            return nil
        }
        guard let camera = OnvifParser.systemDateAndTime(xml) else { return nil }
        clockOffset = camera.timeIntervalSince(now())
        return camera
    }

    /// GetDeviceInformation: manufacturer, model, firmware, serial number
    public func deviceInformation() async throws -> OnvifDeviceInformation {
        try OnvifParser.deviceInformation(await call(deviceURL, OnvifSoap.getDeviceInformation))
    }

    /// GetCapabilities: the Media, PTZ and Events services
    public func capabilities() async throws -> OnvifEndpoints {
        try OnvifParser.capabilities(await call(deviceURL, OnvifSoap.getCapabilities), deviceURL: deviceURL)
    }

    /// GetServices: the same services by namespace
    public func services() async throws -> OnvifEndpoints {
        try OnvifParser.services(await call(deviceURL, OnvifSoap.getServices), deviceURL: deviceURL)
    }

    /// GetCapabilities, else GetServices (cameras of ONVIF 2.x profiles may answer only one of them)
    public func endpoints() async throws -> OnvifEndpoints {
        do {
            return try await capabilities()
        } catch OnvifError.fault, OnvifError.http, OnvifError.invalidResponse {
            return try await services()
        }
    }

    /// GetProfiles of the media service at `mediaURL`
    public func profiles(mediaURL: String) async throws -> [OnvifProfile] {
        try OnvifParser.profiles(await call(mediaURL, OnvifSoap.getProfiles))
    }

    /// GetStreamUri (RTP-Unicast over RTSP) of the profile, on the host the camera was reached at (`OnvifURLs.onHost`).
    /// Returned as the camera sent it: credentials are added only for playback, in memory (`RTSPURLs.withCredentials`).
    public func streamURI(mediaURL: String, profileToken: String) async throws -> String {
        let uri = try OnvifParser.mediaURI(await call(mediaURL, OnvifSoap.getStreamUri(profileToken)), response: "GetStreamUriResponse")
        return OnvifURLs.onHost(uri, reference: deviceURL)
    }

    /// GetSnapshotUri: a JPEG of the profile (HTTP, usually behind Digest), or nil when the camera has none
    public func snapshotURI(mediaURL: String, profileToken: String) async throws -> String? {
        do {
            let uri = try OnvifParser.mediaURI(await call(mediaURL, OnvifSoap.getSnapshotUri(profileToken)), response: "GetSnapshotUriResponse")
            return OnvifURLs.onHost(uri, reference: deviceURL)
        } catch OnvifError.fault, OnvifError.invalidResponse {
            return nil
        }
    }

    /// PTZ ContinuousMove: the camera moves until `stop` (a shorter timeout: a press must feel immediate)
    public func continuousMove(ptzURL: String, profileToken: String, velocity: PtzVelocity) async throws {
        _ = try await call(ptzURL, OnvifSoap.continuousMove(profileToken, velocity), timeout: Self.ptzTimeout)
    }

    /// PTZ Stop of pan, tilt and zoom
    public func stop(ptzURL: String, profileToken: String) async throws {
        _ = try await call(ptzURL, OnvifSoap.stop(profileToken), timeout: Self.ptzTimeout)
    }

    /// PTZ GetNodes: whether the camera has an optical zoom
    public func ptzZoomSupport(ptzURL: String) async throws -> PtzZoomSupport {
        try OnvifParser.ptzZoomSupport(await call(ptzURL, OnvifSoap.getNodes, timeout: Self.ptzTimeout))
    }

    /// PTZ GetStatus: the lens's zoom position, or nil when the camera reports none
    public func ptzZoomPosition(ptzURL: String, profileToken: String) async throws -> Double? {
        try OnvifParser.ptzZoomPosition(await call(ptzURL, OnvifSoap.getStatus(profileToken), timeout: Self.ptzTimeout))
    }

    /// Sends `body` to `url` and returns the parsed answer; throws `OnvifError`
    private func call(_ url: String, _ body: String, authenticated: Bool = true, timeout: TimeInterval = OnvifClient.timeout) async throws -> SoapElement {
        let user = authenticated ? credentials.flatMap { $0.username.isEmpty ? nil : $0 } : nil
        let headers = ["Content-Type": OnvifSoap.contentType]
        var request = LanRequest(url: url, headers: headers, body: Data(OnvifSoap.envelope(body, security: user.map(securityHeader)).utf8), timeout: timeout)
        var response = try await send(request)
        if response.status == 401, let user, let challenge = HTTPDigest.parseChallenge(response.header("WWW-Authenticate")) {
            nonceCount += 1
            request.headers["Authorization"] = HTTPDigest.authorization(challenge, credentials: user, method: "POST", uri: OnvifURLs.requestTarget(url),
                                                                        cnonce: HTTPDigest.cnonce(), nonceCount: nonceCount)
            // A fresh UsernameToken too: some cameras check both
            request.body = Data(OnvifSoap.envelope(body, security: securityHeader(user)).utf8)
            response = try await send(request)
        }
        return try answer(response)
    }

    private func securityHeader(_ user: OnvifCredentials) -> String {
        OnvifSoap.securityHeader(user, created: OnvifSoap.created(now().addingTimeInterval(clockOffset)), nonce: OnvifSoap.nonce())
    }

    private func send(_ request: LanRequest) async throws -> LanResponse {
        do {
            return try await transport.send(request)
        } catch is NotOnLocalNetwork {
            throw OnvifError.notLocal
        } catch let error as OnvifError {
            throw error
        } catch {
            throw OnvifError.unreachable
        }
    }

    /// A fault (any status) first, then 401, other errors, and the body
    private func answer(_ response: LanResponse) throws -> SoapElement {
        let xml = try? SoapXML.parse(response.text)
        if let xml, let fault = OnvifParser.fault(xml) { throw fault }
        if response.status == 401 || response.status == 403 { throw OnvifError.unauthorized }
        guard (200...299).contains(response.status) else { throw OnvifError.http(response.status) }
        guard let xml else { throw OnvifError.invalidResponse("xml") }
        return xml
    }
}
