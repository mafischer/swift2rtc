import AVFoundation
import CoreVideo
import ImageIO
import Network
import VideoToolbox
import Foundation
import Testing
@testable import Swift2RTCCore
@testable import Swift2RTCRTSP

/// H.264 pictures made with VideoToolbox (a test pattern), as NAL units: what a camera sends
enum H264TestStream {
    struct Encoded: Sendable {
        var sps: Data
        var pps: Data
        /// Each picture's NAL units (without parameter sets)
        var pictures: [[Data]]
    }

    final class Collector: @unchecked Sendable {
        let lock = NSLock()
        var sps = Data()
        var pps = Data()
        var pictures: [[Data]] = []
    }

    static func encode(width: Int32 = 320, height: Int32 = 240, frames: Int = 10) throws -> Encoded {
        var session: VTCompressionSession?
        let collector = Collector()
        let status = VTCompressionSessionCreate(allocator: nil, width: width, height: height, codecType: kCMVideoCodecType_H264, encoderSpecification: nil,
                                                imageBufferAttributes: nil, compressedDataAllocator: nil, outputCallback: nil, refcon: nil, compressionSessionOut: &session)
        guard status == noErr, let session else { throw URLError(.cannotDecodeContentData) }
        VTSessionSetProperty(session, key: kVTCompressionPropertyKey_RealTime, value: kCFBooleanTrue)
        VTSessionSetProperty(session, key: kVTCompressionPropertyKey_ProfileLevel, value: kVTProfileLevel_H264_Baseline_AutoLevel)
        VTSessionSetProperty(session, key: kVTCompressionPropertyKey_MaxKeyFrameInterval, value: 5 as CFNumber)
        VTSessionSetProperty(session, key: kVTCompressionPropertyKey_AllowFrameReordering, value: kCFBooleanFalse)
        for index in 0..<frames {
            var buffer: CVPixelBuffer?
            CVPixelBufferCreate(nil, Int(width), Int(height), kCVPixelFormatType_32BGRA, [kCVPixelBufferIOSurfacePropertiesKey: [:]] as CFDictionary, &buffer)
            guard let buffer else { continue }
            CVPixelBufferLockBaseAddress(buffer, [])
            let base = CVPixelBufferGetBaseAddress(buffer)!.assumingMemoryBound(to: UInt8.self)
            for offset in 0..<(CVPixelBufferGetBytesPerRow(buffer) * Int(height)) { base[offset] = UInt8((offset / 4 + index * 8) & 0xFF) }
            CVPixelBufferUnlockBaseAddress(buffer, [])
            VTCompressionSessionEncodeFrame(session, imageBuffer: buffer, presentationTimeStamp: CMTime(value: CMTimeValue(index), timescale: 15), duration: .invalid,
                                            frameProperties: nil, infoFlagsOut: nil) { status, _, sample in
                guard status == noErr, let sample, let format = CMSampleBufferGetFormatDescription(sample), let block = CMSampleBufferGetDataBuffer(sample) else { return }
                var nals: [Data] = []
                var length = 0
                var pointer: UnsafeMutablePointer<CChar>?
                CMBlockBufferGetDataPointer(block, atOffset: 0, lengthAtOffsetOut: nil, totalLengthOut: &length, dataPointerOut: &pointer)
                let bytes = Data(bytes: pointer!, count: length)
                var offset = 0
                while offset + 4 <= bytes.count {
                    let size = Int(bytes[offset]) << 24 | Int(bytes[offset + 1]) << 16 | Int(bytes[offset + 2]) << 8 | Int(bytes[offset + 3])
                    nals.append(bytes.subdata(in: (offset + 4)..<(offset + 4 + size)))
                    offset += 4 + size
                }
                var sps: UnsafePointer<UInt8>?
                var spsSize = 0
                var pps: UnsafePointer<UInt8>?
                var ppsSize = 0
                CMVideoFormatDescriptionGetH264ParameterSetAtIndex(format, parameterSetIndex: 0, parameterSetPointerOut: &sps, parameterSetSizeOut: &spsSize,
                                                                   parameterSetCountOut: nil, nalUnitHeaderLengthOut: nil)
                CMVideoFormatDescriptionGetH264ParameterSetAtIndex(format, parameterSetIndex: 1, parameterSetPointerOut: &pps, parameterSetSizeOut: &ppsSize,
                                                                   parameterSetCountOut: nil, nalUnitHeaderLengthOut: nil)
                collector.lock.withLock {
                    if let sps { collector.sps = Data(bytes: sps, count: spsSize) }
                    if let pps { collector.pps = Data(bytes: pps, count: ppsSize) }
                    collector.pictures.append(nals)
                }
            }
        }
        VTCompressionSessionCompleteFrames(session, untilPresentationTimeStamp: .invalid)
        VTCompressionSessionInvalidate(session)
        return collector.lock.withLock { Encoded(sps: collector.sps, pps: collector.pps, pictures: collector.pictures) }
    }

    /// RTP packets of one picture: single NAL units, FU-A for those above `mtu`, the marker on the last
    static func packets(_ nals: [Data], sequence: inout UInt16, timestamp: UInt32, mtu: Int = 1000) -> [RTPPacket] {
        var packets: [RTPPacket] = []
        for (nalIndex, nal) in nals.enumerated() {
            let last = nalIndex == nals.count - 1
            if nal.count <= mtu {
                packets.append(RTPPacket(marker: last, payloadType: 96, sequence: sequence, timestamp: timestamp, ssrc: 7, payload: nal))
                sequence &+= 1
                continue
            }
            let header = nal[nal.startIndex]
            var offset = 1
            while offset < nal.count {
                let end = min(offset + mtu, nal.count)
                let start = offset == 1
                let finish = end == nal.count
                let fu: [UInt8] = [(header & 0xE0) | 28, (start ? 0x80 : 0) | (finish ? 0x40 : 0) | (header & 0x1F)]
                packets.append(RTPPacket(marker: last && finish, payloadType: 96, sequence: sequence, timestamp: timestamp, ssrc: 7,
                                         payload: Data(fu) + nal.subdata(in: (nal.startIndex + offset)..<(nal.startIndex + end))))
                sequence &+= 1
                offset = end
            }
        }
        return packets
    }
}

/// An IP camera on 127.0.0.1: RTSP with Digest (user admin, password `password`), an H.264 video track (the encoded
/// test pattern, 15 pictures per second) and a G.711 µ-law audio track, interleaved in the TCP connection
final class FakeRTSPCamera: @unchecked Sendable {
    static let password = "swift2rtc-test"
    private let listener: NWListener
    private let queue = DispatchQueue(label: "fake-rtsp-camera")
    private let stream: H264TestStream.Encoded
    let port: UInt16
    private let lock = NSLock()
    private var methods: [String] = []

    var received: [String] { lock.withLock { methods } }

    private init(listener: NWListener, port: UInt16, stream: H264TestStream.Encoded) {
        self.listener = listener
        self.port = port
        self.stream = stream
    }

    static func start() async throws -> FakeRTSPCamera {
        let parameters = NWParameters.tcp
        parameters.requiredLocalEndpoint = NWEndpoint.hostPort(host: "127.0.0.1", port: .any)
        let listener = try NWListener(using: parameters)
        let stream = try H264TestStream.encode()
        let queue = DispatchQueue(label: "fake-rtsp-listener")
        let port: UInt16 = try await withCheckedThrowingContinuation { continuation in
            let once = Once()
            listener.stateUpdateHandler = { state in
                switch state {
                case .ready: once.run { continuation.resume(returning: listener.port?.rawValue ?? 0) }
                case .failed(let error): once.run { continuation.resume(throwing: error) }
                default: break
                }
            }
            listener.newConnectionHandler = { _ in }
            listener.start(queue: queue)
        }
        let camera = FakeRTSPCamera(listener: listener, port: port, stream: stream)
        listener.newConnectionHandler = { [weak camera] connection in camera?.serve(connection) }
        return camera
    }

    func stop() { listener.cancel() }

    private func serve(_ connection: NWConnection) {
        connection.start(queue: queue)
        // Only touched on the camera's queue
        nonisolated(unsafe) var buffer = Data()
        nonisolated(unsafe) var playing = false
        let nonce = "fake-nonce"
        @Sendable func reply(_ text: String) { connection.send(content: Data(text.utf8), completion: .contentProcessed { _ in }) }
        @Sendable func handle(_ request: String) {
            let lines = request.components(separatedBy: "\r\n")
            let parts = lines[0].split(separator: " ")
            let method = String(parts.first ?? "")
            let url = parts.count > 1 ? String(parts[1]) : ""
            let cseq = lines.first { $0.hasPrefix("CSeq: ") }.map { String($0.dropFirst(6)) } ?? "0"
            lock.withLock { methods.append(method) }
            if method == "OPTIONS" {
                return reply("RTSP/1.0 200 OK\r\nCSeq: \(cseq)\r\nPublic: OPTIONS, DESCRIBE, SETUP, PLAY, TEARDOWN, GET_PARAMETER\r\n\r\n")
            }
            // Digest like an Amcrest: every other request needs a valid Authorization
            let authorization = lines.first { $0.hasPrefix("Authorization: ") }.map { String($0.dropFirst("Authorization: Digest".count)) }
            let params = HTTPDigest.parameters(authorization ?? "")
            let ha1 = HTTPDigest.md5("admin:FakeCam:\(Self.password)")
            let expected = HTTPDigest.md5("\(ha1):\(nonce):\(params["nc"] ?? ""):\(params["cnonce"] ?? ""):auth:\(HTTPDigest.md5("\(method):\(params["uri"] ?? "")"))")
            guard params["username"] == "admin", params["uri"] == url, params["response"] == expected else {
                return reply("RTSP/1.0 401 Unauthorized\r\nCSeq: \(cseq)\r\nWWW-Authenticate: Digest realm=\"FakeCam\", nonce=\"\(nonce)\", qop=\"auth\"\r\n\r\n")
            }
            switch method {
            case "DESCRIBE":
                let sdp = "v=0\r\no=- 0 0 IN IP4 127.0.0.1\r\ns=Fake\r\nt=0 0\r\na=control:*\r\nm=video 0 RTP/AVP 96\r\na=rtpmap:96 H264/90000\r\n"
                    + "a=fmtp:96 packetization-mode=1;sprop-parameter-sets=\(stream.sps.base64EncodedString()),\(stream.pps.base64EncodedString())\r\na=control:trackID=0\r\n"
                    + "m=audio 0 RTP/AVP 0\r\na=rtpmap:0 PCMU/8000\r\na=control:trackID=1\r\n"
                reply("RTSP/1.0 200 OK\r\nCSeq: \(cseq)\r\nContent-Base: rtsp://127.0.0.1:\(port)/live/\r\n" +
                      "Content-Type: application/sdp\r\nContent-Length: \(sdp.utf8.count)\r\n\r\n\(sdp)")
            case "SETUP":
                let transport = lines.first { $0.hasPrefix("Transport: ") }.map { String($0.dropFirst(11)) } ?? ""
                reply("RTSP/1.0 200 OK\r\nCSeq: \(cseq)\r\nSession: 1234ABCD;timeout=60\r\nTransport: \(transport)\r\n\r\n")
            case "PLAY":
                reply("RTSP/1.0 200 OK\r\nCSeq: \(cseq)\r\nSession: 1234ABCD\r\n\r\n")
                if !playing {
                    playing = true
                    sendMedia(connection, picture: 0, sequence: 1)
                }
            default:
                reply("RTSP/1.0 200 OK\r\nCSeq: \(cseq)\r\nSession: 1234ABCD\r\n\r\n")
            }
        }
        @Sendable func read() {
            connection.receive(minimumIncompleteLength: 1, maximumLength: 65_536) { data, _, complete, error in
                if let data { buffer.append(data) }
                while let end = buffer.range(of: Data("\r\n\r\n".utf8)) {
                    handle(String(decoding: buffer[buffer.startIndex..<end.lowerBound], as: UTF8.self))
                    buffer.removeSubrange(buffer.startIndex..<end.upperBound)
                }
                if !complete, error == nil { read() }
            }
        }
        read()
    }

    /// One picture and 1/15 s of silence every 66 ms, the pictures in a loop (each loop starts at a key frame)
    private func sendMedia(_ connection: NWConnection, picture: Int, sequence: UInt16) {
        guard connection.state == .ready else { return }
        var next = sequence
        let index = picture % stream.pictures.count
        let nals = (index == 0 ? [stream.sps, stream.pps] : []) + stream.pictures[index]
        var out = Data()
        for packet in H264TestStream.packets(nals, sequence: &next, timestamp: UInt32(picture * 6000)) {
            let bytes = packet.serialized()
            out += Data([0x24, 0, UInt8(bytes.count >> 8), UInt8(bytes.count & 0xFF)]) + bytes
        }
        let audio = RTPPacket(marker: false, payloadType: 0, sequence: UInt16(picture & 0xFFFF), timestamp: UInt32(picture * 533), ssrc: 8,
                              payload: Data(repeating: 0xFF, count: 533)).serialized()
        out += Data([0x24, 2, UInt8(audio.count >> 8), UInt8(audio.count & 0xFF)]) + audio
        connection.send(content: out, completion: .contentProcessed { _ in })
        let following = next
        queue.asyncAfter(deadline: .now() + 0.066) { [weak self] in self?.sendMedia(connection, picture: picture + 1, sequence: following) }
    }
}

/// Counts the frames a player decodes, and their size
final class FrameCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var count = 0
    private var size = CGSize.zero

    var frames: Int { lock.withLock { count } }
    var lastSize: CGSize { lock.withLock { size } }

    func add(_ buffer: CVPixelBuffer) {
        lock.withLock {
            count += 1
            size = CGSize(width: CVPixelBufferGetWidth(buffer), height: CVPixelBufferGetHeight(buffer))
        }
    }
}

/// The RTSP player end to end against a camera on this machine: Digest, H.264 over TCP interleaved, decoded by
/// VideoToolbox into pixel buffers; a wrong password and a camera that is not there
@Suite("RTSP playback", .serialized)
@MainActor
struct RTSPPlaybackTests {
    @Test func theCamerasPicturesAreDecoded() async throws {
        let camera = try await FakeRTSPCamera.start()
        defer { camera.stop() }
        let counter = FrameCounter()
        let player = RTSPPlayer(url: "rtsp://admin:\(FakeRTSPCamera.password)@127.0.0.1:\(camera.port)/live") { counter.add($0) }
        var events: [RTSPEvent] = []
        player.onEvent = { events.append($0) }
        try await waitUntil("playing", timeout: .seconds(15)) { events.contains(.playing) }
        try await waitUntil("frames", timeout: .seconds(10)) { counter.frames >= 5 }
        #expect(counter.lastSize == CGSize(width: 320, height: 240))
        #expect(camera.received.prefix(6) == ["OPTIONS", "DESCRIBE", "DESCRIBE", "SETUP", "SETUP", "PLAY"])
        // Muting and pausing the sound never stops the picture
        player.isAudioMuted = true
        player.isAudioPaused = true
        let before = counter.frames
        try await waitUntil("more frames") { counter.frames > before + 3 }
        // A still of the (not black) test pattern, taken while pictures come
        try await waitUntil("still") { player.stillJPEG() != nil }
        player.close()
        try await waitUntil("teardown") { camera.received.contains("TEARDOWN") }
        #expect(!events.contains { if case .failed = $0 { true } else { false } })
    }

    @Test func aWrongPasswordIsUnauthorizedAndNobodyThereIsUnreachable() async throws {
        let camera = try await FakeRTSPCamera.start()
        defer { camera.stop() }
        let wrong = RTSPPlayer(url: "rtsp://admin:wrong@127.0.0.1:\(camera.port)/live") { _ in }
        var events: [RTSPEvent] = []
        wrong.onEvent = { events.append($0) }
        try await waitUntil("refused", timeout: .seconds(10)) { events == [.failed(.unauthorized)] }
        wrong.close()

        let port = camera.port
        camera.stop()
        try await Task.sleep(for: .milliseconds(200))
        let nobody = RTSPPlayer(url: "rtsp://admin:x@127.0.0.1:\(port)/live") { _ in }
        var nobodyEvents: [RTSPEvent] = []
        nobody.onEvent = { nobodyEvents.append($0) }
        try await waitUntil("unreachable", timeout: .seconds(15)) { nobodyEvents == [.failed(.unreachable)] }
        nobody.close()
    }

    @Test func theDecoderNeedsAKeyFrameAndTheParameterSets() async throws {
        let encoded = try H264TestStream.encode(frames: 6)
        let frames = LockedValue(0)
        let decoder = VideoDecoder(codec: .h264, parameterSets: []) { _ in frames.value += 1 }
        // A P picture first: nothing until the key frame, and nothing without SPS/PPS
        decoder.decode(AccessUnit(nalUnits: encoded.pictures[1], timestamp: 1))
        decoder.decode(AccessUnit(nalUnits: encoded.pictures[0], timestamp: 2))
        try await Task.sleep(for: .milliseconds(300))
        #expect(frames.value == 0)
        decoder.decode(AccessUnit(nalUnits: [encoded.sps, encoded.pps] + encoded.pictures[0], timestamp: 3))
        for index in 1..<encoded.pictures.count { decoder.decode(AccessUnit(nalUnits: encoded.pictures[index], timestamp: UInt32(3 + index))) }
        try await waitUntil("decoded") { frames.value >= encoded.pictures.count }
    }

    /// Never a black picture; a real one at most 640 px wide
    @Test func stillsAreNeverBlackAndAtMost640Wide() throws {
        func buffer(width: Int, height: Int, luma: UInt8) -> CVPixelBuffer {
            var buffer: CVPixelBuffer?
            CVPixelBufferCreate(nil, width, height, kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange, [kCVPixelBufferIOSurfacePropertiesKey: [:]] as CFDictionary, &buffer)
            CVPixelBufferLockBaseAddress(buffer!, [])
            memset(CVPixelBufferGetBaseAddressOfPlane(buffer!, 0), Int32(luma), CVPixelBufferGetBytesPerRowOfPlane(buffer!, 0) * height)
            memset(CVPixelBufferGetBaseAddressOfPlane(buffer!, 1), 128, CVPixelBufferGetBytesPerRowOfPlane(buffer!, 1) * height / 2)
            CVPixelBufferUnlockBaseAddress(buffer!, [])
            return buffer!
        }
        #expect(StillImage.jpeg(buffer(width: 1280, height: 720, luma: 16)) == nil)
        let jpeg = try #require(StillImage.jpeg(buffer(width: 1280, height: 720, luma: 120)))
        let source = try #require(CGImageSourceCreateWithData(jpeg as CFData, nil))
        let properties = try #require(CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any])
        #expect(properties[kCGImagePropertyPixelWidth] as? Int == 640)
    }
}
