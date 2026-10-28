import Foundation

/// An RTP packet (RFC 3550): header fields and the payload without CSRCs, extension or padding
public struct RTPPacket: Equatable, Sendable {
    public var marker: Bool
    public var payloadType: Int
    public var sequence: UInt16
    public var timestamp: UInt32
    public var ssrc: UInt32
    public var payload: Data

    public init(marker: Bool, payloadType: Int, sequence: UInt16, timestamp: UInt32, ssrc: UInt32, payload: Data) {
        self.marker = marker
        self.payloadType = payloadType
        self.sequence = sequence
        self.timestamp = timestamp
        self.ssrc = ssrc
        self.payload = payload
    }

    /// The packet in `data`, or nil when it is not RTP version 2 or is cut short
    public static func parse(_ data: Data) -> RTPPacket? {
        let bytes = [UInt8](data)
        guard bytes.count >= 12, bytes[0] >> 6 == 2 else { return nil }
        let padding = bytes[0] & 0x20 != 0
        let hasExtension = bytes[0] & 0x10 != 0
        let csrcCount = Int(bytes[0] & 0x0F)
        var offset = 12 + csrcCount * 4
        if hasExtension {
            guard bytes.count >= offset + 4 else { return nil }
            let words = Int(bytes[offset + 2]) << 8 | Int(bytes[offset + 3])
            offset += 4 + words * 4
        }
        var end = bytes.count
        if padding, let last = bytes.last { end -= Int(last) }
        guard offset <= end else { return nil }
        return RTPPacket(marker: bytes[1] & 0x80 != 0, payloadType: Int(bytes[1] & 0x7F), sequence: UInt16(bytes[2]) << 8 | UInt16(bytes[3]),
                         timestamp: UInt32(bytes[4]) << 24 | UInt32(bytes[5]) << 16 | UInt32(bytes[6]) << 8 | UInt32(bytes[7]),
                         ssrc: UInt32(bytes[8]) << 24 | UInt32(bytes[9]) << 16 | UInt32(bytes[10]) << 8 | UInt32(bytes[11]),
                         payload: Data(bytes[offset..<end]))
    }

    /// The packet's bytes (no CSRCs, extension or padding)
    public func serialized() -> Data {
        var bytes: [UInt8] = [0x80, (marker ? 0x80 : 0) | UInt8(payloadType & 0x7F), UInt8(sequence >> 8), UInt8(sequence & 0xFF)]
        bytes += [UInt8(timestamp >> 24), UInt8(timestamp >> 16 & 0xFF), UInt8(timestamp >> 8 & 0xFF), UInt8(timestamp & 0xFF)]
        bytes += [UInt8(ssrc >> 24), UInt8(ssrc >> 16 & 0xFF), UInt8(ssrc >> 8 & 0xFF), UInt8(ssrc & 0xFF)]
        return Data(bytes) + payload
    }
}

/// A coded picture: its NAL units (without start codes) and RTP timestamp
public struct AccessUnit: Equatable, Sendable {
    public var nalUnits: [Data]
    public var timestamp: UInt32

    public init(nalUnits: [Data], timestamp: UInt32) {
        self.nalUnits = nalUnits
        self.timestamp = timestamp
    }
}

/// H.264 (RFC 6184) and H.265 (RFC 7798) depacketization: single NAL units, aggregation packets (STAP-A / AP) and
/// fragmentation units (FU-A / FU), gathered into access units by the marker bit or a new timestamp. A fragmented NAL
/// unit with a lost piece (sequence gap) is dropped, and the picture with it; the decoder then waits for the next key
/// frame.
public struct VideoDepacketizer {
    /// `.h264` or `.h265`
    public let codec: RTSPCodec
    private var nalUnits: [Data] = []
    private var timestamp: UInt32?
    private var fragment: Data?
    private var lastSequence: UInt16?
    private var damaged = false

    public init(codec: RTSPCodec) {
        self.codec = codec
    }

    /// The access units this packet completes (usually zero or one)
    public mutating func push(_ packet: RTPPacket) -> [AccessUnit] {
        var completed: [AccessUnit] = []
        if let last = lastSequence, packet.sequence != last &+ 1 {
            // Lost packets: a fragment in progress cannot be completed
            if fragment != nil { damaged = true }
            fragment = nil
        }
        lastSequence = packet.sequence
        if let timestamp, timestamp != packet.timestamp, !nalUnits.isEmpty {
            if let unit = finish() { completed.append(unit) }
        }
        timestamp = packet.timestamp
        if codec == .h265 { pushH265(packet.payload) } else { pushH264(packet.payload) }
        if packet.marker, let unit = finish() { completed.append(unit) }
        return completed
    }

    private mutating func finish() -> AccessUnit? {
        defer {
            nalUnits = []
            fragment = nil
            damaged = false
        }
        guard !nalUnits.isEmpty, !damaged, let timestamp else { return nil }
        return AccessUnit(nalUnits: nalUnits, timestamp: timestamp)
    }

    private mutating func pushH264(_ payload: Data) {
        let bytes = [UInt8](payload)
        guard let first = bytes.first else { return }
        switch first & 0x1F {
        case 24: // STAP-A: 16-bit size, NAL unit, ...
            var offset = 1
            while offset + 2 <= bytes.count {
                let size = Int(bytes[offset]) << 8 | Int(bytes[offset + 1])
                offset += 2
                guard size > 0, offset + size <= bytes.count else { break }
                nalUnits.append(Data(bytes[offset..<(offset + size)]))
                offset += size
            }
        case 28: // FU-A: indicator, header (S, E, type), fragment
            guard bytes.count > 2 else { return }
            let header = bytes[1]
            if header & 0x80 != 0 {
                fragment = Data([(first & 0xE0) | (header & 0x1F)]) + Data(bytes[2...])
            } else if fragment != nil {
                fragment?.append(contentsOf: bytes[2...])
            } else {
                damaged = true
                return
            }
            if header & 0x40 != 0, let complete = fragment {
                nalUnits.append(complete)
                fragment = nil
            }
        case 1...23:
            nalUnits.append(payload)
        default:
            break
        }
    }

    private mutating func pushH265(_ payload: Data) {
        let bytes = [UInt8](payload)
        guard bytes.count >= 2 else { return }
        switch (bytes[0] >> 1) & 0x3F {
        case 48: // AP: 2-byte header, then 16-bit size + NAL unit, ...
            var offset = 2
            while offset + 2 <= bytes.count {
                let size = Int(bytes[offset]) << 8 | Int(bytes[offset + 1])
                offset += 2
                guard size > 0, offset + size <= bytes.count else { break }
                nalUnits.append(Data(bytes[offset..<(offset + size)]))
                offset += size
            }
        case 49: // FU: 2-byte header, FU header (S, E, type), fragment
            guard bytes.count > 3 else { return }
            let header = bytes[2]
            if header & 0x80 != 0 {
                let type = header & 0x3F
                fragment = Data([(bytes[0] & 0x81) | (type << 1), bytes[1]]) + Data(bytes[3...])
            } else if fragment != nil {
                fragment?.append(contentsOf: bytes[3...])
            } else {
                damaged = true
                return
            }
            if header & 0x40 != 0, let complete = fragment {
                nalUnits.append(complete)
                fragment = nil
            }
        case 50: // PACI: not used by cameras
            break
        default:
            nalUnits.append(payload)
        }
    }

    /// The NAL unit type (H.264: 5 bits; H.265: 6 bits)
    public static func nalType(_ nal: Data, codec: RTSPCodec) -> Int {
        guard let first = nal.first else { return -1 }
        return codec == .h265 ? Int((first >> 1) & 0x3F) : Int(first & 0x1F)
    }

    /// A key frame (H.264 IDR 5; H.265 IRAP 16...21)
    public static func isKeyFrame(_ unit: AccessUnit, codec: RTSPCodec) -> Bool {
        unit.nalUnits.contains { nal in
            let type = nalType(nal, codec: codec)
            return codec == .h265 ? (16...21).contains(type) : type == 5
        }
    }

    /// Parameter set NAL units (H.264 SPS 7, PPS 8; H.265 VPS 32, SPS 33, PPS 34)
    public static func isParameterSet(_ nal: Data, codec: RTSPCodec) -> Bool {
        let type = nalType(nal, codec: codec)
        return codec == .h265 ? (32...34).contains(type) : type == 7 || type == 8
    }
}

/// AAC in RFC 3640 (`mpeg4-generic`, AAC-hbr): a 16-bit AU-headers length in bits, AU headers (size and index), then the
/// access units
public enum AACDepacketizer {
    /// The access units of one RTP payload
    public static func frames(_ payload: Data, sizeLength: Int = 13, indexLength: Int = 3) -> [Data] {
        let bytes = [UInt8](payload)
        guard bytes.count >= 2, sizeLength > 0 else { return [] }
        let headersBits = Int(bytes[0]) << 8 | Int(bytes[1])
        let headersBytes = (headersBits + 7) / 8
        let headerBits = sizeLength + indexLength
        guard headerBits > 0, bytes.count >= 2 + headersBytes else { return [] }
        var sizes: [Int] = []
        var bit = 0
        while bit + headerBits <= headersBits {
            var value = 0
            for offset in 0..<sizeLength {
                let position = bit + offset
                value = value << 1 | Int((bytes[2 + position / 8] >> (7 - UInt8(position % 8))) & 1)
            }
            sizes.append(value)
            bit += headerBits
        }
        var frames: [Data] = []
        var offset = 2 + headersBytes
        for size in sizes {
            guard offset + size <= bytes.count else { break }
            frames.append(Data(bytes[offset..<(offset + size)]))
            offset += size
        }
        return frames
    }
}

/// G.711 to 16-bit linear PCM (ITU-T G.711)
public enum G711 {
    /// One µ-law byte as a 16-bit sample
    public static func decodeMuLaw(_ byte: UInt8) -> Int16 {
        let value = ~byte
        let sign = value & 0x80
        let exponent = Int((value >> 4) & 0x07)
        let mantissa = Int(value & 0x0F)
        let magnitude = ((mantissa << 3) + 0x84) << exponent
        return Int16(sign != 0 ? 0x84 - magnitude : magnitude - 0x84)
    }

    /// One A-law byte as a 16-bit sample
    public static func decodeALaw(_ byte: UInt8) -> Int16 {
        let value = byte ^ 0x55
        let sign = value & 0x80
        let exponent = Int((value >> 4) & 0x07)
        let mantissa = Int(value & 0x0F)
        var magnitude = (mantissa << 4) + 8
        if exponent != 0 { magnitude = (magnitude + 0x100) << (exponent - 1) }
        return Int16(sign != 0 ? magnitude : -magnitude)
    }

    /// A G.711 payload (`.pcma` A-law, else µ-law) as 16-bit samples
    public static func decode(_ payload: Data, codec: RTSPCodec) -> [Int16] {
        payload.map { codec == .pcma ? decodeALaw($0) : decodeMuLaw($0) }
    }
}
