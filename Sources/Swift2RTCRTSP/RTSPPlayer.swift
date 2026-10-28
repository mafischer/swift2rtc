import CoreImage
import CoreVideo
import Foundation
import ImageIO
import QuartzCore

/// What an RTSP player reports (on the main actor)
public enum RTSPEvent: Equatable, Sendable {
    /// The first picture is decoded (or, without video, the sound plays)
    case playing
    /// The stream ended; nothing follows
    case failed(RTSPFailure)
}

/// An RTSP player as an app's views use it. `isAudioMuted` is the user's speaker switch, `isAudioPaused` the app pausing
/// sound (background, interruptions); neither stops the stream.
@MainActor
public protocol RTSPPlaying: AnyObject {
    var isAudioMuted: Bool { get set }
    var isAudioPaused: Bool { get set }
    var onEvent: ((RTSPEvent) -> Void)? { get set }
    /// A JPEG of the last picture that was not black (at most 640 px wide, quality 0.7), or nil
    func stillJPEG() -> Data?
    /// TEARDOWN and stop; no event afterwards
    func close()
}

/// Plays a camera's RTSP stream: `RTSPSession` (TCP interleaved, Digest/Basic), the H.264/H.265 depacketizer and the
/// VideoToolbox decoder, whose pictures go to `onFrame` (NV12 `CVPixelBuffer`s: hand them to a Metal view, a sample
/// buffer display layer or a WebRTC video source), and `AudioPlayback` for G.711 and AAC. It starts at once.
///
/// Why not AVPlayer: it does not play RTSP; why not VLCKit/FFmpeg: LGPL/GPL code, and a large dependency for what one
/// camera protocol needs.
@MainActor
public final class RTSPPlayer: RTSPPlaying {
    public var onEvent: ((RTSPEvent) -> Void)?
    public var isAudioMuted = false {
        didSet { pipeline.setAudioMuted(isAudioMuted || isAudioPaused) }
    }

    public var isAudioPaused = false {
        didSet { pipeline.setAudioMuted(isAudioMuted || isAudioPaused) }
    }

    private let session: RTSPSession
    private let pipeline: RTSPPipeline
    private let logger: any Swift2RTCLogger
    private var closed = false

    /// - Parameters:
    ///   - url: the stream, with the camera's login as user info (memory only; never logged or sent in a request line)
    ///   - userAgent: the RTSP `User-Agent`
    ///   - logger: where failures are logged (kinds only)
    ///   - onFrame: each decoded picture, on VideoToolbox's thread
    public init(url: String, userAgent: String = RTSPRequest.defaultUserAgent, logger: any Swift2RTCLogger = NoopLogger(),
                onFrame: @escaping @Sendable (CVPixelBuffer) -> Void) {
        self.logger = logger
        session = RTSPSession(url: url, userAgent: userAgent, logger: logger)
        pipeline = RTSPPipeline(session: session, logger: logger, onFrame: onFrame)
        pipeline.onPlaying = { [weak self] in
            DispatchQueue.main.async { MainActor.assumeIsolated { self?.report(.playing) } }
        }
        session.onFailure = { [weak self] failure in
            logger.log(.info, "RTSP stream failed: \(failure)")
            DispatchQueue.main.async { MainActor.assumeIsolated { self?.report(.failed(failure)) } }
        }
        session.start()
    }

    public func stillJPEG() -> Data? { pipeline.still.value }

    private func report(_ event: RTSPEvent) {
        guard !closed else { return }
        onEvent?(event)
    }

    public func close() {
        guard !closed else { return }
        closed = true
        onEvent = nil
        session.close()
        pipeline.stop()
    }
}

/// The session's packets through depacketizer and decoders, on the session's queue
final class RTSPPipeline: @unchecked Sendable {
    var onPlaying: (@Sendable () -> Void)?
    private let session: RTSPSession
    private let onFrame: @Sendable (CVPixelBuffer) -> Void
    private let logger: any Swift2RTCLogger
    private var depacketizer: VideoDepacketizer?
    private var decoder: VideoDecoder?
    private var audio: AudioPlayback?
    private let reported = Flag()
    private let muted = LockedValue(false)
    /// The last non-black picture as a JPEG, taken every `stillInterval` while pictures come
    let still = LockedValue<Data?>(nil)
    private let lastStill = LockedValue(Date.distantPast)
    static let stillInterval: TimeInterval = 2

    init(session: RTSPSession, logger: any Swift2RTCLogger, onFrame: @escaping @Sendable (CVPixelBuffer) -> Void) {
        self.session = session
        self.logger = logger
        self.onFrame = onFrame
        session.onVideo = { [weak self] packet in self?.video(packet) }
        session.onAudio = { [weak self] packet in self?.sound(packet) }
    }

    func setAudioMuted(_ muted: Bool) {
        self.muted.value = muted
        session.queue.async { [weak self] in self?.audio?.isMuted = muted }
    }

    func stop() {
        session.queue.async { [weak self] in
            self?.audio?.stop()
            self?.audio = nil
            self?.decoder = nil
        }
    }

    private func video(_ packet: RTPPacket) {
        guard let track = session.video else { return }
        if depacketizer == nil {
            depacketizer = VideoDepacketizer(codec: track.codec)
            let onFrame = onFrame
            let reported = reported
            let lastStill = lastStill
            let still = still
            let onPlaying = onPlaying
            decoder = VideoDecoder(codec: track.codec, parameterSets: track.parameterSets, logger: logger) { image in
                onFrame(image)
                if Date().timeIntervalSince(lastStill.value) >= RTSPPipeline.stillInterval {
                    lastStill.value = Date()
                    nonisolated(unsafe) let image = image
                    DispatchQueue.global(qos: .utility).async {
                        if let jpeg = StillImage.jpeg(image) { still.value = jpeg }
                    }
                }
                if !reported.isSet {
                    reported.set()
                    onPlaying?()
                }
            }
        }
        guard let units = depacketizer?.push(packet) else { return }
        for unit in units { decoder?.decode(unit) }
    }

    private func sound(_ packet: RTPPacket) {
        guard let track = session.audio else { return }
        if audio == nil {
            audio = AudioPlayback(media: track)
            audio?.isMuted = muted.value
        }
        audio?.play(packet, sizeLength: track.sizeLength, indexLength: track.indexLength)
        // A camera without video plays once its sound does
        if session.video == nil, !reported.isSet {
            reported.set()
            onPlaying?()
        }
    }
}

/// Stills of a stream (thumbnails): never a black (or not yet drawn) picture, at most 640 px wide, JPEG quality 0.7
public enum StillImage {
    /// The widest still
    public static let maxWidth: CGFloat = 640

    /// The picture as a JPEG, or nil when it is (nearly) black
    public static func jpeg(_ buffer: CVPixelBuffer) -> Data? {
        guard !isBlack(buffer) else { return nil }
        var image = CIImage(cvPixelBuffer: buffer)
        let scale = min(1, maxWidth / max(image.extent.width, 1))
        image = image.transformed(by: CGAffineTransform(scaleX: scale, y: scale))
        return CIContext().jpegRepresentation(of: image, colorSpace: CGColorSpaceCreateDeviceRGB(),
                                              options: [kCGImageDestinationLossyCompressionQuality as CIImageRepresentationOption: 0.7])
    }

    /// The luma plane's samples (a grid of at most 32 x 32) are all near black
    public static func isBlack(_ buffer: CVPixelBuffer) -> Bool {
        guard CVPixelBufferIsPlanar(buffer) else { return false }
        CVPixelBufferLockBaseAddress(buffer, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(buffer, .readOnly) }
        guard let base = CVPixelBufferGetBaseAddressOfPlane(buffer, 0)?.assumingMemoryBound(to: UInt8.self) else { return false }
        let width = CVPixelBufferGetWidthOfPlane(buffer, 0)
        let height = CVPixelBufferGetHeightOfPlane(buffer, 0)
        let stride = CVPixelBufferGetBytesPerRowOfPlane(buffer, 0)
        guard width > 0, height > 0 else { return true }
        var brightest: UInt8 = 0
        for row in 0..<32 {
            let y = row * height / 32
            for column in 0..<32 { brightest = max(brightest, base[y * stride + column * width / 32]) }
        }
        // Video range: 16 is black
        return brightest < 32
    }
}
