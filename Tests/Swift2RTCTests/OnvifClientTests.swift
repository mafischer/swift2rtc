import Foundation
import Testing
@testable import Swift2RTCCore
@testable import Swift2RTCOnvif

/// The ONVIF calls against a fake camera: what each call sends, the camera's clock in the UsernameToken, HTTP
/// Digest after a challenge (the real Amcrest one), and the errors: no answer, not on this network, refused credentials,
/// SOAP faults, not ONVIF
@Suite("ONVIF client")
struct OnvifClientTests {
    let device = "http://10.20.0.204/onvif/device_service"
    let media = "http://10.20.0.204/onvif/media_service"
    let credentials = OnvifCredentials(username: "admin", password: "s3cret")
    let now = ISO8601DateFormatter().date(from: "2026-10-27T00:50:00Z")!

    func client(_ transport: LanHTTPTransport, credentials: OnvifCredentials?? = .none) -> OnvifClient {
        let now = now
        return OnvifClient(transport: transport, deviceURL: device, credentials: credentials ?? self.credentials, now: { now })
    }

    @Test func deviceInformationIsPostedAsSOAPWithTheSecurityHeader() async throws {
        let transport = RecordingLanTransport { _ in
            OnvifFixtures.soap(200, OnvifFixtures.envelope("<tds:GetDeviceInformationResponse><tds:Manufacturer>Amcrest</tds:Manufacturer>" +
                                                           "<tds:Model>IP8M-2493E</tds:Model></tds:GetDeviceInformationResponse>"))
        }
        let info = try await client(transport).deviceInformation()
        #expect(info == OnvifDeviceInformation(manufacturer: "Amcrest", model: "IP8M-2493E"))
        let request = transport.last
        #expect(request.method == "POST")
        #expect(request.url == device)
        #expect(request.header("Content-Type") == "application/soap+xml; charset=utf-8")
        #expect(request.timeout == 4)
        #expect(request.operation == "GetDeviceInformation")
        #expect(request.element("Username") == "admin")
        #expect(!request.text.contains("s3cret"))
        // Our clock until the camera's is known
        #expect(request.element("Created") == "2026-10-27T00:50:00.000Z")
    }

    @Test func theCamerasClockSetsTheUsernameTokensTimestamp() async throws {
        let clock = try OnvifFixtures.read("amcrest-system-date-and-time.xml")
        let transport = RecordingLanTransport { request in
            request.operation == "GetSystemDateAndTime" ? OnvifFixtures.soap(200, clock) : OnvifFixtures.soap(200, OnvifFixtures.envelope("<tptz:StopResponse/>"))
        }
        let camera = client(transport)
        #expect(!camera.clockSynced)
        #expect(try await camera.syncClock() == ISO8601DateFormatter().date(from: "2026-10-27T00:51:47Z"))
        #expect(camera.clockSynced)
        #expect(camera.clockOffset == 107)
        // GetSystemDateAndTime is asked without credentials
        #expect(transport.requests.first?.element("Username") == nil)
        try await camera.stop(ptzURL: "http://10.20.0.204/onvif/ptz_service", profileToken: "MainStream")
        #expect(transport.last.element("Created") == "2026-10-27T00:51:47.000Z")
        #expect(transport.last.timeout == 3)
    }

    @Test func aCameraWithoutAClockAnswerKeepsOursAnUnreachableOneThrows() async throws {
        let refusing = RecordingLanTransport { _ in
            OnvifFixtures.soap(400, OnvifFixtures.envelope("<SOAP-ENV:Fault><SOAP-ENV:Reason><SOAP-ENV:Text>Bad</SOAP-ENV:Text></SOAP-ENV:Reason></SOAP-ENV:Fault>"))
        }
        let camera = client(refusing)
        #expect(try await camera.syncClock() == nil)
        #expect(camera.clockOffset == 0)
        #expect(try await client(RecordingLanTransport { _ in OnvifFixtures.soap(200, OnvifFixtures.envelope("<tds:GetSystemDateAndTimeResponse/>")) }).syncClock() == nil)
        await #expect(throws: OnvifError.unreachable) { try await client(RecordingLanTransport { _ in throw URLError(.timedOut) }).syncClock() }
        await #expect(throws: OnvifError.notLocal) { try await client(RecordingLanTransport { _ in throw NotOnLocalNetwork() }).syncClock() }
    }

    @Test func aDigestChallengeIsAnsweredOnceWithAnAuthorizationHeader() async throws {
        let challenge = try OnvifFixtures.read("amcrest-digest-challenge.txt").trimmingCharacters(in: .whitespacesAndNewlines)
        let transport = RecordingLanTransport { request in
            request.header("Authorization") == nil
                ? LanResponse(status: 401, headers: ["WWW-Authenticate": challenge])
                : OnvifFixtures.soap(200, OnvifFixtures.envelope("<tds:GetDeviceInformationResponse><tds:Model>IP8M-2493E</tds:Model></tds:GetDeviceInformationResponse>"))
        }
        #expect(try await client(transport).deviceInformation().model == "IP8M-2493E")
        #expect(transport.requests.count == 2)
        let authorization = try #require(transport.last.header("Authorization"))
        #expect(authorization.hasPrefix(#"Digest username="admin", realm="Login to AMC0000000000000000""#))
        #expect(authorization.contains(#"uri="/onvif/device_service""#))
        #expect(authorization.contains("nc=00000001"))
        // A fresh UsernameToken in the second request too
        #expect(transport.requests[0].element("Nonce") != transport.requests[1].element("Nonce"))
    }

    @Test func refusedCredentialsAreUnauthorizedWithOrWithoutAChallenge() async throws {
        let challenge = try OnvifFixtures.read("amcrest-digest-challenge.txt").trimmingCharacters(in: .whitespacesAndNewlines)
        let alwaysRefused = RecordingLanTransport { _ in LanResponse(status: 401, headers: ["WWW-Authenticate": challenge]) }
        await #expect(throws: OnvifError.unauthorized) { try await client(alwaysRefused).deviceInformation() }
        // Tried once with Digest, not more
        #expect(alwaysRefused.requests.count == 2)
        // Without credentials there is nothing to answer the challenge with
        let anonymous = RecordingLanTransport { _ in LanResponse(status: 401, headers: ["WWW-Authenticate": challenge]) }
        await #expect(throws: OnvifError.unauthorized) { try await client(anonymous, credentials: .some(nil)).deviceInformation() }
        #expect(anonymous.requests.count == 1)
        // The SOAP way: a NotAuthorized fault (status 400 or 500)
        let fault = RecordingLanTransport { _ in
            OnvifFixtures.soap(400, OnvifFixtures.envelope("<SOAP-ENV:Fault><SOAP-ENV:Code><SOAP-ENV:Value>SOAP-ENV:Sender</SOAP-ENV:Value>" +
                                                           "<SOAP-ENV:Subcode><SOAP-ENV:Value>ter:NotAuthorized</SOAP-ENV:Value></SOAP-ENV:Subcode>" +
                                                           "</SOAP-ENV:Code></SOAP-ENV:Fault>"))
        }
        await #expect(throws: OnvifError.unauthorized) { try await client(fault).deviceInformation() }
        // A Basic challenge is not answered
        let basic = RecordingLanTransport { _ in LanResponse(status: 401, headers: ["WWW-Authenticate": #"Basic realm="cam""#]) }
        await #expect(throws: OnvifError.unauthorized) { try await client(basic).deviceInformation() }
        #expect(basic.requests.count == 1)
        await #expect(throws: OnvifError.unauthorized) { try await client(RecordingLanTransport { _ in LanResponse(status: 403) }).deviceInformation() }
    }

    @Test func faultsOtherErrorsAndAnswersThatAreNotONVIF() async {
        let fault = RecordingLanTransport { _ in
            OnvifFixtures.soap(500, OnvifFixtures.envelope("<SOAP-ENV:Fault><SOAP-ENV:Code><SOAP-ENV:Value>SOAP-ENV:Receiver</SOAP-ENV:Value></SOAP-ENV:Code>" +
                                                           "<SOAP-ENV:Reason><SOAP-ENV:Text>Busy</SOAP-ENV:Text></SOAP-ENV:Reason></SOAP-ENV:Fault>"))
        }
        await #expect(throws: OnvifError.fault(code: "SOAP-ENV:Receiver", subcode: nil, reason: "Busy")) { try await client(fault).profiles(mediaURL: media) }
        await #expect(throws: OnvifError.http(404)) { try await client(RecordingLanTransport { _ in LanResponse(status: 404, body: Data("<html/>".utf8)) }).deviceInformation() }
        await #expect(throws: OnvifError.invalidResponse("xml")) {
            try await client(RecordingLanTransport { _ in LanResponse(status: 200, body: Data("OK".utf8)) }).deviceInformation()
        }
        await #expect(throws: OnvifError.unreachable) { try await client(RecordingLanTransport { _ in throw URLError(.cannotConnectToHost) }).deviceInformation() }
    }

    @Test func endpointsComeFromGetCapabilitiesElseFromGetServices() async throws {
        let capabilitiesXML = try OnvifFixtures.read("amcrest-capabilities.xml")
        let servicesXML = try OnvifFixtures.read("amcrest-services.xml")
        let capabilities = RecordingLanTransport { _ in OnvifFixtures.soap(200, capabilitiesXML) }
        #expect(try await client(capabilities).endpoints().mediaURL == media)
        #expect(capabilities.requests.map(\.operation) == ["GetCapabilities"])

        let servicesOnly = RecordingLanTransport { request in
            request.operation == "GetServices" ? OnvifFixtures.soap(200, servicesXML)
                : OnvifFixtures.soap(400, OnvifFixtures.envelope("<SOAP-ENV:Fault><SOAP-ENV:Reason>" +
                                                                 "<SOAP-ENV:Text>Action not supported</SOAP-ENV:Text></SOAP-ENV:Reason></SOAP-ENV:Fault>"))
        }
        #expect(try await client(servicesOnly).endpoints() == OnvifEndpoints(mediaURL: media, ptzURL: nil, eventsURL: "http://10.20.0.204/onvif/event_service"))
        #expect(servicesOnly.requests.map(\.operation) == ["GetCapabilities", "GetServices"])
        #expect(servicesOnly.last.element("IncludeCapability") == "false")

        // A camera that refuses the credentials does not get a second call
        let refused = RecordingLanTransport { _ in LanResponse(status: 401) }
        await #expect(throws: OnvifError.unauthorized) { try await client(refused).endpoints() }
        #expect(refused.requests.count == 1)
        for answer in [LanResponse(status: 404), OnvifFixtures.soap(200, OnvifFixtures.envelope("<x/>"))] {
            let fallback = RecordingLanTransport { request in request.operation == "GetServices" ? OnvifFixtures.soap(200, servicesXML) : answer }
            #expect(try await client(fallback).endpoints().mediaURL == media)
        }
    }

    @Test func theStreamURIIsOnTheCamerasHostUnescapedWithoutAddedCredentials() async throws {
        let transport = RecordingLanTransport { _ in
            OnvifFixtures.soap(200, OnvifFixtures.envelope("<trt:GetStreamUriResponse><trt:MediaUri><tt:Uri>rtsp://0.0.0.0:554/cam/realmonitor?channel=1&amp;subtype=0</tt:Uri></trt:MediaUri></trt:GetStreamUriResponse>"))
        }
        #expect(try await client(transport).streamURI(mediaURL: media, profileToken: "MainStream") == "rtsp://10.20.0.204:554/cam/realmonitor?channel=1&subtype=0")
        #expect(transport.last.url == media)
        #expect(transport.last.element("ProfileToken") == "MainStream")
        #expect(transport.last.element("Stream") == "RTP-Unicast")
    }

    @Test func theSnapshotURIOrNilWhenTheCameraHasNone() async throws {
        let transport = RecordingLanTransport { _ in
            OnvifFixtures.soap(200, OnvifFixtures.envelope("<trt:GetSnapshotUriResponse><trt:MediaUri><tt:Uri>http://10.20.0.204/cgi-bin/snapshot.cgi</tt:Uri></trt:MediaUri></trt:GetSnapshotUriResponse>"))
        }
        #expect(try await client(transport).snapshotURI(mediaURL: media, profileToken: "MainStream") == "http://10.20.0.204/cgi-bin/snapshot.cgi")
        let none = RecordingLanTransport { _ in
            OnvifFixtures.soap(400, OnvifFixtures.envelope("<SOAP-ENV:Fault><SOAP-ENV:Reason><SOAP-ENV:Text>No snapshot</SOAP-ENV:Text></SOAP-ENV:Reason></SOAP-ENV:Fault>"))
        }
        #expect(try await client(none).snapshotURI(mediaURL: media, profileToken: "MainStream") == nil)
        let empty = RecordingLanTransport { _ in OnvifFixtures.soap(200, OnvifFixtures.envelope("<x/>")) }
        #expect(try await client(empty).snapshotURI(mediaURL: media, profileToken: "MainStream") == nil)
    }

    @Test func continuousMoveSendsTheVelocitiesWithTheShorterTimeout() async throws {
        let transport = RecordingLanTransport { _ in OnvifFixtures.soap(200, OnvifFixtures.envelope("<tptz:ContinuousMoveResponse />")) }
        try await client(transport).continuousMove(ptzURL: "http://10.20.0.204/onvif/ptz_service", profileToken: "MainStream", velocity: PtzVelocity(pan: 0.5, tilt: -0.25))
        #expect(transport.last.url == "http://10.20.0.204/onvif/ptz_service")
        #expect(transport.last.timeout == 3)
        #expect(transport.last.text.contains("<tt:PanTilt x=\"0.5\" y=\"-0.25\""))
        #expect(transport.last.text.contains("<tt:Zoom x=\"0.0\""))
        await #expect(throws: OnvifError.http(500)) {
            try await client(RecordingLanTransport { _ in LanResponse(status: 500) }).continuousMove(ptzURL: device, profileToken: "p", velocity: PtzVelocity(zoom: 1))
        }
    }

    @Test func aUserWithoutANameSendsNoSecurityHeader() async throws {
        let transport = RecordingLanTransport { _ in OnvifFixtures.soap(200, OnvifFixtures.envelope("<trt:GetProfilesResponse/>")) }
        #expect(try await client(transport, credentials: .some(OnvifCredentials(username: "", password: "x"))).profiles(mediaURL: media).isEmpty)
        #expect(!transport.last.text.contains("UsernameToken"))
    }
}

/// Plain HTTP to cameras: responses by length, chunked or until close, and the socket client that sends only
/// to an allowed address, against a server on this machine
@Suite("Camera HTTP")
struct LanHTTPTests {
    @Test func responsesByLengthChunkedOrUntilTheCameraCloses() throws {
        let head = "HTTP/1.1 200 OK\r\nContent-Type: application/soap+xml\r\nWWW-Authenticate: Digest a\r\nwww-authenticate: Basic b\r\n"
        let sized = try #require(try LanHTTPParser.parse(Data((head + "Content-Length: 5\r\n\r\nhello").utf8), atEnd: false))
        #expect(sized.status == 200)
        #expect(sized.text == "hello")
        // Repeated headers: the first one wins
        #expect(sized.header("WWW-Authenticate") == "Digest a")
        // Not complete yet
        #expect(try LanHTTPParser.parse(Data((head + "Content-Length: 5\r\n\r\nhel").utf8), atEnd: false) == nil)
        #expect(throws: URLError.self) { try LanHTTPParser.parse(Data((head + "Content-Length: 5\r\n\r\nhel").utf8), atEnd: true) }
        let chunked = try #require(try LanHTTPParser.parse(Data((head + "Transfer-Encoding: chunked\r\n\r\n5;x=1\r\nhello\r\n6\r\n world\r\n0\r\n\r\n").utf8), atEnd: false))
        #expect(chunked.text == "hello world")
        #expect(try LanHTTPParser.parse(Data((head + "Transfer-Encoding: chunked\r\n\r\n5\r\nhel").utf8), atEnd: false) == nil)
        #expect(try LanHTTPParser.parse(Data((head + "\r\nuntil close").utf8), atEnd: false) == nil)
        #expect(try LanHTTPParser.parse(Data((head + "\r\nuntil close").utf8), atEnd: true)?.text == "until close")
        #expect(throws: URLError.self) { try LanHTTPParser.parse(Data("garbage\r\n\r\n".utf8), atEnd: false) }
        #expect(throws: URLError.self) { try LanHTTPParser.parse(Data((head + "Content-Length: 99\r\n\r\n").utf8), atEnd: false, maxBodyBytes: 10) }
    }

    @Test func anAddressOffThisNetworkIsRefusedBeforeConnecting() async throws {
        let transport = SocketLanTransport(allows: { _ in false }, resolve: { _ in [InetAddress("192.168.1.64")!] })
        await #expect(throws: NotOnLocalNetwork.self) { try await transport.send(LanRequest(url: "http://camera.lan/onvif/device_service")) }
        await #expect(throws: URLError.self) { try await transport.send(LanRequest(url: "https://192.168.1.64/onvif/device_service")) }
    }

    @Test func aRequestToAnAllowedAddressGoesOverTCP() async throws {
        let received = LockedValue("")
        let server = try await LoopbackHTTPServer.start { request in
            received.value = request
            return "HTTP/1.1 200 OK\r\nContent-Length: 7\r\n\r\n<ok/>\r\n"
        }
        defer { server.stop() }
        let transport = SocketLanTransport(allows: { $0.isLoopback })
        let response = try await transport.send(LanRequest(url: "http://127.0.0.1:\(server.port)/onvif/device_service", headers: ["Content-Type": "application/soap+xml"],
                                                           body: Data("<body/>".utf8)))
        let request = received.value
        #expect(request.hasPrefix("POST /onvif/device_service HTTP/1.1\r\nHost: 127.0.0.1:\(server.port)\r\n"))
        #expect(request.contains("Content-Type: application/soap+xml"))
        #expect(request.contains("Connection: close"))
        #expect(request.hasSuffix("<body/>"))
        #expect(response.status == 200)
        #expect(response.text == "<ok/>\r\n")
        // Nobody listening: no answer
        let closed = server.port
        server.stop()
        try await Task.sleep(for: .milliseconds(100))
        await #expect(throws: (any Error).self) { try await transport.send(LanRequest(url: "http://127.0.0.1:\(closed)/x", timeout: 2)) }
        #expect(await TCPConnection.probe(InetAddress("127.0.0.1")!, port: Int(closed), timeout: 1) == false)
    }

    @Test func aSilentCameraTimesOut() async throws {
        let server = try await LoopbackHTTPServer.start { _ in nil }
        defer { server.stop() }
        let transport = SocketLanTransport(allows: { $0.isLoopback })
        let started = Date()
        await #expect(throws: URLError(.timedOut)) { try await transport.send(LanRequest(url: "http://127.0.0.1:\(server.port)/x", timeout: 0.5)) }
        // The request's timeout ends the wait; room for a busy CI Mac (3.8 s seen for 0.5 s)
        #expect(Date().timeIntervalSince(started) < 10)
        #expect(await TCPConnection.probe(InetAddress("127.0.0.1")!, port: Int(server.port), timeout: 1))
    }
}

/// a camera's answer that never gets a complete head is an error, not a wait forever
extension LanHTTPTests {
    @Test func anAnswerWithoutACompleteHeadIsAnError() async throws {
        // Still arriving: wait; the camera closed the connection, or sent far too much without a head: an error
        #expect(try LanHTTPParser.parse(Data("HTTP/1.1 200 OK\r\nContent-Le".utf8), atEnd: false) == nil)
        #expect(throws: URLError(.cannotParseResponse)) { try LanHTTPParser.parse(Data("HTTP/1.1 200 OK\r\nContent-Le".utf8), atEnd: true) }
        #expect(throws: URLError(.cannotParseResponse)) {
            try LanHTTPParser.parse(Data(repeating: UInt8(ascii: "a"), count: LanHTTPParser.maxLine * 4 + 1), atEnd: false)
        }
        // A broken chunk size or Content-Length, and a chunked body that ends with the connection
        #expect(throws: URLError(.cannotParseResponse)) {
            try LanHTTPParser.parse(Data("HTTP/1.1 200 OK\r\nTransfer-Encoding: chunked\r\n\r\nzz\r\nhello\r\n".utf8), atEnd: false)
        }
        #expect(throws: URLError(.cannotParseResponse)) { try LanHTTPParser.parse(Data("HTTP/1.1 200 OK\r\nContent-Length: -1\r\n\r\n".utf8), atEnd: false) }
        #expect(throws: URLError(.networkConnectionLost)) {
            try LanHTTPParser.parse(Data("HTTP/1.1 200 OK\r\nTransfer-Encoding: chunked\r\n\r\n5\r\nhel".utf8), atEnd: true)
        }
        #expect(throws: URLError(.dataLengthExceedsMaximum)) {
            try LanHTTPParser.parse(Data("HTTP/1.1 200 OK\r\nTransfer-Encoding: chunked\r\n\r\n10\r\n0123456789abcdef\r\n0\r\n\r\n".utf8), atEnd: false, maxBodyBytes: 8)
        }
        #expect(throws: URLError(.dataLengthExceedsMaximum)) { try LanHTTPParser.parse(Data("HTTP/1.1 200 OK\r\n\r\n0123456789".utf8), atEnd: false, maxBodyBytes: 8) }

        // Over TCP: a camera that hangs up in the middle of its head
        let server = try await LoopbackHTTPServer.start { _ in "HTTP/1.1 200 OK\r\nContent-Le" }
        defer { server.stop() }
        let transport = SocketLanTransport(allows: { $0.isLoopback })
        // (an unparsable head, or the reset of the connection, at once rather than after the deadline)
        let started = Date()
        await #expect(throws: (any Error).self) { try await transport.send(LanRequest(url: "http://127.0.0.1:\(server.port)/onvif/device_service", timeout: 30)) }
        // A deadline far from the bound, so a busy CI Mac (3.8 s seen) cannot blur "at once" with "after the deadline"
        #expect(Date().timeIntervalSince(started) < 15)
    }
}
