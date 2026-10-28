import CryptoKit
import Foundation
import Testing
@testable import Swift2RTCCore
@testable import Swift2RTCOnvif

/// The SOAP the client sends and reads: the WS-Security password digest with the vectors kotlin2rtc's
/// tests pin, the envelope and bodies, escaping, and how the answers of real cameras are read whatever their prefixes
@Suite("ONVIF SOAP")
struct OnvifSoapTests {
    let credentials = OnvifCredentials(username: "admin", password: "s3cret")

    @Test func thePasswordDigestMatchesTheONVIFExampleAndTheKotlinVectors() {
        // ONVIF Application Programmer's Guide 6.1.1.3: the published nonce, timestamp and password
        let nonce = Data(base64Encoded: "LKqI6G/AikKCQrN0zqZFlg==")!
        #expect(OnvifSoap.passwordDigest(password: "userpassword", created: "2010-09-16T07:50:45Z", nonce: nonce) == "tuOSpGlFlIXsozq4HFNeeGeFLEI=")
        #expect(OnvifSoap.passwordDigest(password: "userpassword", created: "2010-09-16T07:50:46Z", nonce: nonce) != "tuOSpGlFlIXsozq4HFNeeGeFLEI=")
        #expect(OnvifSoap.passwordDigest(password: "testPassword123", created: "2026-10-25T00:00:00Z", nonce: Data(1...16)) == "8lkwDHT3BpaNBg/R7KnO4Matd8U=")
        #expect(OnvifSoap.passwordDigest(password: "testpassword", created: "2026-10-25T00:00:00Z", nonce: Data("16bytesnonce1234".utf8)) == "swccRiGHBCrWDQjq3N6/BkBRh4Q=")
    }

    @Test func theSecurityHeaderCarriesADigestOfItsOwnNonceAndTimestampNeverThePassword() throws {
        let nonce = OnvifSoap.nonce()
        let created = OnvifSoap.created(Date(timeIntervalSince1970: 1_761_436_800.123))
        #expect(created == "2025-10-26T00:00:00.123Z")
        let envelope = OnvifSoap.envelope(OnvifSoap.getDeviceInformation, security: OnvifSoap.securityHeader(credentials, created: created, nonce: nonce))
        #expect(!envelope.contains("s3cret"))
        let xml = try SoapXML.parse(envelope)
        #expect(xml.descendant("Username")?.text == "admin")
        #expect(xml.descendant("Nonce")?.text == nonce.base64EncodedString())
        #expect(xml.descendant("Created")?.text == created)
        #expect(xml.descendant("Password")?.text == OnvifSoap.passwordDigest(password: "s3cret", created: created, nonce: nonce))
        #expect(envelope.contains("<Security s:mustUnderstand=\"1\""))
        #expect(envelope.contains("#PasswordDigest\">"))
        #expect(envelope.contains("<Username>admin</Username>"))
        #expect(envelope.contains("xmlns:s=\"http://www.w3.org/2003/05/soap-envelope\""))
        #expect(envelope.contains("<tds:GetDeviceInformation />"))
        // A fresh nonce for every request
        #expect(OnvifSoap.nonce() != nonce)
        #expect(nonce.count == 16)
    }

    @Test func withoutCredentialsThereIsNoSecurityHeader() throws {
        let envelope = OnvifSoap.envelope(OnvifSoap.getProfiles)
        #expect(!envelope.contains("<s:Header>"))
        #expect(!envelope.contains("UsernameToken"))
        #expect(envelope.contains("<s:Body>\n<trt:GetProfiles />\n</s:Body>"))
        #expect(try SoapXML.parse(envelope).descendant("Body")?.children.map(\.name) == ["GetProfiles"])
    }

    @Test func theBodiesAskWhatTheKotlinClientAsks() throws {
        let stream = OnvifSoap.getStreamUri("MainStream")
        #expect(stream.contains("<tt:Stream>RTP-Unicast</tt:Stream>"))
        #expect(stream.contains("<tt:Protocol>RTSP</tt:Protocol>"))
        #expect(stream.contains("<trt:ProfileToken>MainStream</trt:ProfileToken>"))
        #expect(OnvifSoap.getSnapshotUri("Sub").contains("<trt:GetSnapshotUri><trt:ProfileToken>Sub</trt:ProfileToken>"))
        #expect(OnvifSoap.getCapabilities.contains("<tds:Category>All</tds:Category>"))
        let move = OnvifSoap.continuousMove("MainStream", PtzVelocity(pan: 0.5, tilt: -0.25))
        #expect(move.contains("<tt:PanTilt x=\"0.5\" y=\"-0.25\""))
        #expect(move.contains("<tt:Zoom x=\"0.0\""))
        #expect(move.contains("VelocityGenericSpace"))
        let stop = OnvifSoap.stop("MainStream")
        #expect(stop.contains("<tptz:Stop>"))
        #expect(stop.contains("<tptz:PanTilt>true</tptz:PanTilt>"))
        #expect(stop.contains("<tptz:Zoom>true</tptz:Zoom>"))
        for body in [stream, move, stop, OnvifSoap.getServices, OnvifSoap.getSystemDateAndTime] { _ = try SoapXML.parse(OnvifSoap.envelope(body)) }
    }

    @Test func userNamesAndProfileTokensAreEscaped() throws {
        let header = OnvifSoap.securityHeader(OnvifCredentials(username: "a<b>&\"c'", password: "pw"), created: "2026-10-25T00:00:00.000Z", nonce: Data(count: 16))
        #expect(header.contains("<Username>a&lt;b&gt;&amp;&quot;c&apos;</Username>"))
        let body = OnvifSoap.getStreamUri("</trt:ProfileToken><evil/>")
        #expect(try SoapXML.parse(OnvifSoap.envelope(body)).descendant("ProfileToken")?.text == "</trt:ProfileToken><evil/>")
        #expect(try SoapXML.parse(OnvifSoap.envelope("<x/>", security: header)).descendant("Username")?.text == "a<b>&\"c'")
    }

    @Test func credentialsNeverPrintTheirPassword() {
        #expect("\(credentials)" == "OnvifCredentials(username=admin, password=***)")
        #expect(String(describing: credentials) == "OnvifCredentials(username=admin, password=***)")
    }
}

/// HTTP Digest for cameras that answer ONVIF or RTSP with a challenge: RFC 2617's example and the Amcrest's
@Suite("HTTP Digest")
struct HTTPDigestTests {
    @Test func theRFC2617ExampleGivesItsPublishedResponse() throws {
        let challenge = try #require(HTTPDigest.parseChallenge(
            #"Digest realm="testrealm@host.com", qop="auth,auth-int", nonce="dcd98b7102dd2f0e8b11d0f600bfb0c093", opaque="5ccc069c403ebaf9f0171e9517f40e41""#))
        #expect(challenge.qop == "auth")
        let header = HTTPDigest.authorization(challenge, credentials: OnvifCredentials(username: "Mufasa", password: "Circle Of Life"), method: "GET",
                                              uri: "/dir/index.html", cnonce: "0a4f113b")
        #expect(header.contains(#"response="6629fae49393a05397450978507c4ef1""#))
        #expect(header.hasPrefix(#"Digest username="Mufasa", realm="testrealm@host.com""#))
        #expect(header.contains(#"qop=auth, nc=00000001, cnonce="0a4f113b""#))
        #expect(header.contains(#"opaque="5ccc069c403ebaf9f0171e9517f40e41""#))
        #expect(header.contains(#"uri="/dir/index.html""#))
    }

    @Test func theAmcrestCamerasChallengeIsRead() throws {
        let challenge = try #require(HTTPDigest.parseChallenge(try OnvifFixtures.read("amcrest-digest-challenge.txt").trimmingCharacters(in: .whitespacesAndNewlines)))
        #expect(challenge == HTTPDigest.Challenge(realm: "Login to AMC0000000000000000", nonce: "b252aWYtZGlnZXN0OjY4MDgxOTY2NzMw", qop: "auth", opaque: "", algorithm: nil))
        let header = HTTPDigest.authorization(challenge, credentials: OnvifCredentials(username: "admin", password: "pw"), method: "POST", uri: "/onvif/device_service",
                                              cnonce: "abc", nonceCount: 2)
        let ha1 = HTTPDigest.md5("admin:Login to AMC0000000000000000:pw")
        let ha2 = HTTPDigest.md5("POST:/onvif/device_service")
        #expect(header.contains("response=\"\(HTTPDigest.md5("\(ha1):b252aWYtZGlnZXN0OjY4MDgxOTY2NzMw:00000002:abc:auth:\(ha2)"))\""))
        #expect(header.contains("nc=00000002"))
    }

    @Test func withoutQopAndWithMD5Sess() throws {
        let plain = try #require(HTTPDigest.parseChallenge("Digest realm=r, nonce=n"))
        #expect(plain.qop == nil)
        let header = HTTPDigest.authorization(plain, credentials: OnvifCredentials(username: "u", password: "p"), method: "POST", uri: "/x", cnonce: "c")
        #expect(header.contains("response=\"\(HTTPDigest.md5("\(HTTPDigest.md5("u:r:p")):n:\(HTTPDigest.md5("POST:/x"))"))\""))
        #expect(!header.contains("qop="))
        // A Tapo C210 (firmware 1.2.7) refuses the right response when the header adds an unasked algorithm=MD5
        let tapo = try #require(HTTPDigest.parseChallenge(#"Digest realm="TP-LINK IP-Camera", nonce="fb93f59432fa328235d29ba4a23cb7fa""#))
        #expect(tapo.algorithm == nil)
        #expect(!HTTPDigest.authorization(tapo, credentials: OnvifCredentials(username: "u", password: "p"), method: "DESCRIBE", uri: "rtsp://cam/stream1", cnonce: "c").contains("algorithm"))
        let named = try #require(HTTPDigest.parseChallenge(#"Digest realm="r", nonce="n", algorithm="MD5""#))
        #expect(HTTPDigest.authorization(named, credentials: OnvifCredentials(username: "u", password: "p"), method: "GET", uri: "/", cnonce: "c").hasSuffix(", algorithm=MD5"))
        let session = try #require(HTTPDigest.parseChallenge(#"Digest realm="r", nonce="n", qop="auth", algorithm=MD5-sess"#))
        let sessionHeader = HTTPDigest.authorization(session, credentials: OnvifCredentials(username: "u", password: "p"), method: "POST", uri: "/x", cnonce: "c")
        let ha1 = HTTPDigest.md5("\(HTTPDigest.md5("u:r:p")):n:c")
        #expect(sessionHeader.contains("response=\"\(HTTPDigest.md5("\(ha1):n:00000001:c:auth:\(HTTPDigest.md5("POST:/x"))"))\""))
        #expect(sessionHeader.hasSuffix("algorithm=MD5-sess"))
    }

    @Test func basicEmptyOrIncompleteChallengesAreNotDigestChallenges() {
        #expect(HTTPDigest.parseChallenge(nil) == nil)
        #expect(HTTPDigest.parseChallenge(#"Basic realm="cam""#) == nil)
        #expect(HTTPDigest.parseChallenge(#"Digest realm="cam""#) == nil)
        #expect(HTTPDigest.parseChallenge(#"Digest nonce="n""#) == nil)
        #expect(HTTPDigest.parseChallenge(#"Digest realm=r, nonce=n, qop="auth-int""#)?.qop == nil)
    }

    @Test func quotedValuesKeepCommasAndEscapesAndUserNamesAreQuoted() {
        #expect(HTTPDigest.parameters(#" realm="a, \"b\"", nonce=n"#) == ["realm": #"a, "b""#, "nonce": "n"])
        let header = HTTPDigest.authorization(HTTPDigest.Challenge(realm: "r", nonce: "n"), credentials: OnvifCredentials(username: #"we"ird"#, password: "p"),
                                              method: "POST", uri: "/", cnonce: "c")
        #expect(header.hasPrefix(#"Digest username="we\"ird""#))
        #expect(HTTPDigest.cnonce().count == 32)
        #expect(HTTPDigest.basic(OnvifCredentials(username: "Aladdin", password: "open sesame")) == "Basic QWxhZGRpbjpvcGVuIHNlc2FtZQ==")
    }
}

/// Reading cameras' answers whatever their prefixes: the real Amcrest answers, other clients' tests'
/// answers, SOAP 1.2 and 1.1 faults, and refusing what is not plain XML
@Suite("ONVIF answers")
struct OnvifParserTests {
    let device = "http://10.20.0.204/onvif/device_service"
    let envelope = OnvifFixtures.envelope

    @Test func theAmcrestCamerasClock() throws {
        let date = OnvifParser.systemDateAndTime(try SoapXML.parse(try OnvifFixtures.read("amcrest-system-date-and-time.xml")))
        #expect(date == ISO8601DateFormatter().date(from: "2026-10-27T00:51:47Z"))
        #expect(OnvifParser.systemDateAndTime(try SoapXML.parse(envelope("<tds:GetSystemDateAndTimeResponse/>"))) == nil)
    }

    @Test func theAmcrestCamerasCapabilitiesAndServices() throws {
        let capabilities = try OnvifParser.capabilities(try SoapXML.parse(try OnvifFixtures.read("amcrest-capabilities.xml")), deviceURL: device)
        // It has no PTZ service: the analytics, imaging and device XAddrs are not taken for one
        #expect(capabilities == OnvifEndpoints(mediaURL: "http://10.20.0.204/onvif/media_service", ptzURL: nil, eventsURL: "http://10.20.0.204/onvif/event_service"))
        let services = try OnvifParser.services(try SoapXML.parse(try OnvifFixtures.read("amcrest-services.xml")), deviceURL: device)
        #expect(services == capabilities)
    }

    @Test func capabilitiesGiveTheMediaPTZAndEventsServices() throws {
        let xml = try SoapXML.parse(envelope("""
            <tds:GetCapabilitiesResponse><tds:Capabilities>
              <tt:Device><tt:XAddr>http://10.20.0.204/onvif/device_service</tt:XAddr></tt:Device>
              <tt:Events><tt:XAddr>http://10.20.0.204/onvif/event_service</tt:XAddr><tt:WSPullPointSupport>true</tt:WSPullPointSupport></tt:Events>
              <tt:Media><tt:XAddr>http://10.20.0.204:8000/onvif/media_service</tt:XAddr>
                <tt:StreamingCapabilities><tt:RTP_RTSP_TCP>true</tt:RTP_RTSP_TCP></tt:StreamingCapabilities></tt:Media>
              <tt:PTZ><tt:XAddr>http://10.20.0.204/onvif/ptz_service</tt:XAddr></tt:PTZ>
            </tds:Capabilities></tds:GetCapabilitiesResponse>
            """))
        #expect(try OnvifParser.capabilities(xml, deviceURL: device)
            == OnvifEndpoints(mediaURL: "http://10.20.0.204:8000/onvif/media_service", ptzURL: "http://10.20.0.204/onvif/ptz_service", eventsURL: "http://10.20.0.204/onvif/event_service"))
        // Without a Media service: the default path next to the device service
        let bare = try SoapXML.parse(envelope("<tds:GetCapabilitiesResponse><tds:Capabilities>" +
                                              "<tt:Device><tt:XAddr>x</tt:XAddr></tt:Device></tds:Capabilities></tds:GetCapabilitiesResponse>"))
        #expect(try OnvifParser.capabilities(bare, deviceURL: "http://cam:8080/onvif/device_service") == OnvifEndpoints(mediaURL: "http://cam:8080/onvif/media_service"))
        #expect(throws: OnvifError.invalidResponse("Capabilities")) { try OnvifParser.capabilities(try SoapXML.parse(envelope("<x/>")), deviceURL: device) }
    }

    @Test func serviceAddressesOnAnotherHostAreMovedToTheCamerasAddress() throws {
        let xml = try SoapXML.parse(envelope("<tds:GetCapabilitiesResponse><tds:Capabilities><tt:Media><tt:XAddr>http://192.168.0.2:8899/onvif/media</tt:XAddr></tt:Media></tds:Capabilities></tds:GetCapabilitiesResponse>"))
        #expect(try OnvifParser.capabilities(xml, deviceURL: device).mediaURL == "http://10.20.0.204:8899/onvif/media")
        #expect(OnvifURLs.onHost("rtsp://u:p@0.0.0.0:554/a?b=1&c=2", reference: device) == "rtsp://u:p@10.20.0.204:554/a?b=1&c=2")
        #expect(OnvifURLs.onHost("rtsp://10.20.0.204/live", reference: device) == "rtsp://10.20.0.204/live")
        #expect(OnvifURLs.onHost("not a url", reference: device) == "not a url")
        #expect(OnvifURLs.sibling("http://cam/onvif/device_service?x=1", "media_service") == "http://cam/onvif/media_service")
        #expect(OnvifURLs.sibling("http://cam", "media_service") == "http://cam/media_service")
        #expect(OnvifURLs.deviceService(host: "10.0.0.5", port: 80) == "http://10.0.0.5/onvif/device_service")
        #expect(OnvifURLs.deviceService(host: "fe80::1", port: 8080) == "http://[fe80::1]:8080/onvif/device_service")
        #expect(OnvifURLs.requestTarget("http://cam/onvif/device_service?a=1") == "/onvif/device_service?a=1")
        #expect(OnvifURLs.requestTarget("http://cam") == "/")
    }

    @Test func getServicesByNamespace() throws {
        let xml = try SoapXML.parse(envelope(
            "<tds:GetServicesResponse>"
                + "<tds:Service><tds:Namespace>http://www.onvif.org/ver10/media/wsdl</tds:Namespace><tds:XAddr>http://10.20.0.204/media</tds:XAddr></tds:Service>"
                + "<tds:Service><tds:Namespace>http://www.onvif.org/ver20/ptz/wsdl</tds:Namespace><tds:XAddr>http://10.20.0.204/ptz</tds:XAddr></tds:Service>"
                + "</tds:GetServicesResponse>"))
        #expect(try OnvifParser.services(xml, deviceURL: device) == OnvifEndpoints(mediaURL: "http://10.20.0.204/media", ptzURL: "http://10.20.0.204/ptz"))
        #expect(throws: OnvifError.self) { try OnvifParser.services(try SoapXML.parse(envelope("<x/>")), deviceURL: device) }
    }

    @Test func deviceInformationWhateverThePrefixMissingFieldsEmpty() throws {
        let xml = try SoapXML.parse(envelope("""
            <tds:GetDeviceInformationResponse>
              <tds:Manufacturer>Reolink</tds:Manufacturer>
              <tds:Model>E1 Zoom</tds:Model>
              <tds:FirmwareVersion>v3.1.0.2368</tds:FirmwareVersion>
              <SerialNumber>00000000000000</SerialNumber>
              <tds:HardwareId>IPC_566SD54MP</tds:HardwareId>
            </tds:GetDeviceInformationResponse>
            """))
        let info = try OnvifParser.deviceInformation(xml)
        #expect(info == OnvifDeviceInformation(manufacturer: "Reolink", model: "E1 Zoom", firmwareVersion: "v3.1.0.2368",
                                               serialNumber: "00000000000000", hardwareId: "IPC_566SD54MP"))
        #expect(info.displayName == "Reolink E1 Zoom")
        let partial = try OnvifParser.deviceInformation(try SoapXML.parse(envelope("<tds:GetDeviceInformationResponse>" +
                                                                                   "<tds:Model>X</tds:Model></tds:GetDeviceInformationResponse>")))
        #expect(partial == OnvifDeviceInformation(model: "X"))
        #expect(OnvifDeviceInformation().displayName == nil)
    }

    @Test func profilesWithTokenNameResolutionEncodingAndPTZ() throws {
        let xml = try SoapXML.parse(envelope("""
            <trt:GetProfilesResponse>
              <trt:Profiles token="MainStream" fixed="true">
                <tt:Name>mainStream</tt:Name>
                <tt:VideoSourceConfiguration token="VideoSource"><tt:Name>VideoSource</tt:Name>
                  <tt:Bounds x="0" y="0" width="2560" height="1920"></tt:Bounds></tt:VideoSourceConfiguration>
                <tt:VideoEncoderConfiguration token="Main"><tt:Name>Main</tt:Name><tt:Encoding>H264</tt:Encoding>
                  <tt:Resolution><tt:Width>2560</tt:Width><tt:Height>1920</tt:Height></tt:Resolution></tt:VideoEncoderConfiguration>
                <tt:PTZConfiguration token="ptz0"><tt:Name>PTZ</tt:Name></tt:PTZConfiguration>
              </trt:Profiles>
              <trt:Profiles fixed="true" token="SubStream">
                <tt:VideoEncoderConfiguration token="Sub"><tt:Resolution><tt:Width>640</tt:Width><tt:Height>480</tt:Height></tt:Resolution></tt:VideoEncoderConfiguration>
              </trt:Profiles>
              <trt:Profiles token="Audio"><tt:Name>audio only</tt:Name></trt:Profiles>
            </trt:GetProfilesResponse>
            """))
        #expect(try OnvifParser.profiles(xml) == [
            OnvifProfile(token: "MainStream", name: "mainStream", width: 2560, height: 1920, encoding: "H264", hasPtz: true),
            // No name: the token names it
            OnvifProfile(token: "SubStream", name: "SubStream", width: 640, height: 480),
            // No video: no resolution
            OnvifProfile(token: "Audio", name: "audio only"),
        ])
        let vue = try SoapXML.parse(envelope(
            "<trt:GetProfilesResponse><trt:Profiles token=\"Profile000\"><trt:Name>MainStream</trt:Name><trt:VideoEncoderConfiguration>"
                + "<trt:Resolution><trt:Width>1920</trt:Width><trt:Height>1080</trt:Height></trt:Resolution></trt:VideoEncoderConfiguration>"
                + "</trt:Profiles></trt:GetProfilesResponse>"))
        #expect(try OnvifParser.profiles(vue) == [OnvifProfile(token: "Profile000", name: "MainStream", width: 1920, height: 1080)])
        #expect(try OnvifParser.profiles(try SoapXML.parse(envelope("<trt:GetProfilesResponse></trt:GetProfilesResponse>"))).isEmpty)
    }

    @Test func streamAndSnapshotURIsWithTheirEntitiesDecoded() throws {
        let xml = try SoapXML.parse(envelope(
            "<trt:GetStreamUriResponse><trt:MediaUri><tt:Uri>rtsp://10.20.0.204:554/cam/realmonitor?channel=1&amp;subtype=0</tt:Uri>"
                + "<tt:InvalidAfterConnect>false</tt:InvalidAfterConnect><tt:Timeout>PT60S</tt:Timeout></trt:MediaUri></trt:GetStreamUriResponse>"))
        #expect(try OnvifParser.mediaURI(xml, response: "GetStreamUriResponse") == "rtsp://10.20.0.204:554/cam/realmonitor?channel=1&subtype=0")
        #expect(throws: OnvifError.invalidResponse("Uri")) {
            try OnvifParser.mediaURI(try SoapXML.parse(envelope("<trt:GetStreamUriResponse/>")), response: "GetStreamUriResponse")
        }
        #expect(throws: OnvifError.invalidResponse("GetSnapshotUriResponse")) { try OnvifParser.mediaURI(xml, response: "GetSnapshotUriResponse") }
    }

    @Test func soap12FaultsAuthenticationFaultsAndSoap11Faults() throws {
        let notAuthorized = envelope(
            "<SOAP-ENV:Fault><SOAP-ENV:Code><SOAP-ENV:Value>SOAP-ENV:Sender</SOAP-ENV:Value><SOAP-ENV:Subcode><SOAP-ENV:Value>ter:NotAuthorized</SOAP-ENV:Value>"
                + "</SOAP-ENV:Subcode></SOAP-ENV:Code><SOAP-ENV:Reason><SOAP-ENV:Text xml:lang=\"en\">Sender not Authorized</SOAP-ENV:Text></SOAP-ENV:Reason></SOAP-ENV:Fault>")
        #expect(OnvifParser.fault(try SoapXML.parse(notAuthorized)) == .unauthorized)
        #expect(OnvifParser.fault(try SoapXML.parse(envelope("<SOAP-ENV:Fault><SOAP-ENV:Reason>Sender not authorized</SOAP-ENV:Reason></SOAP-ENV:Fault>"))) == .unauthorized)
        let other = envelope(
            "<SOAP-ENV:Fault><SOAP-ENV:Code><SOAP-ENV:Value>SOAP-ENV:Receiver</SOAP-ENV:Value><SOAP-ENV:Subcode><SOAP-ENV:Value>ter:ActionNotSupported</SOAP-ENV:Value>"
                + "</SOAP-ENV:Subcode></SOAP-ENV:Code><SOAP-ENV:Reason><SOAP-ENV:Text>Optional Action Not Implemented</SOAP-ENV:Text></SOAP-ENV:Reason></SOAP-ENV:Fault>")
        #expect(OnvifParser.fault(try SoapXML.parse(other)) == .fault(code: "SOAP-ENV:Receiver", subcode: "ter:ActionNotSupported", reason: "Optional Action Not Implemented"))
        let soap11 = #"<s:Envelope xmlns:s="http://schemas.xmlsoap.org/soap/envelope/"><s:Body><s:Fault><faultcode>s:Client</faultcode>"#
            + "<faultstring>Bad profile</faultstring></s:Fault></s:Body></s:Envelope>"
        #expect(OnvifParser.fault(try SoapXML.parse(soap11)) == .fault(code: "s:Client", subcode: nil, reason: "Bad profile"))
        #expect(OnvifParser.fault(try SoapXML.parse(envelope("<tptz:StopResponse/>"))) == nil)
    }

    @Test func whatIsNotPlainXMLIsRefused() throws {
        #expect(throws: OnvifError.invalidResponse("empty")) { try SoapXML.parse("") }
        #expect(throws: OnvifError.invalidResponse("xml")) { try SoapXML.parse("<html><body>Login</body>") }
        // No DTDs or entities (XXE)
        #expect(throws: OnvifError.invalidResponse("doctype")) { try SoapXML.parse(#"<?xml version="1.0"?><!DOCTYPE r [<!ENTITY x SYSTEM "file:///etc/passwd">]><r>&x;</r>"#) }
        // A byte order mark and leading blank lines are fine
        #expect(try SoapXML.parse("\u{FEFF}\n  <r a:b=\"1\" xmlns:a=\"urn:a\"/>").name == "r")
        #expect(try SoapXML.parse("<r a:b=\"1\" xmlns:a=\"urn:a\"/>").attribute("b") == "1")
        #expect(try SoapXML.parse("<r/>").attribute("b") == nil)
        #expect(try SoapXML.parse("<r/>").path("a", "b") == nil)
    }
}
