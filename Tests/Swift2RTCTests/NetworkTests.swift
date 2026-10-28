import Darwin
import Foundation
import Testing
@testable import Swift2RTCCore
@testable import Swift2RTCOnvif

/// The subnets of this device's current network, and plain HTTP and RTSP to cameras only there or at private
/// addresses, never the internet
@Suite("Local network")
@MainActor
struct LocalNetworkTests {
    func ip(_ text: String) -> InetAddress { InetAddress(text)! }

    @Test func anIPv4Slash24HoldsItsOwnAddressesOnly() {
        let network = LocalNetwork(subnets: [.parse("192.168.1.23/24")])
        #expect(network.allows(ip("192.168.1.64")))
        #expect(network.allows(ip("192.168.1.1")))
        for other in ["192.168.2.64", "10.20.0.204", "172.16.0.5", "8.8.8.8", "169.254.1.1"] { #expect(!network.allows(ip(other)), "\(other)") }
        // Never loopback, multicast or the unspecified address, whatever the subnets
        let loose = LocalNetwork(subnets: [.parse("127.0.0.1/8"), .parse("224.0.0.1/4"), .parse("0.0.0.0/1")])
        for special in ["127.0.0.1", "239.255.255.250", "0.0.0.0"] { #expect(!loose.allows(ip(special)), "\(special)") }
        #expect(network.describe() == "192.168.1.23/24")
        // The same answer off the main actor
        #expect(network.allowsFromAnyThread(ip("192.168.1.64")))
        #expect(!network.allowsFromAnyThread(ip("10.20.0.204")))
    }

    @Test func otherPrefixesCutWhereTheySay() {
        let wide = LinkSubnet.parse("10.20.0.74/16")
        #expect(wide.contains(ip("10.20.255.1")))
        #expect(!wide.contains(ip("10.21.0.1")))
        let odd = LinkSubnet.parse("172.20.5.9/20")
        #expect(odd.contains(ip("172.20.0.1")))
        #expect(odd.contains(ip("172.20.15.254")))
        #expect(!odd.contains(ip("172.20.16.1")))
        let small = LinkSubnet.parse("192.168.1.130/25")
        #expect(small.contains(ip("192.168.1.200")))
        #expect(!small.contains(ip("192.168.1.64")))
        #expect(LinkSubnet.parse("192.168.1.5/32").contains(ip("192.168.1.5")))
        #expect(!LinkSubnet.parse("192.168.1.5/0").contains(ip("192.168.1.5")))
        #expect(!LinkSubnet.parse("192.168.1.5/33").contains(ip("192.168.1.5")))
        #expect(!LinkSubnet.parse("192.168.1.5/24").contains(ip("fe80::1")))
    }

    @Test func ipv6GlobalAndLinkLocalSubnetsTheLinkLocalScopeMustMatch() {
        let network = LocalNetwork(subnets: [.parse("2001:db8:1:2::10/64"), .parse("fe80::10/64")])
        #expect(network.allows(ip("2001:db8:1:2::abcd")))
        #expect(!network.allows(ip("2001:db8:1:3::1")))
        #expect(network.allows(ip("fe80::99")))
        let wlan = LinkSubnet(address: InetAddress(bytes: ip("fe80::10").bytes, scope: 3), prefixLength: 64)
        #expect(!wlan.contains(InetAddress(bytes: ip("fe80::99").bytes, scope: 4)))
        #expect(wlan.contains(InetAddress(bytes: ip("fe80::99").bytes, scope: 3)))
        #expect(network.describe() == "2001:db8:1:2::10/64, fe80::10/64")
    }

    @Test func noNetworkAllowsNothingChangesCountGenerationsOneDNSAnswerIsPickedFrom() {
        let network = LocalNetwork()
        #expect(!network.isConnected)
        #expect(!network.allows(ip("192.168.1.64")))
        network.subnetsChanged([.parse("192.168.1.23/24")])
        #expect(network.generation == 1)
        network.subnetsChanged([.parse("192.168.1.23/24")])
        #expect(network.generation == 1)
        #expect(network.pick([ip("10.0.0.1"), ip("192.168.1.64")]) == ip("192.168.1.64"))
        #expect(network.pick([ip("10.0.0.1")]) == nil)
        network.subnetsChanged([])
        #expect(network.generation == 2)
        #expect(network.pick([ip("192.168.1.64")]) == nil)
    }

    @Test func camerasMayAlsoBeAtPrivateAddressesOfOtherSubnetsNeverOnTheInternet() {
        let network = LocalNetwork(subnets: [.parse("10.0.2.16/24")])
        // The emulator's NAT, a VPN: the camera's home address is still private
        for address in ["10.20.0.204", "172.16.0.5", "172.31.255.1", "192.168.1.64", "169.254.1.1", "100.64.0.7", "fd00::5", "fe80::1"] {
            #expect(network.allowsCamera(ip(address)), "\(address)")
            #expect(ip(address).isPrivate, "\(address)")
        }
        for address in ["8.8.8.8", "172.32.0.1", "100.128.0.1", "2001:db8::1", "127.0.0.1", "239.255.255.250", "0.0.0.0", "::1"] {
            #expect(!network.allowsCamera(ip(address)), "\(address)")
        }
        // A public address on the device's own subnet stays allowed (IPv6 LANs)
        #expect(LocalNetwork(subnets: [.parse("2001:db8:1:2::10/64")]).allowsCamera(ip("2001:db8:1:2::abcd")))
        // On the subnet first, then any private address
        #expect(network.pickCamera([ip("10.20.0.204"), ip("10.0.2.9")]) == ip("10.0.2.9"))
        #expect(network.pickCamera([ip("8.8.8.8"), ip("10.20.0.204")]) == ip("10.20.0.204"))
        // Without a network nothing
        #expect(!LocalNetwork().allowsCamera(ip("10.20.0.204")))
    }

    @Test func addressLiteralsAndThisMachinesInterfaces() async throws {
        #expect(InetAddress("192.168.1.64")?.bytes == [192, 168, 1, 64])
        #expect(InetAddress("[fe80::1]")?.description == "fe80::1")
        #expect(InetAddress("fe80::1%lo0")?.scope == if_nametoindex("lo0"))
        #expect(InetAddress("camera.lan") == nil)
        #expect(InetAddress("::1")!.isLoopback)
        #expect(InetAddress("fe80::1")!.urlHost == "[fe80::1]")
        // Loopback is left out of the interfaces' subnets
        let all = InterfaceSubnets.read(names: ["lo0"])
        #expect(all.isEmpty)
        #expect(try await HostResolver.resolve("127.0.0.1") == [InetAddress("127.0.0.1")!])
        #expect(try await HostResolver.resolve("localhost").contains { $0.isLoopback })
    }

    @Test func ipv6HostsAreBracketed() {
        #expect(RTSPURLs.withHost("rtsp://u:p@cam:554/a", InetAddress("fd00::5")!) == "rtsp://u:p@[fd00::5]:554/a")
        #expect(RTSPURLs.withHost("rtsp://[fe80::1]/a", InetAddress("10.0.0.1")!) == "rtsp://10.0.0.1/a")
        #expect(RTSPURLs.withHost("not a [url", InetAddress("10.0.0.1")!) == "not a [url")
    }

    @Test func credentialsGoIntoTheURLPercentEncodedAndComeOutDecoded() throws {
        let url = RTSPURLs.withCredentials("rtsp://cam:554/live?a=1", OnvifCredentials(username: "ad min", password: "p@ss:w/rd"))
        #expect(url == "rtsp://ad%20min:p%40ss%3Aw%2Frd@cam:554/live?a=1")
        let (bare, credentials) = RTSPURLs.split(url)
        #expect(bare == "rtsp://cam:554/live?a=1")
        #expect(credentials == OnvifCredentials(username: "ad min", password: "p@ss:w/rd"))
        #expect(RTSPURLs.split("rtsp://cam/live").0 == "rtsp://cam/live")
        #expect(RTSPURLs.split("rtsp://cam/live").1 == nil)
        #expect(RTSPURLs.withCredentials("rtsp://cam/live", nil) == "rtsp://cam/live")
        #expect(RTSPURLs.redacted(url) == "rtsp://cam:554/live")
    }
}

/// The probe without credentials (ONVIF GetSystemDateAndTime, the RTSP port without a device service), the
/// identity by unicast WS-Discovery or GetEndpointReference, and the trust rules that decide whether the login may go
/// to the device at a camera's address
@Suite("Camera probe")
struct CameraProbeTests {
    /// Records requests and answers with `handler`
    final class RecordingLan: LanHTTPTransport {
        var requests: [LanRequest] = []
        var handler: (LanRequest) throws -> LanResponse

        init(handler: @escaping (LanRequest) throws -> LanResponse) {
            self.handler = handler
        }

        func send(_ request: LanRequest) async throws -> LanResponse {
            requests.append(request)
            return try handler(request)
        }
    }

    func camera(deviceURL: String = "http://10.20.0.204/onvif/device_service", stream: String = "rtsp://10.20.0.204:554/live") -> ProbeTarget {
        ProbeTarget(deviceURL: deviceURL, streamURI: stream)
    }

    @Test func theTrustRules() {
        let home = CameraFingerprint(endpoint: "urn:uuid:A1B2C3D4-0000", hardware: "IP8M-2493E")
        // Recorded: only the same reference
        #expect(CameraIdentity.trust(recorded: "a1b2c3d4-0000", seen: home, onSubnet: false, model: nil) == .verified)
        #expect(CameraIdentity.trust(recorded: "other", seen: home, onSubnet: true, model: "IP8M-2493E") == .mismatch)
        #expect(CameraIdentity.trust(recorded: "a1b2c3d4-0000", seen: nil, onSubnet: true, model: nil) == .unverified)
        #expect(CameraIdentity.trust(recorded: "a1b2c3d4-0000", seen: CameraFingerprint(endpoint: nil, hardware: "IP8M-2493E"), onSubnet: true, model: nil) == .unverified)
        // Not recorded: the camera's subnet, or the stored model
        #expect(CameraIdentity.trust(recorded: nil, seen: nil, onSubnet: true, model: nil) == .firstUse)
        #expect(CameraIdentity.trust(recorded: nil, seen: home, onSubnet: false, model: "IP8M-2493EB") == .firstUse)
        #expect(CameraIdentity.trust(recorded: nil, seen: home, onSubnet: false, model: "D101S") == .unverified)
        #expect(CameraIdentity.trust(recorded: nil, seen: home, onSubnet: false, model: nil) == .unverified)
        #expect(CameraIdentity.trust(recorded: nil, seen: nil, onSubnet: false, model: "IP8M-2493EB") == .unverified)
    }

    @Test func referencesAndModelsCompareLooselyDiscoveryFallbacksDoNotCount() throws {
        #expect(CameraIdentity.normalize(" urn:uuid:ABC-1 ") == "abc-1")
        #expect(CameraIdentity.normalize("uuid:abc-1") == "abc-1")
        #expect(CameraIdentity.normalize("") == nil)
        #expect(CameraIdentity.normalize(nil) == nil)
        #expect(CameraIdentity.sameModel("IP8M-2493EB", "ip8m 2493e"))
        #expect(CameraIdentity.sameModel("IP8M-2493E", "IP8M-2493E"))
        #expect(!CameraIdentity.sameModel("IP8M-2493E", "IP5M-1173E"))
        // Too short to mean anything
        #expect(!CameraIdentity.sameModel("IPC", "IPC"))
        #expect(!CameraIdentity.sameModel(nil, "IP8M-2493E"))
        let parsed = try #require(WSDiscoveryMessages.parse(try OnvifFixtures.read("amcrest-probe-match.xml")).first)
        #expect(CameraFingerprint.of(parsed) == CameraFingerprint(endpoint: "uuid:a1b2c3d4-0000-4000-8000-000000000001", hardware: "IP8M-2493E"))
        let bare = DiscoveredDevice(endpoint: "http://10.0.0.5/onvif/device_service", name: "ONVIF Camera", hardware: WSDiscoveryMessages.defaultHardware,
                                    host: "10.0.0.5", port: 80, deviceURL: "http://10.0.0.5/onvif/device_service")
        #expect(CameraFingerprint.of(bare) == CameraFingerprint(endpoint: nil, hardware: nil))
    }

    @Test func answeringIsAnUnauthenticatedGetSystemDateAndTimeAtTheCheckedAddress() async {
        let transport = RecordingLan { _ in LanResponse(status: 200, body: Data(FakeOnvifCamera.systemDateAndTime.utf8)) }
        let probe = NetworkCameraProbe(transport: transport, allows: { _ in true })
        #expect(await probe.answers(InetAddress("10.20.0.204")!, camera: camera(deviceURL: "http://driveway.lan/onvif/device_service")))
        let request = transport.requests.last!
        #expect(request.url == "http://10.20.0.204/onvif/device_service")
        #expect(request.timeout == NetworkCameraProbe.defaultTimeout)
        let body = String(decoding: request.body, as: UTF8.self)
        #expect(body.contains("GetSystemDateAndTime"))
        // No credentials of any kind
        #expect(!body.contains("UsernameToken"))
        #expect(request.header("Authorization") == nil)
        // Any HTTP answer counts (a 401 is a camera too); no answer does not
        transport.handler = { _ in LanResponse(status: 401) }
        #expect(await probe.answers(InetAddress("10.20.0.204")!, camera: camera()))
        transport.handler = { _ in throw URLError(.timedOut) }
        #expect(!(await probe.answers(InetAddress("10.20.0.204")!, camera: camera())))
    }

    @Test func addressesThatAreNotAllowedAreNeverCalled() async {
        let transport = RecordingLan { _ in LanResponse(status: 200) }
        let probe = NetworkCameraProbe(transport: transport, allows: { _ in false })
        #expect(!(await probe.answers(InetAddress("8.8.8.8")!, camera: camera())))
        #expect(await probe.identify(InetAddress("8.8.8.8")!, camera: camera()) == nil)
        #expect(transport.requests.isEmpty)
    }

    @Test func withoutADeviceServiceTheRTSPPortIsTried() async {
        let probe = NetworkCameraProbe(transport: RecordingLan { _ in LanResponse(status: 200) }, allows: { _ in true }, timeout: 0.5)
        // Nothing listens on this port of this machine: refused at once
        #expect(!(await probe.answers(InetAddress("127.0.0.1")!, camera: camera(deviceURL: "", stream: "rtsp://cam:9/live"))))
        #expect(NetworkCameraProbe.rtspPort("rtsp://cam/live") == 554)
        #expect(NetworkCameraProbe.rtspPort("rtsp://cam:8554/live") == 8554)
    }

    @Test func identityFromAUnicastWSDiscoveryProbe() async throws {
        let responder = try UDPResponder(answers: [try OnvifFixtures.read("amcrest-probe-match.xml")], rounds: 1)
        let transport = RecordingLan { _ in LanResponse(status: 200) }
        let probe = NetworkCameraProbe(transport: transport, allows: { _ in true }, discoveryPort: responder.port)
        let found = await probe.identify(InetAddress("127.0.0.1")!, camera: camera())
        let probes = await responder.finish()
        #expect(found == CameraFingerprint(endpoint: "uuid:a1b2c3d4-0000-4000-8000-000000000001", hardware: "IP8M-2493E"))
        #expect(probes.first?.contains("NetworkVideoTransmitter") == true)
        // HTTP was not needed
        #expect(transport.requests.isEmpty)
    }

    @Test func identityFromGetEndpointReferenceWhenDiscoveryIsSilentElseNone() async throws {
        let silent = try UDPResponder(answers: [], rounds: 0)
        let endpoint = FakeOnvifCamera.envelope("<tds:GetEndpointReferenceResponse><tds:GUID>urn:uuid:doorbird-1</tds:GUID></tds:GetEndpointReferenceResponse>")
        let transport = RecordingLan { _ in LanResponse(status: 200, body: Data(endpoint.utf8)) }
        let probe = NetworkCameraProbe(transport: transport, allows: { _ in true }, timeout: 0.2, discoveryPort: silent.port)
        #expect(await probe.identify(InetAddress("127.0.0.1")!, camera: camera(deviceURL: "http://cam/onvif/device_service")) == CameraFingerprint(endpoint: "urn:uuid:doorbird-1"))
        #expect(String(decoding: transport.requests.last!.body, as: UTF8.self).contains("GetEndpointReference"))
        #expect(transport.requests.last?.url == "http://127.0.0.1/onvif/device_service")
        // Amcrest: not implemented (a fault), and failures: nothing to tell
        transport.handler = { _ in LanResponse(status: 500, body: Data(FakeOnvifCamera.fault("ter:ActionNotSupported", "Not implemented").utf8)) }
        #expect(await probe.identify(InetAddress("127.0.0.1")!, camera: camera()) == nil)
        transport.handler = { _ in throw URLError(.timedOut) }
        #expect(await probe.identify(InetAddress("127.0.0.1")!, camera: camera()) == nil)
        #expect(await probe.identify(InetAddress("127.0.0.1")!, camera: camera(deviceURL: "")) == nil)
        _ = await silent.finish()
    }
}

/// WS-Discovery: the Probe, the ProbeMatches of real cameras (Amcrest, DoorBird)
/// and a hand-written one, and a probe over UDP to a responder on this machine
@Suite("WS-Discovery")
struct WSDiscoveryTests {
    @Test func theProbeAsksForNetworkVideoTransmitterWithAFreshMessageId() throws {
        let probe = WSDiscoveryMessages.probe(messageId: "urn:uuid:test")
        #expect(probe.contains("<d:Types>dn:NetworkVideoTransmitter</d:Types>"))
        #expect(probe.contains("http://schemas.xmlsoap.org/ws/2005/04/discovery/Probe"))
        #expect(probe.contains("<w:MessageID>urn:uuid:test</w:MessageID>"))
        let first = WSDiscoveryMessages.probe()
        #expect(WSDiscoveryMessages.probe() != first)
        #expect(try SoapXML.parse(probe).descendant("Body")?.children.map(\.name) == ["Probe"])
    }

    @Test func theRealCamerasAnswers() throws {
        #expect(WSDiscoveryMessages.parse(try OnvifFixtures.read("amcrest-probe-match.xml")) == [
            DiscoveredDevice(endpoint: "uuid:a1b2c3d4-0000-4000-8000-000000000001", name: "Amcrest", hardware: "IP8M-2493E", host: "10.20.0.204", port: 80,
                             deviceURL: "http://10.20.0.204/onvif/device_service"),
        ])
        #expect(WSDiscoveryMessages.parse(try OnvifFixtures.read("doorbird-probe-match.xml")) == [
            DiscoveredDevice(endpoint: "urn:uuid:0d0b1d00-0000-4000-8000-000000000002", name: "DoorBird_D101S", hardware: "IntercomDoorBirdOne", host: "10.20.0.185",
                             port: 80, deviceURL: "http://10.20.0.185/onvif/device_service"),
        ])
    }

    @Test func aDiscoveryAnswerWithSeveralAddressesDefaultsAndJunk() throws {
        let vue = """
            <e:Envelope xmlns:e="http://www.w3.org/2003/05/soap-envelope" xmlns:d="http://schemas.xmlsoap.org/ws/2005/04/discovery">
              <e:Body><d:ProbeMatches><d:ProbeMatch>
                <d:Types>dn:NetworkVideoTransmitter</d:Types>
                <d:Scopes>onvif://www.onvif.org/name/Amcrest%20Nursery onvif://www.onvif.org/hardware/IP4M-1051</d:Scopes>
                <d:XAddrs>http://10.20.0.204/onvif/device_service</d:XAddrs>
              </d:ProbeMatch></d:ProbeMatches></e:Body>
            </e:Envelope>
            """
        let device = try #require(WSDiscoveryMessages.parse(vue).first)
        #expect(device.host == "10.20.0.204")
        #expect(device.port == 80)
        #expect(device.name == "Amcrest Nursery")
        #expect(device.hardware == "IP4M-1051")
        #expect(device.deviceURL == "http://10.20.0.204/onvif/device_service")
        // Without an endpoint reference the device URL identifies it
        #expect(device.endpoint == "http://10.20.0.204/onvif/device_service")

        let several = vue.replacingOccurrences(of: "<d:XAddrs>http://10.20.0.204/onvif/device_service</d:XAddrs>",
                                               with: "<d:XAddrs>http://[fe80::1]:8080/onvif/device_service http://192.168.1.9:8080/onvif/device_service</d:XAddrs>")
            .replacingOccurrences(of: "<d:Scopes>onvif://www.onvif.org/name/Amcrest%20Nursery onvif://www.onvif.org/hardware/IP4M-1051</d:Scopes>", with: "")
        let ipv4 = try #require(WSDiscoveryMessages.parse(several).first)
        #expect(ipv4.host == "192.168.1.9")
        #expect(ipv4.port == 8080)
        #expect(ipv4.name == WSDiscoveryMessages.defaultName)
        #expect(ipv4.hardware == WSDiscoveryMessages.defaultHardware)
        let onlyV6 = vue.replacingOccurrences(of: "http://10.20.0.204/onvif/device_service", with: "http://[fe80::1]/onvif/device_service")
        #expect(WSDiscoveryMessages.parse(onlyV6).first?.host == "fe80::1")

        #expect(WSDiscoveryMessages.parse("not xml").isEmpty)
        #expect(WSDiscoveryMessages.parse(vue.replacingOccurrences(of: "<d:XAddrs>http://10.20.0.204/onvif/device_service</d:XAddrs>", with: "")).isEmpty)
        #expect(WSDiscoveryMessages.parse(vue.replacingOccurrences(of: "http://10.20.0.204", with: "https://10.20.0.204")).isEmpty)
    }

    @Test func aProbeOverUDPCollectsEveryCameraOnceAndIgnoresOtherNetworks() async throws {
        let answers = [try OnvifFixtures.read("amcrest-probe-match.xml"), try OnvifFixtures.read("doorbird-probe-match.xml"), "garbage"]
        let responder = try UDPResponder(answers: answers, rounds: 2)
        // The DoorBird at 10.20.0.185 is outside what this probe accepts: ignored
        let discovery = WSDiscovery(accept: { $0.isLoopback || $0.description == "10.20.0.204" }, target: ("127.0.0.1", responder.port))
        let found = try await discovery.discover(timeout: 1)
        let probes = await responder.finish()
        #expect(found.map(\.host) == ["10.20.0.204"])
        #expect(probes.count == 2)
        #expect(probes.allSatisfy { $0.contains("NetworkVideoTransmitter") })
    }

    @Test func nobodyAnsweringIsAnEmptyListAfterTheTimeout() async throws {
        let silent = try UDPResponder(answers: [], rounds: 0)
        let started = Date()
        let found = try await WSDiscovery(accept: { _ in true }, target: ("127.0.0.1", silent.port)).discover(timeout: 0.3)
        _ = await silent.finish()
        #expect(found.isEmpty)
        #expect(Date().timeIntervalSince(started) >= 0.3)
    }
}
