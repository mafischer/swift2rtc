import AVFoundation
import CoreMedia
import Foundation
import VideoToolbox

/// H.264 / H.265 access units to pixel buffers with VideoToolbox (the hardware decoder): the parameter sets from the SDP
/// and from the stream make the format; decoding starts at a key frame, and again at the next one after an error (iOS
/// invalidates hardware sessions when the app is suspended). Frames come out as NV12 (`pixelFormat`) IOSurface buffers,
/// Metal-compatible, which Metal views, WebRTC video sources and sample-buffer display layers all take.
///
/// Not thread-safe: call `decode` from one queue (the RTSP session's). `onFrame` runs on VideoToolbox's thread.
public final class VideoDecoder: @unchecked Sendable {
    /// The pixel format of the decoded frames: 4:2:0 bi-planar, video range (NV12)
    public static let pixelFormat = kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange

    private let codec: RTSPCodec
    private let onFrame: @Sendable (CVPixelBuffer) -> Void
    private let logger: any Swift2RTCLogger
    private var parameterSets: [Int: Data] = [:]
    private var format: CMVideoFormatDescription?
    private var session: VTDecompressionSession?
    private var waitingForKeyFrame = true

    /// - Parameters:
    ///   - codec: `.h264` or `.h265`
    ///   - parameterSets: from the SDP (`SDPMedia.parameterSets`); the stream's own replace them
    ///   - logger: where a decoder that cannot be created is reported
    ///   - onFrame: each decoded picture
    public init(codec: RTSPCodec, parameterSets: [Data], logger: any Swift2RTCLogger = NoopLogger(), onFrame: @escaping @Sendable (CVPixelBuffer) -> Void) {
        self.codec = codec
        self.onFrame = onFrame
        self.logger = logger
        for nal in parameterSets { remember(nal) }
    }

    deinit {
        if let session { VTDecompressionSessionInvalidate(session) }
    }

    /// Decodes one picture (asynchronously); parameter sets in it update the format
    public func decode(_ unit: AccessUnit) {
        var changed = false
        for nal in unit.nalUnits where VideoDepacketizer.isParameterSet(nal, codec: codec) { changed = remember(nal) || changed }
        if changed || format == nil { rebuildFormat() }
        guard let format else { return }
        let keyFrame = VideoDepacketizer.isKeyFrame(unit, codec: codec)
        if waitingForKeyFrame {
            guard keyFrame else { return }
            waitingForKeyFrame = false
        }
        if session == nil, !makeSession(format) { return }
        let pictureNALs = unit.nalUnits.filter { !VideoDepacketizer.isParameterSet($0, codec: codec) }
        guard !pictureNALs.isEmpty, let sample = Self.sampleBuffer(pictureNALs, format: format), let session else { return }
        let onFrame = onFrame
        let status = VTDecompressionSessionDecodeFrame(session, sampleBuffer: sample, flags: [._EnableAsynchronousDecompression], infoFlagsOut: nil) { status, _, image, _, _ in
            guard status == noErr, let image else { return }
            onFrame(image)
        }
        if status != noErr {
            // kVTInvalidSessionErr after the app was suspended, or a broken picture: a new session from the next key frame
            VTDecompressionSessionInvalidate(session)
            self.session = nil
            waitingForKeyFrame = true
        }
    }

    /// True when the set changed
    @discardableResult
    private func remember(_ nal: Data) -> Bool {
        let type = VideoDepacketizer.nalType(nal, codec: codec)
        guard parameterSets[type] != nal else { return false }
        parameterSets[type] = nal
        return true
    }

    private func rebuildFormat() {
        let order = codec == .h265 ? [32, 33, 34] : [7, 8]
        let sets = order.compactMap { parameterSets[$0] }
        guard sets.count == order.count else { return }
        var description: CMFormatDescription?
        let status: OSStatus = sets.withPointers { pointers, sizes in
            if codec == .h265 {
                CMVideoFormatDescriptionCreateFromHEVCParameterSets(allocator: kCFAllocatorDefault, parameterSetCount: sets.count, parameterSetPointers: pointers,
                                                                    parameterSetSizes: sizes, nalUnitHeaderLength: 4, extensions: nil, formatDescriptionOut: &description)
            } else {
                CMVideoFormatDescriptionCreateFromH264ParameterSets(allocator: kCFAllocatorDefault, parameterSetCount: sets.count, parameterSetPointers: pointers,
                                                                    parameterSetSizes: sizes, nalUnitHeaderLength: 4, formatDescriptionOut: &description)
            }
        }
        guard status == noErr, let description else { return }
        if let old = format, CMFormatDescriptionEqual(old, otherFormatDescription: description) { return }
        format = description
        if let session { VTDecompressionSessionInvalidate(session) }
        session = nil
        waitingForKeyFrame = true
    }

    private func makeSession(_ format: CMVideoFormatDescription) -> Bool {
        let attributes: [CFString: Any] = [kCVPixelBufferPixelFormatTypeKey: Self.pixelFormat, kCVPixelBufferIOSurfacePropertiesKey: [:] as CFDictionary,
                                           kCVPixelBufferMetalCompatibilityKey: true]
        var created: VTDecompressionSession?
        let status = VTDecompressionSessionCreate(allocator: kCFAllocatorDefault, formatDescription: format, decoderSpecification: nil,
                                                  imageBufferAttributes: attributes as CFDictionary, outputCallback: nil, decompressionSessionOut: &created)
        guard status == noErr, let created else {
            logger.log(.error, "RTSP: decoder not created (\(status))")
            return false
        }
        VTSessionSetProperty(created, key: kVTDecompressionPropertyKey_RealTime, value: kCFBooleanTrue)
        session = created
        return true
    }

    /// The picture's NAL units with 4-byte lengths (AVCC / HVCC) in a sample buffer that displays at once
    static func sampleBuffer(_ nalUnits: [Data], format: CMVideoFormatDescription) -> CMSampleBuffer? {
        var data = Data()
        for nal in nalUnits {
            var length = UInt32(nal.count).bigEndian
            data.append(Data(bytes: &length, count: 4))
            data.append(nal)
        }
        var block: CMBlockBuffer?
        guard CMBlockBufferCreateWithMemoryBlock(allocator: kCFAllocatorDefault, memoryBlock: nil, blockLength: data.count, blockAllocator: kCFAllocatorDefault,
                                                 customBlockSource: nil, offsetToData: 0, dataLength: data.count, flags: kCMBlockBufferAssureMemoryNowFlag,
                                                 blockBufferOut: &block) == noErr, let block else { return nil }
        let copied = data.withUnsafeBytes { CMBlockBufferReplaceDataBytes(with: $0.baseAddress!, blockBuffer: block, offsetIntoDestination: 0, dataLength: data.count) }
        guard copied == noErr else { return nil }
        var sample: CMSampleBuffer?
        var size = data.count
        guard CMSampleBufferCreateReady(allocator: kCFAllocatorDefault, dataBuffer: block, formatDescription: format, sampleCount: 1, sampleTimingEntryCount: 0,
                                        sampleTimingArray: nil, sampleSizeEntryCount: 1, sampleSizeArray: &size, sampleBufferOut: &sample) == noErr else { return nil }
        return sample
    }
}

private extension Array where Element == Data {
    /// The raw pointers and sizes of every element, valid inside `body`
    func withPointers<R>(_ body: (UnsafePointer<UnsafePointer<UInt8>>, UnsafePointer<Int>) -> R) -> R {
        let copies = map { data -> UnsafeMutablePointer<UInt8> in
            let pointer = UnsafeMutablePointer<UInt8>.allocate(capacity: Swift.max(1, data.count))
            data.copyBytes(to: pointer, count: data.count)
            return pointer
        }
        defer { copies.forEach { $0.deallocate() } }
        let pointers = copies.map { UnsafePointer($0) }
        let sizes = map(\.count)
        return pointers.withUnsafeBufferPointer { p in sizes.withUnsafeBufferPointer { s in body(p.baseAddress!, s.baseAddress!) } }
    }
}

/// A camera's sound: G.711 decoded here, AAC through AVAudioConverter, played by an AVAudioEngine of its own (on iOS in
/// the app's current audio session: configure it, e.g. playback or play-and-record, before playing). Muting sets the
/// volume to 0, the stream keeps running. At most half a second is queued: a late packet is dropped rather than delaying
/// the live sound.
///
/// Call `play` and `stop` from one queue (the RTSP session's); `isMuted` from any thread.
public final class AudioPlayback: @unchecked Sendable {
    private let codec: RTSPCodec
    private let engine = AVAudioEngine()
    private let player = AVAudioPlayerNode()
    private let pcmFormat: AVAudioFormat
    private var converter: AVAudioConverter?
    private var compressedFormat: AVAudioFormat?
    private let lock = NSLock()
    private var queuedFrames: AVAudioFrameCount = 0
    private var volume: Float = 1

    /// Nil for a codec it cannot play (video, unsupported audio)
    public init?(media: SDPMedia) {
        codec = media.codec
        let rate = Double(media.clockRate > 0 ? media.clockRate : 8000)
        let channels = AVAudioChannelCount(max(1, media.channels))
        guard let format = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: rate, channels: channels, interleaved: false) else { return nil }
        pcmFormat = format
        if codec == .aac {
            var description = AudioStreamBasicDescription(mSampleRate: rate, mFormatID: kAudioFormatMPEG4AAC, mFormatFlags: 0, mBytesPerPacket: 0,
                                                          mFramesPerPacket: 1024, mBytesPerFrame: 0, mChannelsPerFrame: channels, mBitsPerChannel: 0, mReserved: 0)
            guard let input = AVAudioFormat(streamDescription: &description), let converter = AVAudioConverter(from: input, to: format) else { return nil }
            if let config = media.audioSpecificConfig { converter.magicCookie = config }
            compressedFormat = input
            self.converter = converter
        } else if !codec.isAudio {
            return nil
        }
        engine.attach(player)
        engine.connect(player, to: engine.mainMixerNode, format: format)
    }

    /// The volume is 0 (the stream keeps running)
    public var isMuted: Bool {
        get { lock.withLock { volume == 0 } }
        set {
            lock.withLock { volume = newValue ? 0 : 1 }
            player.volume = newValue ? 0 : 1
        }
    }

    /// Decodes and schedules one RTP packet (AAC: with the SDP's AU header sizes)
    public func play(_ packet: RTPPacket, sizeLength: Int, indexLength: Int) {
        switch codec {
        case .pcmu, .pcma:
            schedule(pcm(G711.decode(packet.payload, codec: codec)))
        case .aac:
            for frame in AACDepacketizer.frames(packet.payload, sizeLength: sizeLength, indexLength: indexLength) { schedule(decodeAAC(frame)) }
        default:
            break
        }
    }

    /// Stops the engine
    public func stop() {
        player.stop()
        engine.stop()
    }

    private func pcm(_ samples: [Int16]) -> AVAudioPCMBuffer? {
        guard !samples.isEmpty, let buffer = AVAudioPCMBuffer(pcmFormat: pcmFormat, frameCapacity: AVAudioFrameCount(samples.count)),
              let channel = buffer.floatChannelData?[0] else { return nil }
        for (index, sample) in samples.enumerated() { channel[index] = Float(sample) / 32768 }
        buffer.frameLength = AVAudioFrameCount(samples.count)
        return buffer
    }

    private func decodeAAC(_ frame: Data) -> AVAudioPCMBuffer? {
        guard let converter, let compressedFormat, !frame.isEmpty else { return nil }
        let input = AVAudioCompressedBuffer(format: compressedFormat, packetCapacity: 1, maximumPacketSize: frame.count)
        frame.withUnsafeBytes { input.data.copyMemory(from: $0.baseAddress!, byteCount: frame.count) }
        input.byteLength = UInt32(frame.count)
        input.packetCount = 1
        input.packetDescriptions?.pointee = AudioStreamPacketDescription(mStartOffset: 0, mVariableFramesInPacket: 0, mDataByteSize: UInt32(frame.count))
        guard let output = AVAudioPCMBuffer(pcmFormat: pcmFormat, frameCapacity: 2048) else { return nil }
        let delivered = Flag()
        var error: NSError?
        converter.convert(to: output, error: &error) { _, status in
            if delivered.isSet {
                status.pointee = .noDataNow
                return nil
            }
            delivered.set()
            status.pointee = .haveData
            return input
        }
        return error == nil && output.frameLength > 0 ? output : nil
    }

    private func schedule(_ buffer: AVAudioPCMBuffer?) {
        guard let buffer else { return }
        if !engine.isRunning {
            // First packet, or the engine stopped (an audio interruption): (re)start it
            do {
                try engine.start()
            } catch {
                return
            }
            player.volume = lock.withLock { volume }
        }
        if !player.isPlaying { player.play() }
        let limit = AVAudioFrameCount(pcmFormat.sampleRate / 2)
        let queued = lock.withLock { queuedFrames }
        guard queued < limit else { return }
        lock.withLock { queuedFrames += buffer.frameLength }
        let frames = buffer.frameLength
        player.scheduleBuffer(buffer) { [weak self] in
            guard let self else { return }
            lock.withLock { queuedFrames -= min(queuedFrames, frames) }
        }
    }
}
