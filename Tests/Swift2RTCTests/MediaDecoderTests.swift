import AVFoundation
import CoreMedia
import Foundation
import Testing
@testable import Swift2RTCCore
@testable import Swift2RTCRTSP

import VideoToolbox

/// H.265 pictures made with VideoToolbox, as NAL units (VPS, SPS, PPS and each picture's slices): what an H.265 camera
/// sends
enum H265TestStream {
    struct Encoded: Sendable {
        var parameterSets: [Data]
        var pictures: [[Data]]
    }

    final class Collector: @unchecked Sendable {
        let lock = NSLock()
        var parameterSets: [Data] = []
        var pictures: [[Data]] = []
    }

    static func encode(width: Int32 = 320, height: Int32 = 240, frames: Int = 6) throws -> Encoded {
        var session: VTCompressionSession?
        let collector = Collector()
        let status = VTCompressionSessionCreate(allocator: nil, width: width, height: height, codecType: kCMVideoCodecType_HEVC, encoderSpecification: nil,
                                                imageBufferAttributes: nil, compressedDataAllocator: nil, outputCallback: nil, refcon: nil, compressionSessionOut: &session)
        guard status == noErr, let session else { throw URLError(.cannotDecodeContentData) }
        VTSessionSetProperty(session, key: kVTCompressionPropertyKey_RealTime, value: kCFBooleanTrue)
        VTSessionSetProperty(session, key: kVTCompressionPropertyKey_MaxKeyFrameInterval, value: 3 as CFNumber)
        VTSessionSetProperty(session, key: kVTCompressionPropertyKey_AllowFrameReordering, value: kCFBooleanFalse)
        for index in 0..<frames {
            var buffer: CVPixelBuffer?
            CVPixelBufferCreate(nil, Int(width), Int(height), kCVPixelFormatType_32BGRA, [kCVPixelBufferIOSurfacePropertiesKey: [:]] as CFDictionary, &buffer)
            guard let buffer else { continue }
            CVPixelBufferLockBaseAddress(buffer, [])
            let base = CVPixelBufferGetBaseAddress(buffer)!.assumingMemoryBound(to: UInt8.self)
            for offset in 0..<(CVPixelBufferGetBytesPerRow(buffer) * Int(height)) { base[offset] = UInt8((offset / 4 + index * 16) & 0xFF) }
            CVPixelBufferUnlockBaseAddress(buffer, [])
            VTCompressionSessionEncodeFrame(session, imageBuffer: buffer, presentationTimeStamp: CMTime(value: CMTimeValue(index), timescale: 15), duration: .invalid,
                                            frameProperties: nil, infoFlagsOut: nil) { status, _, sample in
                guard status == noErr, let sample, let format = CMSampleBufferGetFormatDescription(sample), let block = CMSampleBufferGetDataBuffer(sample) else { return }
                var length = 0
                var pointer: UnsafeMutablePointer<CChar>?
                CMBlockBufferGetDataPointer(block, atOffset: 0, lengthAtOffsetOut: nil, totalLengthOut: &length, dataPointerOut: &pointer)
                let bytes = Data(bytes: pointer!, count: length)
                var nals: [Data] = []
                var offset = 0
                while offset + 4 <= bytes.count {
                    let size = Int(bytes[offset]) << 24 | Int(bytes[offset + 1]) << 16 | Int(bytes[offset + 2]) << 8 | Int(bytes[offset + 3])
                    nals.append(bytes.subdata(in: (offset + 4)..<(offset + 4 + size)))
                    offset += 4 + size
                }
                var count = 0
                CMVideoFormatDescriptionGetHEVCParameterSetAtIndex(format, parameterSetIndex: 0, parameterSetPointerOut: nil, parameterSetSizeOut: nil,
                                                                   parameterSetCountOut: &count, nalUnitHeaderLengthOut: nil)
                var sets: [Data] = []
                for set in 0..<count {
                    var pointer: UnsafePointer<UInt8>?
                    var size = 0
                    CMVideoFormatDescriptionGetHEVCParameterSetAtIndex(format, parameterSetIndex: set, parameterSetPointerOut: &pointer, parameterSetSizeOut: &size,
                                                                       parameterSetCountOut: nil, nalUnitHeaderLengthOut: nil)
                    if let pointer { sets.append(Data(bytes: pointer, count: size)) }
                }
                collector.lock.withLock {
                    if !sets.isEmpty { collector.parameterSets = sets }
                    collector.pictures.append(nals)
                }
            }
        }
        VTCompressionSessionCompleteFrames(session, untilPresentationTimeStamp: .invalid)
        VTCompressionSessionInvalidate(session)
        return collector.lock.withLock { Encoded(parameterSets: collector.parameterSets, pictures: collector.pictures) }
    }
}

/// IP cameras' media: H.265 pictures decode from the SDP's parameter sets like H.264 ones, and the camera's
/// sound is played for G.711 and AAC only, a broken AAC frame being dropped
@Suite("RTSP media decoders", .serialized)
struct MediaDecoderTests {
    @Test func anH265CameraDecodesFromItsKeyFrameWithTheSDPsParameterSets() async throws {
        let encoded = try H265TestStream.encode()
        try #require(encoded.parameterSets.count == 3, "VPS, SPS and PPS")
        #expect(encoded.parameterSets.map { VideoDepacketizer.nalType($0, codec: .h265) } == [32, 33, 34])
        #expect(VideoDepacketizer.isKeyFrame(AccessUnit(nalUnits: encoded.pictures[0], timestamp: 0), codec: .h265))
        let frames = LockedValue<[CGSize]>([])
        let decoder = VideoDecoder(codec: .h265, parameterSets: encoded.parameterSets) { image in
            frames.value.append(CGSize(width: CVPixelBufferGetWidth(image), height: CVPixelBufferGetHeight(image)))
        }
        // A picture that depends on another first: nothing until the key frame
        decoder.decode(AccessUnit(nalUnits: encoded.pictures[1], timestamp: 1))
        try await Task.sleep(for: .milliseconds(200))
        #expect(frames.value.isEmpty)
        for (index, picture) in encoded.pictures.enumerated() { decoder.decode(AccessUnit(nalUnits: picture, timestamp: UInt32(2 + index))) }
        try await waitUntil("decoded") { frames.value.count >= encoded.pictures.count }
        #expect(frames.value.allSatisfy { $0 == CGSize(width: 320, height: 240) })
        // The same parameter sets in the stream again: same format, the session goes on
        decoder.decode(AccessUnit(nalUnits: encoded.parameterSets + encoded.pictures[0], timestamp: 20))
        try await waitUntil("decoded again") { frames.value.count >= encoded.pictures.count + 1 }
    }

    @Test func soundIsPlayedForGSevenElevenAndAACOnly() throws {
        let video = SDPMedia(kind: "video", payloadType: 96, codec: .h264, clockRate: 90_000)
        #expect(AudioPlayback(media: video) == nil)
        let other = SDPMedia(kind: "audio", payloadType: 97, codec: .unsupported("OPUS"), clockRate: 48_000)
        #expect(AudioPlayback(media: other) == nil)

        // G.711 µ-law at 8 kHz; no clock rate in the SDP is 8 kHz too
        let pcmu = try #require(AudioPlayback(media: SDPMedia(kind: "audio", payloadType: 0, codec: .pcmu, clockRate: 0)))
        #expect(!pcmu.isMuted)
        pcmu.isMuted = true
        #expect(pcmu.isMuted)
        pcmu.play(RTPPacket(marker: true, payloadType: 0, sequence: 1, timestamp: 0, ssrc: 1, payload: Data(repeating: 0xFF, count: 160)), sizeLength: 13, indexLength: 3)
        pcmu.isMuted = false
        #expect(!pcmu.isMuted)
        pcmu.stop()

        // AAC-LC 16 kHz mono (AudioSpecificConfig 1408): a frame the converter cannot decode is dropped, nothing breaks
        var aacMedia = SDPMedia(kind: "audio", payloadType: 97, codec: .aac, clockRate: 16_000)
        aacMedia.fmtp = ["config": "1408"]
        let aac = try #require(AudioPlayback(media: aacMedia))
        let broken = Data([0xDE, 0xAD, 0xBE, 0xEF, 0x00, 0x11])
        let header = UInt16(broken.count << 3)
        let payload = Data([0x00, 0x10, UInt8(header >> 8), UInt8(header & 0xFF)]) + broken
        #expect(AACDepacketizer.frames(payload) == [broken])
        aac.play(RTPPacket(marker: true, payloadType: 97, sequence: 1, timestamp: 0, ssrc: 1, payload: payload), sizeLength: 13, indexLength: 3)
        // No AU headers at all: nothing to play
        aac.play(RTPPacket(marker: true, payloadType: 97, sequence: 2, timestamp: 1024, ssrc: 1, payload: Data()), sizeLength: 13, indexLength: 3)
        aac.isMuted = true
        #expect(aac.isMuted)
        aac.stop()
    }
}
