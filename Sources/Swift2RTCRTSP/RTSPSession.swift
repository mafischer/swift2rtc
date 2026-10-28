import Foundation
import Network

/// Why an RTSP stream failed
public enum RTSPFailure: Equatable, Sendable {
    /// No answer from the camera: another network, the camera is off, or the address changed
    case unreachable
    /// The camera refused the user name or password (RTSP 401 after answering its challenge)
    case unauthorized
    /// Anything else: an error status, no supported codec, a dropped connection, no media
    case other
}

/// The connection the session talks over: TCP to the camera (`NWByteStream`), a scripted camera in tests. Every callback
/// runs on the queue given to `start`.
public protocol RTSPByteStream: AnyObject, Sendable {
    /// Connects; `onReady` once connected, `onData` for each chunk received, `onClose(true)` when it failed before it was
    /// ready, `onClose(false)` when an open connection ended
    func start(queue: DispatchQueue, onReady: @escaping @Sendable () -> Void, onData: @escaping @Sendable (Data) -> Void, onClose: @escaping @Sendable (Bool) -> Void)
    /// Sends bytes (fire and forget)
    func send(_ data: Data)
    /// Closes the connection; no callback afterwards
    func cancel()
}

/// TCP to the camera's RTSP port (Network.framework: App Transport Security does not apply). `onClose(true)` when it
/// failed before it was ready.
public final class NWByteStream: RTSPByteStream, @unchecked Sendable {
    private let connection: NWConnection
    private var ready = false
    private var closed = false

    /// `connectTimeout` in seconds
    public init(host: String, port: UInt16, connectTimeout: Int = 5) {
        let tcp = NWProtocolTCP.Options()
        tcp.noDelay = true
        tcp.connectionTimeout = connectTimeout
        connection = NWConnection(host: NWEndpoint.Host(host), port: NWEndpoint.Port(rawValue: port) ?? 554, using: NWParameters(tls: nil, tcp: tcp))
    }

    public func start(queue: DispatchQueue, onReady: @escaping @Sendable () -> Void, onData: @escaping @Sendable (Data) -> Void, onClose: @escaping @Sendable (Bool) -> Void) {
        connection.stateUpdateHandler = { [weak self] state in
            guard let self, !closed else { return }
            switch state {
            case .ready:
                ready = true
                onReady()
                receive(onData: onData, onClose: onClose)
            case .failed, .waiting:
                closed = true
                connection.cancel()
                onClose(!ready)
            default:
                break
            }
        }
        connection.start(queue: queue)
    }

    private func receive(onData: @escaping @Sendable (Data) -> Void, onClose: @escaping @Sendable (Bool) -> Void) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 256 * 1024) { [weak self] data, _, isComplete, error in
            guard let self, !closed else { return }
            if let data, !data.isEmpty { onData(data) }
            if isComplete || error != nil {
                closed = true
                connection.cancel()
                onClose(false)
                return
            }
            receive(onData: onData, onClose: onClose)
        }
    }

    public func send(_ data: Data) {
        connection.send(content: data, completion: .contentProcessed { _ in })
    }

    public func cancel() {
        closed = true
        connection.cancel()
    }
}

/// One RTSP session with an IP camera (RFC 2326), RTP interleaved in the TCP connection: DESCRIBE (answering a Digest or
/// Basic challenge once), SETUP of the video track (H.264/H.265) and, when the player can play it, the audio track (G.711,
/// AAC), PLAY, then RTP packets until `close` (TEARDOWN). Keeps the session alive with GET_PARAMETER (OPTIONS when the
/// camera does not list it) at half its timeout, and fails when no media arrives for `mediaTimeout`.
///
/// Runs on its own serial queue; `onVideo`, `onAudio`, `onPlaying` and `onFailure` are called there (set them before
/// `start`). The URL may carry the camera's credentials as user info: they are taken out of it and never sent in a
/// request line or logged.
public final class RTSPSession: @unchecked Sendable {
    /// The session's serial queue: every callback runs on it
    public let queue = DispatchQueue(label: "swift2rtc.rtsp")
    /// The SDP's video track, once DESCRIBE answered
    public private(set) var video: SDPMedia?
    /// The SDP's audio track when `playsAudio` accepted its codec
    public private(set) var audio: SDPMedia?

    /// A video RTP packet
    public var onVideo: ((RTPPacket) -> Void)?
    /// An audio RTP packet
    public var onAudio: ((RTPPacket) -> Void)?
    /// PLAY was answered
    public var onPlaying: (() -> Void)?
    /// The session ended (once; nothing is called afterwards)
    public var onFailure: ((RTSPFailure) -> Void)?

    private let url: String
    private let credentials: OnvifCredentials?
    private let stream: any RTSPByteStream
    private let setupTimeout: TimeInterval
    private let mediaTimeout: TimeInterval
    private let playsAudio: (RTSPCodec) -> Bool
    private let userAgent: String
    private let logger: any Swift2RTCLogger

    private var parser = RTSPStreamParser()
    private var cseq = 0
    private var pending: [Int: (method: String, url: String, headers: [(String, String)], retried: Bool)] = [:]
    private var challenge: HTTPDigest.Challenge?
    private var basic = false
    private var nonceCount = 0
    private var sessionId: String?
    private var sessionTimeout: TimeInterval = 60
    private var baseURL: String
    private var setupQueue: [(SDPMedia, Int)] = []
    private var channels: [Int: SDPMedia] = [:]
    private var supportsGetParameter = false
    private var answered = false
    private var playing = false
    private var finished = false
    private var lastMedia = Date()
    private var timers: [DispatchSourceTimer] = []

    /// - Parameters:
    ///   - url: `rtsp://` with optional user info (the login, percent-encoded)
    ///   - setupTimeout: seconds until PLAY must be answered
    ///   - mediaTimeout: seconds without media after which the stream fails
    ///   - playsAudio: whether the audio track of this codec is set up
    ///   - userAgent: the `User-Agent` of every request
    ///   - logger: where failures are logged (kinds only)
    ///   - connect: opens the byte stream to the URL's host and port (TCP by default; a scripted camera in tests)
    public init(url: String, setupTimeout: TimeInterval = 10, mediaTimeout: TimeInterval = 10, playsAudio: @escaping (RTSPCodec) -> Bool = { $0.isAudio },
                userAgent: String = RTSPRequest.defaultUserAgent, logger: any Swift2RTCLogger = NoopLogger(),
                connect: (String, UInt16) -> any RTSPByteStream = { NWByteStream(host: $0, port: $1) }) {
        let (bare, credentials) = RTSPURLs.split(url)
        self.url = bare
        self.credentials = credentials
        baseURL = bare
        self.setupTimeout = setupTimeout
        self.mediaTimeout = mediaTimeout
        self.playsAudio = playsAudio
        self.userAgent = userAgent
        self.logger = logger
        let components = URLComponents(string: bare)
        let host = (components?.host ?? "").trimmingCharacters(in: CharacterSet(charactersIn: "[]"))
        stream = connect(host, UInt16(clamping: components?.port ?? 554))
    }

    /// Connects and starts the exchange
    public func start() {
        queue.async { [self] in
            schedule(after: setupTimeout) { [weak self] in
                guard let self, !playing else { return }
                fail(answered ? .other : .unreachable)
            }
            stream.start(queue: queue, onReady: { [weak self] in
                guard let self else { return }
                request("OPTIONS", url: url)
            }, onData: { [weak self] data in
                self?.received(data)
            }, onClose: { [weak self] beforeReady in
                guard let self else { return }
                fail(beforeReady || !answered ? .unreachable : .other)
            })
        }
    }

    /// TEARDOWN and close; no callback afterwards
    public func close() {
        queue.async { [self] in
            guard !finished else { return }
            finished = true
            if sessionId != nil { request("TEARDOWN", url: baseURL) }
            stop()
        }
    }

    private func stop() {
        timers.forEach { $0.cancel() }
        timers.removeAll()
        // A moment for the TEARDOWN to leave
        let stream = stream
        queue.asyncAfter(deadline: .now() + 0.2) { stream.cancel() }
        onVideo = nil
        onAudio = nil
        onPlaying = nil
        onFailure = nil
    }

    private func fail(_ failure: RTSPFailure) {
        guard !finished else { return }
        finished = true
        let callback = onFailure
        stop()
        callback?(failure)
    }

    // MARK: Requests

    private func request(_ method: String, url: String, headers: [(String, String)] = [], retried: Bool = false) {
        cseq += 1
        var all = headers
        if let sessionId, method != "OPTIONS" || playing { all.append(("Session", sessionId)) }
        if let authorization = authorization(method: method, url: url) { all.append(("Authorization", authorization)) }
        pending[cseq] = (method, url, headers, retried)
        stream.send(RTSPRequest.make(method, url: url, cseq: cseq, headers: all, userAgent: userAgent))
    }

    private func authorization(method: String, url: String) -> String? {
        guard let credentials else { return nil }
        if basic { return HTTPDigest.basic(credentials) }
        guard let challenge else { return nil }
        nonceCount += 1
        return HTTPDigest.authorization(challenge, credentials: credentials, method: method, uri: url, cnonce: HTTPDigest.cnonce(), nonceCount: nonceCount)
    }

    // MARK: Responses and media

    private func received(_ data: Data) {
        guard !finished else { return }
        parser.append(data)
        do {
            while !finished, let frame = try parser.next() {
                switch frame {
                case .response(let response): handle(response)
                case .interleaved(let channel, let payload): media(channel: Int(channel), payload: payload)
                }
            }
        } catch {
            fail(.other)
        }
    }

    private func media(channel: Int, payload: Data) {
        guard let track = channels[channel], let packet = RTPPacket.parse(payload) else { return }
        lastMedia = Date()
        if track.codec.isVideo { onVideo?(packet) } else { onAudio?(packet) }
    }

    private func handle(_ response: RTSPResponse) {
        guard let cseq = response.cseq, let sent = pending.removeValue(forKey: cseq) else { return }
        answered = true
        if response.status == 401 {
            guard credentials != nil, !sent.retried else { return fail(.unauthorized) }
            let header = response.header("WWW-Authenticate")
            if let digest = HTTPDigest.parseChallenge(header) {
                challenge = digest
                basic = false
            } else if header?.lowercased().hasPrefix("basic") == true {
                basic = true
            } else {
                return fail(.unauthorized)
            }
            request(sent.method, url: sent.url, headers: sent.headers, retried: true)
            return
        }
        switch sent.method {
        case "OPTIONS":
            supportsGetParameter = response.header("Public")?.uppercased().contains("GET_PARAMETER") ?? false
            // Some cameras refuse OPTIONS without a session: go on anyway
            if !playing { request("DESCRIBE", url: url, headers: [("Accept", "application/sdp")]) }
        case "DESCRIBE":
            guard response.status == 200 else { return fail(.other) }
            described(response)
        case "SETUP":
            guard (200...299).contains(response.status), let (track, channel) = setupQueue.first else { return fail(.other) }
            setupQueue.removeFirst()
            if sessionId == nil {
                sessionId = response.sessionId
                sessionTimeout = response.sessionTimeout
            }
            channels[RTSPRequest.interleavedChannel(response.header("Transport")) ?? channel] = track
            setupNext()
        case "PLAY":
            guard (200...299).contains(response.status) else { return fail(.other) }
            startPlaying()
        default:
            break
        }
    }

    private func described(_ response: RTSPResponse) {
        let sdp = SDP.parse(String(decoding: response.body, as: UTF8.self))
        baseURL = response.header("Content-Base") ?? response.header("Content-Location") ?? url
        video = sdp.video
        audio = sdp.audio.flatMap { playsAudio($0.codec) ? $0 : nil }
        guard video != nil || audio != nil else {
            logger.log(.info, "RTSP: no supported codec in \(sdp.media.map { "\($0.codec)" }.joined(separator: ","))")
            return fail(.other)
        }
        var channel = 0
        for track in [video, audio].compactMap({ $0 }) {
            setupQueue.append((track, channel))
            channel += 2
        }
        setupNext()
    }

    private func setupNext() {
        guard let (track, channel) = setupQueue.first else {
            request("PLAY", url: baseURL, headers: [("Range", "npt=0.000-")])
            return
        }
        request("SETUP", url: RTSPRequest.controlURL(track.control, base: baseURL), headers: [("Transport", RTSPRequest.tcpTransport(channel: channel))])
    }

    private func startPlaying() {
        playing = true
        lastMedia = Date()
        onPlaying?()
        let keepAlive = max(5, sessionTimeout / 2)
        repeating(every: keepAlive) { [weak self] in
            guard let self else { return }
            request(supportsGetParameter ? "GET_PARAMETER" : "OPTIONS", url: baseURL)
        }
        repeating(every: 1) { [weak self] in
            guard let self, Date().timeIntervalSince(lastMedia) > mediaTimeout else { return }
            logger.log(.info, "RTSP: no media for \(Int(mediaTimeout)) s")
            fail(.other)
        }
    }

    // MARK: Timers (on the queue)

    private func schedule(after seconds: TimeInterval, _ body: @escaping () -> Void) {
        let timer = DispatchSource.makeTimerSource(queue: queue)
        timer.schedule(deadline: .now() + seconds)
        timer.setEventHandler(handler: body)
        timer.resume()
        timers.append(timer)
    }

    private func repeating(every seconds: TimeInterval, _ body: @escaping () -> Void) {
        let timer = DispatchSource.makeTimerSource(queue: queue)
        timer.schedule(deadline: .now() + seconds, repeating: seconds)
        timer.setEventHandler(handler: body)
        timer.resume()
        timers.append(timer)
    }
}
