import Foundation
import Testing
@testable import Swift2RTCCore
@testable import Swift2RTCOnvif
@testable import Swift2RTCRTSP

/// The README's quick start against the fake camera: clock, device, services, profiles, stream URI, the URL for playback;
/// the PTZ nodes and status fixtures; the SDP of cameras that also offer an audio backchannel
@Suite("End to end")
struct OnvifEndToEndTests {
    @Test func fromTheDeviceServiceToAPlayableURL() async throws {
        let camera = FakeOnvifCamera.Transport()
        let credentials = OnvifCredentials(username: FakeOnvifCamera.username, password: FakeOnvifCamera.password)
        let client = OnvifClient(transport: camera, deviceURL: OnvifURLs.deviceService(host: FakeOnvifCamera.host, port: 80), credentials: credentials)
        try await client.syncClock()
        let info = try await client.deviceInformation()
        #expect(info.displayName == "Example FK-1000")
        let endpoints = try await client.endpoints()
        #expect(endpoints == OnvifEndpoints(mediaURL: "http://192.168.1.64/onvif/media_service", ptzURL: "http://192.168.1.64/onvif/ptz_service"))
        let profiles = try await client.profiles(mediaURL: endpoints.mediaURL)
        #expect(profiles.map(\.token) == ["MainStream", "SubStream"])
        #expect(profiles[0].hasPtz && profiles[0].hasVideo)
        let stream = try await client.streamURI(mediaURL: endpoints.mediaURL, profileToken: profiles[0].token)
        #expect(stream == FakeOnvifCamera.stream)
        #expect(try await client.snapshotURI(mediaURL: endpoints.mediaURL, profileToken: profiles[0].token) == "http://192.168.1.64/onvif/snapshot?channel=1")
        let playable = RTSPURLs.withCredentials(stream, credentials)
        #expect(playable == "rtsp://admin:fake-password@192.168.1.64:554/live/main")
        #expect(RTSPURLs.split(playable).1 == credentials)

        // A wrong password: the camera's NotAuthorized fault
        let wrong = OnvifClient(transport: camera, deviceURL: client.deviceURL, credentials: OnvifCredentials(username: "admin", password: "nope"))
        await #expect(throws: OnvifError.unauthorized) { try await wrong.deviceInformation() }
        // An address the transport refuses
        let refusing = FakeOnvifCamera.Transport(allows: { _ in false })
        await #expect(throws: OnvifError.notLocal) { try await OnvifClient(transport: refusing, deviceURL: client.deviceURL, credentials: credentials).syncClock() }
    }

    @Test func ptzNodesWithAndWithoutAnOpticalZoomAndTheLensPosition() throws {
        let optical = try OnvifParser.ptzZoomSupport(try SoapXML.parse(try OnvifFixtures.read("ptz-nodes-optical-zoom.xml")))
        #expect(optical == PtzZoomSupport(optical: true, min: 0, max: 1))
        // A zoom space from 0 to 0 moves nothing
        #expect(try OnvifParser.ptzZoomSupport(try SoapXML.parse(try OnvifFixtures.read("ptz-nodes-pan-tilt-only.xml"))) == .none)
        #expect(try OnvifParser.ptzZoomPosition(try SoapXML.parse(try OnvifFixtures.read("ptz-status.xml"))) == 0.42)
        #expect(throws: OnvifError.invalidResponse("GetNodesResponse")) { try OnvifParser.ptzZoomSupport(try SoapXML.parse(OnvifFixtures.envelope("<x/>"))) }
    }

    @Test func media1ProfilesOfACameraWithAnAudioOutput() throws {
        let profiles = try OnvifParser.profiles(try SoapXML.parse(try OnvifFixtures.read("media1-profiles-audio-output.xml")))
        #expect(profiles == [
            OnvifProfile(token: "MediaProfile000", name: "MediaProfile_Channel1_MainStream", width: 3840, height: 2160, encoding: "H264", hasPtz: true),
            OnvifProfile(token: "MediaProfile001", name: "MediaProfile_Channel1_SubStream1", width: 704, height: 480, encoding: "H264"),
        ])
    }

    @Test func playbackTracksOfCamerasThatAlsoOfferABackchannel() throws {
        // Dahua: H.264, G.711 µ-law, metadata, and a sendonly backchannel the player leaves alone
        let dahua = try OnvifFixtures.read("backchannel-describe-dahua.txt")
        var parser = RTSPStreamParser()
        parser.append(Data(dahua.replacingOccurrences(of: "\r\n", with: "\n").replacingOccurrences(of: "\n", with: "\r\n").utf8))
        guard case .response(let response) = try parser.next() else {
            Issue.record("no response")
            return
        }
        #expect(response.header("Content-Base") == "rtsp://10.20.0.204:554/cam/realmonitor?channel=1&subtype=0&unicast=true&proto=Onvif/")
        let sdp = SDP.parse(String(decoding: response.body, as: UTF8.self))
        #expect(sdp.video?.codec == .h264)
        #expect(sdp.audio?.codec == .pcmu)
        #expect(sdp.audio?.control == "trackID=1")
        #expect(RTSPRequest.controlURL(sdp.video?.control, base: response.header("Content-Base")!)
            == "rtsp://10.20.0.204:554/cam/realmonitor?channel=1&subtype=0&unicast=true&proto=Onvif/trackID=0")

        let plain = SDP.parse(try OnvifFixtures.read("describe-without-backchannel.sdp"))
        #expect(plain.video?.control == "rtsp://192.168.1.30:554/Streaming/Channels/101/trackID=1")
        #expect(plain.audio?.codec == .pcmu)
        let hevc = SDP.parse(try OnvifFixtures.read("backchannel-describe-aac-only.sdp"))
        #expect(hevc.video?.codec == .h265)
        #expect(hevc.audio?.codec == .aac)
        #expect(hevc.audio?.control == "rtsp://192.168.1.20/stream1/track2")
        #expect(hevc.audio?.audioSpecificConfig == Data([0x14, 0x08]))
    }
}
