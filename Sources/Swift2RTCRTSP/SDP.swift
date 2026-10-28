import Foundation

/// The codecs the RTSP player plays (and `unsupported` for the rest)
public enum RTSPCodec: Equatable, Sendable {
    case h264
    case h265
    /// G.711 µ-law (payload type 0) and A-law (8), 8 kHz
    case pcmu
    case pcma
    /// AAC in RFC 3640 `mpeg4-generic` (AAC-hbr)
    case aac
    case unsupported(String)

    /// H.264 or H.265
    public var isVideo: Bool { self == .h264 || self == .h265 }
    /// G.711 or AAC
    public var isAudio: Bool { self == .pcmu || self == .pcma || self == .aac }
}

/// One `m=` section of a DESCRIBE answer
public struct SDPMedia: Equatable, Sendable {
    public var kind: String
    public var payloadType: Int
    public var codec: RTSPCodec
    public var clockRate: Int
    public var channels = 1
    public var control: String?
    public var fmtp: [String: String] = [:]

    public init(kind: String, payloadType: Int, codec: RTSPCodec, clockRate: Int, channels: Int = 1, control: String? = nil, fmtp: [String: String] = [:]) {
        self.kind = kind
        self.payloadType = payloadType
        self.codec = codec
        self.clockRate = clockRate
        self.channels = channels
        self.control = control
        self.fmtp = fmtp
    }

    /// H.264 `sprop-parameter-sets` (SPS, PPS) or H.265 `sprop-vps` / `sprop-sps` / `sprop-pps`, as NAL units
    public var parameterSets: [Data] {
        let decode = { (text: String?) -> [Data] in
            (text ?? "").split(separator: ",").compactMap { Data(base64Encoded: String($0).trimmingCharacters(in: .whitespaces), options: .ignoreUnknownCharacters) }
        }
        switch codec {
        case .h264: return decode(fmtp["sprop-parameter-sets"])
        case .h265: return decode(fmtp["sprop-vps"]) + decode(fmtp["sprop-sps"]) + decode(fmtp["sprop-pps"])
        default: return []
        }
    }

    /// AAC's AudioSpecificConfig (`config=` in hex)
    public var audioSpecificConfig: Data? {
        guard let hex = fmtp["config"], hex.count.isMultiple(of: 2), !hex.isEmpty else { return nil }
        var bytes: [UInt8] = []
        var index = hex.startIndex
        while index < hex.endIndex {
            let next = hex.index(index, offsetBy: 2)
            guard let byte = UInt8(hex[index..<next], radix: 16) else { return nil }
            bytes.append(byte)
            index = next
        }
        return Data(bytes)
    }

    /// RFC 3640 AU header sizes (AAC-hbr: 13 and 3)
    public var sizeLength: Int { fmtp["sizelength"].flatMap(Int.init) ?? 13 }
    public var indexLength: Int { fmtp["indexlength"].flatMap(Int.init) ?? 3 }
}

/// A session description (RFC 4566), the parts the player needs
public struct SDP: Equatable, Sendable {
    public var media: [SDPMedia]
    /// The session-level `a=control`
    public var control: String?

    public init(media: [SDPMedia], control: String? = nil) {
        self.media = media
        self.control = control
    }

    /// The first H.264/H.265 track
    public var video: SDPMedia? { media.first { $0.codec.isVideo } }
    /// The first G.711/AAC track
    public var audio: SDPMedia? { media.first { $0.codec.isAudio } }

    /// Reads a DESCRIBE answer's body; unknown lines are ignored
    public static func parse(_ text: String) -> SDP {
        var media: [SDPMedia] = []
        var sessionControl: String?
        var current: SDPMedia?
        var rtpmaps: [Int: (String, Int, Int)] = [:]
        func finish() {
            guard var section = current else { return }
            if let (name, rate, channels) = rtpmaps[section.payloadType] {
                section.codec = codec(name: name, payloadType: section.payloadType)
                section.clockRate = rate
                section.channels = channels
            }
            media.append(section)
            rtpmaps = [:]
        }
        for rawLine in text.components(separatedBy: .newlines) {
            let line = rawLine.trimmingCharacters(in: .whitespaces)
            if line.hasPrefix("m=") {
                finish()
                let parts = line.dropFirst(2).split(separator: " ")
                let payloadType = parts.count > 3 ? Int(parts[3]) ?? -1 : -1
                let staticCodec = codec(name: "", payloadType: payloadType)
                current = SDPMedia(kind: parts.first.map(String.init) ?? "", payloadType: payloadType, codec: staticCodec,
                                   clockRate: payloadType == 0 || payloadType == 8 ? 8000 : 90000)
            } else if line.hasPrefix("a=control:") {
                let value = String(line.dropFirst("a=control:".count))
                if current != nil { current?.control = value } else { sessionControl = value }
            } else if line.hasPrefix("a=rtpmap:"), current != nil {
                let value = line.dropFirst("a=rtpmap:".count)
                let parts = value.split(separator: " ", maxSplits: 1)
                guard parts.count == 2, let payloadType = Int(parts[0]) else { continue }
                let encoding = parts[1].split(separator: "/")
                rtpmaps[payloadType] = (String(encoding.first ?? ""), encoding.count > 1 ? Int(encoding[1]) ?? 90000 : 90000, encoding.count > 2 ? Int(encoding[2]) ?? 1 : 1)
            } else if line.hasPrefix("a=fmtp:"), current != nil {
                let value = line.dropFirst("a=fmtp:".count)
                guard let space = value.firstIndex(of: " "), Int(value[..<space]) == current?.payloadType else { continue }
                for parameter in value[value.index(after: space)...].split(separator: ";") {
                    let pair = parameter.split(separator: "=", maxSplits: 1)
                    guard pair.count == 2 else { continue }
                    current?.fmtp[pair[0].trimmingCharacters(in: .whitespaces).lowercased()] = pair[1].trimmingCharacters(in: .whitespaces)
                }
            }
        }
        finish()
        return SDP(media: media, control: sessionControl)
    }

    private static func codec(name: String, payloadType: Int) -> RTSPCodec {
        switch name.uppercased() {
        case "H264": return .h264
        case "H265", "HEVC": return .h265
        case "PCMU": return .pcmu
        case "PCMA": return .pcma
        case "MPEG4-GENERIC": return .aac
        case "":
            return payloadType == 0 ? .pcmu : payloadType == 8 ? .pcma : .unsupported("pt\(payloadType)")
        default: return .unsupported(name)
        }
    }
}
