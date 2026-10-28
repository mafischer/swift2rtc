import Foundation
import Testing
@testable import Swift2RTCCore
@testable import Swift2RTCRTSP


/// The RTSP player's pure parts: responses and interleaved packets from one byte stream, SDP of real cameras,
/// RTP, H.264/H.265 depacketization, AAC AU headers, G.711
@Suite("RTSP protocol")
struct RTSPProtocolTests {
    @Test func responsesAndInterleavedPacketsAreSplitWhateverTheChunks() throws {
        let response = "RTSP/1.0 200 OK\r\nCSeq: 3\r\nSession: 12345678;timeout=60\r\nContent-Length: 4\r\n\r\nabcd"
        let packet: [UInt8] = [0x24, 2, 0, 3, 0xAA, 0xBB, 0xCC]
        let bytes = Array(response.utf8) + packet + Array("RTSP/1.0 401 Unauthorized\r\nCSeq: 4\r\nWWW-Authenticate: Digest realm=\"r\", nonce=\"n\"\r\n\r\n".utf8)
        // Fed one byte at a time, as a slow TCP stream may deliver it
        var parser = RTSPStreamParser()
        var frames: [RTSPFrame] = []
        for byte in bytes {
            parser.append(Data([byte]))
            while let frame = try parser.next() { frames.append(frame) }
        }
        #expect(frames.count == 3)
        guard case .response(let first) = frames[0], case .interleaved(let channel, let payload) = frames[1], case .response(let refused) = frames[2] else {
            Issue.record("frames \(frames)")
            return
        }
        #expect(first.status == 200)
        #expect(first.cseq == 3)
        #expect(first.sessionId == "12345678")
        #expect(first.sessionTimeout == 60)
        #expect(first.body == Data("abcd".utf8))
        #expect(channel == 2)
        #expect(payload == Data([0xAA, 0xBB, 0xCC]))
        #expect(refused.status == 401)
        #expect(refused.reason == "Unauthorized")
        #expect(HTTPDigest.parseChallenge(refused.header("www-authenticate"))?.realm == "r")
        // A session without a timeout: 60 s; junk between frames is skipped
        var junk = RTSPStreamParser()
        junk.append(Data("\r\n\r\nRTSP/1.0 200 OK\r\nCSeq: 1\r\nSession: abc\r\n\r\n".utf8))
        guard case .response(let plain) = try junk.next() else {
            Issue.record("no response")
            return
        }
        #expect(plain.sessionId == "abc")
        #expect(plain.sessionTimeout == 60)
        #expect(try junk.next() == nil)
        var broken = RTSPStreamParser()
        broken.append(Data("RTSP/1.0 abc\r\n\r\n".utf8))
        #expect(throws: RTSPError.self) { try broken.next() }
    }

    @Test func requestsTransportsAndControlURLs() {
        let request = String(decoding: RTSPRequest.make("SETUP", url: "rtsp://10.20.0.204/live/trackID=0", cseq: 4,
                                                        headers: [("Transport", RTSPRequest.tcpTransport(channel: 2)), ("Session", "12345678")]), as: UTF8.self)
        #expect(request == "SETUP rtsp://10.20.0.204/live/trackID=0 RTSP/1.0\r\nCSeq: 4\r\nUser-Agent: swift2rtc\r\nTransport: RTP/AVP/TCP;unicast;interleaved=2-3\r\nSession: 12345678\r\n\r\n")
        #expect(RTSPRequest.interleavedChannel("RTP/AVP/TCP;unicast;interleaved=4-5;ssrc=1234") == 4)
        #expect(RTSPRequest.interleavedChannel("RTP/AVP;unicast;client_port=5000-5001") == nil)
        #expect(RTSPRequest.controlURL("trackID=0", base: "rtsp://cam/live/") == "rtsp://cam/live/trackID=0")
        #expect(RTSPRequest.controlURL("trackID=0", base: "rtsp://cam/live") == "rtsp://cam/live/trackID=0")
        #expect(RTSPRequest.controlURL("rtsp://cam/other", base: "rtsp://cam/live") == "rtsp://cam/other")
        #expect(RTSPRequest.controlURL("*", base: "rtsp://cam/live") == "rtsp://cam/live")
        #expect(RTSPRequest.controlURL(nil, base: "rtsp://cam/live") == "rtsp://cam/live")
    }

    /// The SDP of an Amcrest/Dahua camera (H.264 main stream, AAC sound), as these cameras send it
    static let amcrestSDP = """
        v=0\r
        o=- 2251937001 2251937001 IN IP4 0.0.0.0\r
        s=Media Server\r
        c=IN IP4 0.0.0.0\r
        t=0 0\r
        a=control:*\r
        a=packetization-supported:DH\r
        a=range:npt=now-\r
        m=video 0 RTP/AVP 96\r
        a=control:trackID=0\r
        a=framerate:25.000000\r
        a=rtpmap:96 H264/90000\r
        a=fmtp:96 packetization-mode=1;profile-level-id=640033;sprop-parameter-sets=Z2QAM6wVFKAoAPGQ,aO48sA==\r
        a=recvonly\r
        m=audio 0 RTP/AVP 97\r
        a=control:trackID=1\r
        a=rtpmap:97 MPEG4-GENERIC/16000/1\r
        a=fmtp:97 streamtype=5;profile-level-id=1;mode=AAC-hbr;sizelength=13;indexlength=3;indexdeltalength=3;config=1408\r
        a=recvonly\r
        """

    @Test func theSDPOfAnAmcrestCameraAndOfH265AndG711Cameras() throws {
        let sdp = SDP.parse(Self.amcrestSDP)
        #expect(sdp.control == "*")
        let video = try #require(sdp.video)
        #expect(video.codec == .h264)
        #expect(video.payloadType == 96)
        #expect(video.clockRate == 90000)
        #expect(video.control == "trackID=0")
        #expect(video.parameterSets.count == 2)
        #expect(video.parameterSets.map { VideoDepacketizer.nalType($0, codec: .h264) } == [7, 8])
        let audio = try #require(sdp.audio)
        #expect(audio.codec == .aac)
        #expect(audio.clockRate == 16000)
        #expect(audio.channels == 1)
        #expect(audio.audioSpecificConfig == Data([0x14, 0x08]))
        #expect(audio.sizeLength == 13)
        #expect(audio.indexLength == 3)

        let hevc = SDP.parse("""
            m=video 0 RTP/AVP 98
            a=rtpmap:98 H265/90000
            a=fmtp:98 sprop-vps=QAEMAf//AWAAAAMAkAAAAwAAAwBdlZgJ; sprop-sps=QgEBAWAAAAMAkAAAAwAAAwBdoAKAgC0WWVmkkyvAQEAAAAMAQAAABkI=; sprop-pps=RAHBcrRiQA==
            a=control:trackID=0
            m=audio 0 RTP/AVP 8
            a=control:trackID=1
            """)
        #expect(hevc.video?.codec == .h265)
        #expect(hevc.video?.parameterSets.map { VideoDepacketizer.nalType($0, codec: .h265) } == [32, 33, 34])
        // A static payload type without rtpmap: G.711 A-law at 8 kHz
        #expect(hevc.audio?.codec == .pcma)
        #expect(hevc.audio?.clockRate == 8000)
        #expect(SDP.parse("m=video 0 RTP/AVP 26\na=rtpmap:26 JPEG/90000").video == nil)
        #expect(SDP.parse("garbage").media.isEmpty)
    }

    @Test func rtpPacketsWithCSRCsExtensionsAndPadding() throws {
        let packet = RTPPacket(marker: true, payloadType: 96, sequence: 65535, timestamp: 3_000_000_000, ssrc: 0x01020304, payload: Data([1, 2, 3]))
        #expect(RTPPacket.parse(packet.serialized()) == packet)
        // One CSRC, a one-word extension, two bytes of padding
        var bytes: [UInt8] = [0xB1, 0x60, 0, 1, 0, 0, 0, 2, 0, 0, 0, 3]
        bytes += [9, 9, 9, 9] + [0xBE, 0xDE, 0, 1, 7, 7, 7, 7] + [0x41, 0x42] + [0, 2]
        let parsed = try #require(RTPPacket.parse(Data(bytes)))
        #expect(parsed.payload == Data([0x41, 0x42]))
        #expect(parsed.payloadType == 96)
        #expect(!parsed.marker)
        #expect(RTPPacket.parse(Data([0x40] + [UInt8](repeating: 0, count: 11))) == nil)
        #expect(RTPPacket.parse(Data([0x80, 0])) == nil)
    }

    func packet(_ sequence: UInt16, _ timestamp: UInt32, _ payload: [UInt8], marker: Bool = false) -> RTPPacket {
        RTPPacket(marker: marker, payloadType: 96, sequence: sequence, timestamp: timestamp, ssrc: 1, payload: Data(payload))
    }

    @Test func h264SingleNALUnitsAggregatesAndFragmentsMakeAccessUnits() {
        var depacketizer = VideoDepacketizer(codec: .h264)
        // STAP-A with SPS and PPS, then an IDR in three FU-A fragments, the marker on the last
        #expect(depacketizer.push(packet(1, 100, [24, 0, 2, 0x67, 0xAA, 0, 2, 0x68, 0xBB])).isEmpty)
        #expect(depacketizer.push(packet(2, 100, [0x7C, 0x85, 1, 2])).isEmpty)
        #expect(depacketizer.push(packet(3, 100, [0x7C, 0x05, 3])).isEmpty)
        let units = depacketizer.push(packet(4, 100, [0x7C, 0x45, 4], marker: true))
        #expect(units == [AccessUnit(nalUnits: [Data([0x67, 0xAA]), Data([0x68, 0xBB]), Data([0x65, 1, 2, 3, 4])], timestamp: 100)])
        #expect(VideoDepacketizer.isKeyFrame(units[0], codec: .h264))
        #expect(VideoDepacketizer.isParameterSet(Data([0x67]), codec: .h264))
        // A single NAL unit without a marker ends with the next timestamp
        #expect(depacketizer.push(packet(5, 200, [0x41, 9])).isEmpty)
        let next = depacketizer.push(packet(6, 300, [0x41, 8], marker: true))
        #expect(next == [AccessUnit(nalUnits: [Data([0x41, 9])], timestamp: 200), AccessUnit(nalUnits: [Data([0x41, 8])], timestamp: 300)])
        #expect(!VideoDepacketizer.isKeyFrame(next[0], codec: .h264))
    }

    @Test func aLostFragmentDropsThePicture() {
        var depacketizer = VideoDepacketizer(codec: .h264)
        _ = depacketizer.push(packet(10, 100, [0x7C, 0x85, 1]))
        // Sequence 11 lost
        #expect(depacketizer.push(packet(12, 100, [0x7C, 0x45, 3], marker: true)).isEmpty)
        // The next picture is whole again
        #expect(depacketizer.push(packet(13, 200, [0x41, 7], marker: true)) == [AccessUnit(nalUnits: [Data([0x41, 7])], timestamp: 200)])
        // A middle fragment without its start is dropped too
        #expect(depacketizer.push(packet(14, 300, [0x7C, 0x05, 3], marker: true)).isEmpty)
    }

    @Test func h265AggregationAndFragmentationUnits() {
        var depacketizer = VideoDepacketizer(codec: .h265)
        // AP (type 48) with VPS (32) and SPS (33)
        _ = depacketizer.push(packet(1, 100, [0x60, 0x01, 0, 2, 0x40, 0x01, 0, 2, 0x42, 0x01]))
        // FU (type 49) of an IDR_W_RADL (19): start, end
        _ = depacketizer.push(packet(2, 100, [0x62, 0x01, 0x93, 0xAA]))
        let units = depacketizer.push(packet(3, 100, [0x62, 0x01, 0x53, 0xBB], marker: true))
        #expect(units == [AccessUnit(nalUnits: [Data([0x40, 0x01]), Data([0x42, 0x01]), Data([0x26, 0x01, 0xAA, 0xBB])], timestamp: 100)])
        #expect(VideoDepacketizer.nalType(Data([0x26, 0x01]), codec: .h265) == 19)
        #expect(VideoDepacketizer.isKeyFrame(units[0], codec: .h265))
        #expect(VideoDepacketizer.isParameterSet(Data([0x40, 0x01]), codec: .h265))
    }

    @Test func aacAUHeadersAndG711() {
        // Two AUs of 3 and 2 bytes: AU-headers-length 32 bits, each 13-bit size + 3-bit index
        let payload: [UInt8] = [0x00, 0x20, 0x00, 0x18, 0x00, 0x10, 1, 2, 3, 4, 5]
        #expect(AACDepacketizer.frames(Data(payload)) == [Data([1, 2, 3]), Data([4, 5])])
        #expect(AACDepacketizer.frames(Data([0x00])).isEmpty)
        // G.711 (ITU-T tables): silence and the extremes
        #expect(G711.decodeMuLaw(0xFF) == 0)
        #expect(G711.decodeMuLaw(0x7F) == 0)
        #expect(G711.decodeMuLaw(0x00) == -32124)
        #expect(G711.decodeMuLaw(0x80) == 32124)
        #expect(G711.decodeALaw(0xD5) == 8)
        #expect(G711.decodeALaw(0x55) == -8)
        #expect(G711.decodeALaw(0xAA) == 32256)
        #expect(G711.decode(Data([0xFF, 0xD5]), codec: .pcma) == [G711.decodeALaw(0xFF), 8])
    }
}

/// The RTSP session's exchange with a scripted camera: DESCRIBE with a Digest challenge, SETUP of both tracks on their
/// channels, PLAY, media, keep-alive, TEARDOWN, and its failures
@Suite("RTSP session", .serialized)
struct RTSPSessionTests {
    /// The camera's side of the byte stream: records requests, the test answers them
    final class ScriptedStream: RTSPByteStream, @unchecked Sendable {
        private let lock = NSLock()
        private var queue: DispatchQueue?
        private var onData: (@Sendable (Data) -> Void)?
        private var onClose: (@Sendable (Bool) -> Void)?
        private var sentRequests: [String] = []
        private var cancelled = false
        var refuseConnection = false

        func start(queue: DispatchQueue, onReady: @escaping @Sendable () -> Void, onData: @escaping @Sendable (Data) -> Void, onClose: @escaping @Sendable (Bool) -> Void) {
            lock.withLock {
                self.queue = queue
                self.onData = onData
                self.onClose = onClose
            }
            let refuse = refuseConnection
            queue.async { refuse ? onClose(true) : onReady() }
        }

        func send(_ data: Data) { lock.withLock { sentRequests.append(String(decoding: data, as: UTF8.self)) } }
        func cancel() { lock.withLock { cancelled = true } }

        var requests: [String] { lock.withLock { sentRequests } }
        var isCancelled: Bool { lock.withLock { cancelled } }

        /// The camera answers (on the session's queue)
        func deliver(_ text: String) { deliver(Data(text.utf8)) }

        func deliver(_ data: Data) {
            let (queue, onData) = lock.withLock { (self.queue, self.onData) }
            queue?.async { onData?(data) }
        }

        func waitForRequest(_ count: Int) async throws {
            try await waitUntil("request \(count)") { self.requests.count >= count }
        }

        func cseq(_ index: Int) -> String {
            requests[index].components(separatedBy: "\r\n").first { $0.hasPrefix("CSeq: ") }.map { String($0.dropFirst(6)) } ?? "?"
        }
    }

    final class Events: @unchecked Sendable {
        private let lock = NSLock()
        private var items: [String] = []
        func add(_ item: String) { lock.withLock { items.append(item) } }
        var all: [String] { lock.withLock { items } }
    }

    func session(_ stream: ScriptedStream, url: String = "rtsp://admin:s3cret@127.0.0.1:554/cam/realmonitor?channel=1&subtype=0", mediaTimeout: TimeInterval = 10)
        -> (RTSPSession, Events) {
        let events = Events()
        // A setup deadline far beyond the waits below: during a full parallel test run on the CI Mac a 5 s deadline fired
        // before the scripted camera had answered (no test here waits for the setup timeout)
        let session = RTSPSession(url: url, setupTimeout: 60, mediaTimeout: mediaTimeout, connect: { host, port in
            events.add("connect \(host):\(port)")
            return stream
        })
        session.onPlaying = { events.add("playing") }
        session.onFailure = { events.add("failed \($0)") }
        session.onVideo = { events.add("video \($0.sequence)") }
        session.onAudio = { events.add("audio \($0.sequence)") }
        return (session, events)
    }

    @Test func describeAnswersTheDigestChallengeThenSetsUpBothTracksAndPlays() async throws {
        let stream = ScriptedStream()
        let (session, events) = session(stream)
        session.start()
        try await stream.waitForRequest(1)
        #expect(events.all == ["connect 127.0.0.1:554"])
        // OPTIONS without credentials in the request line
        #expect(stream.requests[0].hasPrefix("OPTIONS rtsp://127.0.0.1:554/cam/realmonitor?channel=1&subtype=0 RTSP/1.0\r\nCSeq: 1\r\n"))
        #expect(!stream.requests.joined().contains("s3cret"))
        stream.deliver("RTSP/1.0 200 OK\r\nCSeq: 1\r\nPublic: OPTIONS, DESCRIBE, SETUP, PLAY, TEARDOWN, GET_PARAMETER\r\n\r\n")
        try await stream.waitForRequest(2)
        #expect(stream.requests[1].hasPrefix("DESCRIBE rtsp://127.0.0.1:554/cam/realmonitor?channel=1&subtype=0 RTSP/1.0\r\nCSeq: 2\r\n"))
        #expect(stream.requests[1].contains("Accept: application/sdp\r\n"))
        stream.deliver("RTSP/1.0 401 Unauthorized\r\nCSeq: 2\r\nWWW-Authenticate: Digest realm=\"Login to AMC0000\", nonce=\"abc\", qop=\"auth\"\r\n\r\n")
        try await stream.waitForRequest(3)
        let describe = stream.requests[2]
        #expect(describe.hasPrefix("DESCRIBE "))
        let authorization = try #require(describe.components(separatedBy: "\r\n").first { $0.hasPrefix("Authorization: ") }?.dropFirst("Authorization: ".count))
        #expect(authorization.hasPrefix(#"Digest username="admin", realm="Login to AMC0000", nonce="abc", uri="rtsp://127.0.0.1:554/cam/realmonitor?channel=1&subtype=0""#))
        let params = HTTPDigest.parameters(String(authorization.dropFirst("Digest".count)))
        let ha1 = HTTPDigest.md5("admin:Login to AMC0000:s3cret")
        let ha2 = HTTPDigest.md5("DESCRIBE:rtsp://127.0.0.1:554/cam/realmonitor?channel=1&subtype=0")
        #expect(params["response"] == HTTPDigest.md5("\(ha1):abc:\(params["nc"] ?? ""):\(params["cnonce"] ?? ""):auth:\(ha2)"))
        let sdp = RTSPProtocolTests.amcrestSDP
        stream.deliver("RTSP/1.0 200 OK\r\nCSeq: \(stream.cseq(2))\r\nContent-Base: rtsp://127.0.0.1:554/cam/realmonitor/\r\nContent-Type: application/sdp\r\nContent-Length: \(sdp.utf8.count)\r\n\r\n\(sdp)")
        try await stream.waitForRequest(4)
        #expect(stream.requests[3].hasPrefix("SETUP rtsp://127.0.0.1:554/cam/realmonitor/trackID=0 RTSP/1.0\r\n"))
        #expect(stream.requests[3].contains("Transport: RTP/AVP/TCP;unicast;interleaved=0-1\r\n"))
        #expect(stream.requests[3].contains("Authorization: Digest "))
        stream.deliver("RTSP/1.0 200 OK\r\nCSeq: \(stream.cseq(3))\r\nSession: 87654321;timeout=10\r\nTransport: RTP/AVP/TCP;unicast;interleaved=0-1\r\n\r\n")
        try await stream.waitForRequest(5)
        #expect(stream.requests[4].hasPrefix("SETUP rtsp://127.0.0.1:554/cam/realmonitor/trackID=1 RTSP/1.0\r\n"))
        #expect(stream.requests[4].contains("Transport: RTP/AVP/TCP;unicast;interleaved=2-3\r\n"))
        #expect(stream.requests[4].contains("Session: 87654321\r\n"))
        stream.deliver("RTSP/1.0 200 OK\r\nCSeq: \(stream.cseq(4))\r\nSession: 87654321\r\nTransport: RTP/AVP/TCP;unicast;interleaved=2-3\r\n\r\n")
        try await stream.waitForRequest(6)
        #expect(stream.requests[5].hasPrefix("PLAY rtsp://127.0.0.1:554/cam/realmonitor/ RTSP/1.0\r\n"))
        #expect(stream.requests[5].contains("Range: npt=0.000-\r\n"))
        stream.deliver("RTSP/1.0 200 OK\r\nCSeq: \(stream.cseq(5))\r\nSession: 87654321\r\n\r\n")
        try await waitUntil("playing") { events.all.contains("playing") }
        // Media on the channels the SETUPs chose; RTCP (odd channels) and unknown channels are ignored
        let video = RTPPacket(marker: true, payloadType: 96, sequence: 7, timestamp: 1, ssrc: 1, payload: Data([0x41, 1])).serialized()
        let audio = RTPPacket(marker: true, payloadType: 97, sequence: 9, timestamp: 1, ssrc: 2, payload: Data([0, 16, 0, 8, 1])).serialized()
        var media = Data([0x24, 0, 0, UInt8(video.count)]) + video
        media += Data([0x24, 1, 0, 2, 0x80, 0xC8]) + Data([0x24, 2, 0, UInt8(audio.count)]) + audio + Data([0x24, 6, 0, 1, 0])
        stream.deliver(media)
        try await waitUntil("media") { events.all.contains("audio 9") }
        #expect(events.all == ["connect 127.0.0.1:554", "playing", "video 7", "audio 9"])
        // Keep-alive at half the session timeout (5 s for timeout=10), with GET_PARAMETER as the camera lists it
        try await waitUntil("keep-alive", timeout: .seconds(20)) { stream.requests.count >= 7 }
        #expect(stream.requests[6].hasPrefix("GET_PARAMETER rtsp://127.0.0.1:554/cam/realmonitor/ RTSP/1.0\r\n"))
        #expect(stream.requests[6].contains("Session: 87654321\r\n"))
        session.close()
        try await waitUntil("teardown") { stream.requests.last?.hasPrefix("TEARDOWN ") == true && stream.isCancelled }
        #expect(!events.all.contains { $0.hasPrefix("failed") })
    }

    @Test func refusedCredentialsNoAnswerAnErrorStatusOrNoMediaFail() async throws {
        // Refused twice: unauthorized
        let refused = ScriptedStream()
        let (first, firstEvents) = session(refused)
        first.start()
        try await refused.waitForRequest(1)
        refused.deliver("RTSP/1.0 401 Unauthorized\r\nCSeq: 1\r\nWWW-Authenticate: Basic realm=\"cam\"\r\n\r\n")
        try await refused.waitForRequest(2)
        #expect(refused.requests[1].contains("Authorization: Basic YWRtaW46czNjcmV0\r\n"))
        refused.deliver("RTSP/1.0 401 Unauthorized\r\nCSeq: 2\r\nWWW-Authenticate: Basic realm=\"cam\"\r\n\r\n")
        try await waitUntil("unauthorized") { firstEvents.all.contains("failed unauthorized") }

        // A URL without credentials cannot answer a challenge
        let anonymous = ScriptedStream()
        let (second, secondEvents) = session(anonymous, url: "rtsp://127.0.0.1/live")
        second.start()
        try await anonymous.waitForRequest(1)
        anonymous.deliver("RTSP/1.0 401 Unauthorized\r\nCSeq: 1\r\nWWW-Authenticate: Digest realm=\"r\", nonce=\"n\"\r\n\r\n")
        try await waitUntil("anonymous refused") { secondEvents.all.contains("failed unauthorized") }

        // Nobody there: unreachable
        let nobody = ScriptedStream()
        nobody.refuseConnection = true
        let (third, thirdEvents) = session(nobody)
        third.start()
        try await waitUntil("unreachable") { thirdEvents.all.contains("failed unreachable") }

        // DESCRIBE refused for another reason: other; the camera closing after playing: other
        let missing = ScriptedStream()
        let (fourth, fourthEvents) = session(missing)
        fourth.start()
        try await missing.waitForRequest(1)
        missing.deliver("RTSP/1.0 200 OK\r\nCSeq: 1\r\n\r\n")
        try await missing.waitForRequest(2)
        missing.deliver("RTSP/1.0 404 Stream Not Found\r\nCSeq: 2\r\n\r\n")
        try await waitUntil("other") { fourthEvents.all.contains("failed other") }

        // Playing, then no media for the media timeout
        let silent = ScriptedStream()
        let (fifth, fifthEvents) = session(silent, mediaTimeout: 1)
        fifth.start()
        try await silent.waitForRequest(1)
        silent.deliver("RTSP/1.0 200 OK\r\nCSeq: 1\r\n\r\n")
        try await silent.waitForRequest(2)
        let sdp = "m=video 0 RTP/AVP 96\r\na=rtpmap:96 H264/90000\r\na=control:track1\r\n"
        silent.deliver("RTSP/1.0 200 OK\r\nCSeq: 2\r\nContent-Length: \(sdp.utf8.count)\r\n\r\n\(sdp)")
        try await silent.waitForRequest(3)
        #expect(silent.requests[2].hasPrefix("SETUP rtsp://127.0.0.1:554/cam/realmonitor?channel=1&subtype=0/track1 RTSP/1.0"))
        silent.deliver("RTSP/1.0 200 OK\r\nCSeq: 3\r\nSession: s1\r\n\r\n")
        try await silent.waitForRequest(4)
        silent.deliver("RTSP/1.0 200 OK\r\nCSeq: 4\r\n\r\n")
        try await waitUntil("playing") { fifthEvents.all.contains("playing") }
        try await waitUntil("no media", timeout: .seconds(15)) { fifthEvents.all.contains("failed other") }
        // No second failure, nothing after it
        try await Task.sleep(for: .milliseconds(300))
        #expect(fifthEvents.all.filter { $0.hasPrefix("failed") }.count == 1)

        // No supported codec
        let mjpeg = ScriptedStream()
        let (sixth, sixthEvents) = session(mjpeg)
        sixth.start()
        try await mjpeg.waitForRequest(1)
        mjpeg.deliver("RTSP/1.0 200 OK\r\nCSeq: 1\r\n\r\n")
        try await mjpeg.waitForRequest(2)
        let jpeg = "m=video 0 RTP/AVP 26\r\n"
        mjpeg.deliver("RTSP/1.0 200 OK\r\nCSeq: 2\r\nContent-Length: \(jpeg.utf8.count)\r\n\r\n\(jpeg)")
        try await waitUntil("unsupported") { sixthEvents.all.contains("failed other") }
    }
}
