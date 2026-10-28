import Foundation
import Observation

/// The directions of a PTZ pad (generic velocity space, half speed: smooth enough on a touch screen)
public enum PtzDirection: String, CaseIterable, Sendable {
    case left, right, up, down, zoomIn, zoomOut

    /// The speed of every direction
    public static let speed = 0.5

    /// The ContinuousMove velocity of this direction
    public var velocity: PtzVelocity {
        switch self {
        case .left: PtzVelocity(pan: -Self.speed)
        case .right: PtzVelocity(pan: Self.speed)
        case .up: PtzVelocity(tilt: Self.speed)
        case .down: PtzVelocity(tilt: -Self.speed)
        case .zoomIn: PtzVelocity(zoom: Self.speed)
        case .zoomOut: PtzVelocity(zoom: -Self.speed)
        }
    }
}

/// What is known of a camera's optical zoom
public struct OpticalZoom: Equatable, Sendable {
    /// No zoom space: zoom buttons can only zoom the picture (digital)
    public static let none = Self(available: false)
    /// Not known yet, or the camera refused GetNodes: the zoom buttons drive the lens
    public static let unknown = Self(available: true)
    /// How close to an end of the range counts as the end (lenses stop a little short)
    public static let edge = 0.02

    /// The lens can zoom (or it is not known that it cannot)
    public var available: Bool
    /// The lens's position, 0 (widest) ... 1 (closest), when the camera reported it
    public var level: Double?

    public init(available: Bool, level: Double? = nil) {
        self.available = available
        self.level = level
    }

    /// At (or very near) the widest position
    public var atWidest: Bool { level.map { $0 <= Self.edge } ?? false }
    /// At (or very near) the closest position
    public var atClosest: Bool { level.map { $0 >= 1 - Self.edge } ?? false }
}

/// A camera the PTZ controller drives: its device service (for the clock), PTZ service, profile and login
public struct PTZTarget: Equatable, Sendable {
    public var deviceURL: String
    /// The PTZ service; nil when the camera has none (commands are then not sent)
    public var ptzURL: String?
    public var profileToken: String
    public var credentials: OnvifCredentials?

    public init(deviceURL: String, ptzURL: String?, profileToken: String, credentials: OnvifCredentials?) {
        self.deviceURL = deviceURL
        self.ptzURL = ptzURL
        self.profileToken = profileToken
        self.credentials = credentials
    }

    /// PTZ works when the camera has the service (and the chosen profile a PTZ configuration)
    public var hasPtz: Bool { ptzURL != nil }
}

/// Pan, tilt and zoom of cameras, by id: holding a direction sends ContinuousMove, releasing it Stop. The commands of
/// one camera run in order (a Stop never overtakes its move); the camera's clock is read once per camera for the
/// WS-Security timestamp. A refused command calls `onCommandFailed` (once per refused command: a UI that shows alerts
/// should show at most one per camera). It also learns once per camera whether it zooms optically and where its lens is
/// (`probeZoom`, `opticalZoom`).
@MainActor
@Observable
public final class PTZController {
    /// How long a nudge (an accessibility activate instead of holding) moves the camera
    public static let nudge: Duration = .milliseconds(400)

    @ObservationIgnored private let target: (String) -> PTZTarget?
    @ObservationIgnored private let transport: any LanHTTPTransport
    @ObservationIgnored private let onCommandFailed: (String, OnvifError?) -> Void
    @ObservationIgnored private let logger: any Swift2RTCLogger
    @ObservationIgnored private let now: () -> Date
    @ObservationIgnored private let sleep: (Duration) async -> Void
    @ObservationIgnored private var clients: [String: OnvifClient] = [:]
    @ObservationIgnored private var queues: [String: Task<Void, Never>] = [:]
    @ObservationIgnored private var zoomSupport: [String: PtzZoomSupport] = [:]
    @ObservationIgnored private var probing: Set<String> = []
    /// What is known of each camera's optical zoom
    private var optical: [String: OpticalZoom] = [:]
    /// Whether commands may go to the camera now (for example: it answered its last check and is the device recorded
    /// for it); else nothing with its login is sent
    @ObservationIgnored private let verified: (String) -> Bool

    /// - Parameters:
    ///   - transport: plain HTTP to the cameras
    ///   - target: the camera with this id, or nil when there is none (commands for it are dropped)
    ///   - verified: whether commands may go to the camera right now
    ///   - onCommandFailed: a move or stop was refused (camera id, the ONVIF error when there is one)
    ///   - logger: where refusals are logged (kinds only)
    ///   - now: the clock (tests)
    ///   - sleep: how a nudge waits (tests)
    public init(transport: any LanHTTPTransport, target: @escaping (String) -> PTZTarget?, verified: @escaping (String) -> Bool = { _ in true },
                onCommandFailed: @escaping (String, OnvifError?) -> Void = { _, _ in }, logger: any Swift2RTCLogger = NoopLogger(),
                now: @escaping () -> Date = Date.init, sleep: @escaping (Duration) async -> Void = { try? await Task.sleep(for: $0) }) {
        self.transport = transport
        self.target = target
        self.verified = verified
        self.onCommandFailed = onCommandFailed
        self.logger = logger
        self.now = now
        self.sleep = sleep
    }

    /// What is known of `cameraId`'s optical zoom (`OpticalZoom.unknown` until `probeZoom` answered)
    public func opticalZoom(_ cameraId: String) -> OpticalZoom { optical[cameraId] ?? .unknown }

    /// Once per camera (for example when its pad shows): GetNodes says whether it has an optical zoom, then GetStatus
    /// where the lens is. Quiet: a camera that refuses them keeps `OpticalZoom.unknown` and is asked again next time.
    public func probeZoom(_ cameraId: String) {
        guard zoomSupport[cameraId] == nil, !probing.contains(cameraId) else { return }
        probing.insert(cameraId)
        let probe: (PTZTarget, OnvifClient) async throws -> Void = { [weak self] camera, client in
            guard let ptz = camera.ptzURL else { return }
            let support = try await client.ptzZoomSupport(ptzURL: ptz)
            guard let self else { return }
            zoomSupport[cameraId] = support
            probing.remove(cameraId)
            optical[cameraId] = support.optical ? OpticalZoom(available: true) : .none
            if support.optical { try await readZoom(cameraId, camera, client, support) }
        }
        let queued = enqueue(cameraId, quiet: { [weak self] in self?.probing.remove(cameraId) }, probe)
        // Not sent (no such camera, no PTZ, not verified): asked again next time
        if !queued { probing.remove(cameraId) }
    }

    /// Reads the lens's zoom position again (while and after the optical zoom moves)
    public func refreshZoom(_ cameraId: String) {
        guard let support = zoomSupport[cameraId], support.optical else { return }
        let read: (PTZTarget, OnvifClient) async throws -> Void = { [weak self] camera, client in try await self?.readZoom(cameraId, camera, client, support) }
        enqueue(cameraId, quiet: {}, read)
    }

    private func readZoom(_ cameraId: String, _ camera: PTZTarget, _ client: OnvifClient, _ support: PtzZoomSupport) async throws {
        guard let ptz = camera.ptzURL else { return }
        let position = try await client.ptzZoomPosition(ptzURL: ptz, profileToken: camera.profileToken)
        optical[cameraId] = OpticalZoom(available: true, level: position.map(support.normalized))
    }

    /// Starts moving the camera in `direction` (until `stop`)
    public func move(_ cameraId: String, _ direction: PtzDirection) {
        enqueue(cameraId) { camera, client in
            guard let ptz = camera.ptzURL else { return }
            try await client.continuousMove(ptzURL: ptz, profileToken: camera.profileToken, velocity: direction.velocity)
        }
    }

    /// Stops pan, tilt and zoom
    public func stop(_ cameraId: String) {
        enqueue(cameraId) { camera, client in
            guard let ptz = camera.ptzURL else { return }
            try await client.stop(ptzURL: ptz, profileToken: camera.profileToken)
        }
    }

    /// A short step: move, wait `nudge`, stop
    public func nudge(_ cameraId: String, _ direction: PtzDirection) {
        move(cameraId, direction)
        let sleep = sleep
        enqueue(cameraId) { _, _ in await sleep(Self.nudge) }
        stop(cameraId)
    }

    /// Waits until the commands of every camera so far are done
    public func idle() async {
        for task in queues.values { await task.value }
    }

    /// Drops the cameras' clients and what is known of them (signed out, cameras changed)
    public func reset() {
        clients.removeAll()
        queues.values.forEach { $0.cancel() }
        queues.removeAll()
        zoomSupport.removeAll()
        probing.removeAll()
        optical.removeAll()
    }

    /// Runs `command` after the camera's earlier ones; a refusal calls `onCommandFailed`, or only `quiet` when given.
    /// False when nothing was queued (no such camera, no PTZ, not verified).
    @discardableResult
    private func enqueue(_ cameraId: String, quiet: (() -> Void)? = nil, _ command: @escaping (PTZTarget, OnvifClient) async throws -> Void) -> Bool {
        guard let camera = target(cameraId), camera.hasPtz else { return false }
        guard verified(cameraId) else {
            logger.log(.info, "PTZ skipped: camera not verified")
            return false
        }
        let previous = queues[cameraId]
        queues[cameraId] = Task { [weak self] in
            await previous?.value
            guard let self, !Task.isCancelled else { return }
            let client = clients[cameraId] ?? OnvifClient(transport: transport, deviceURL: camera.deviceURL, credentials: camera.credentials, now: now)
            clients[cameraId] = client
            do {
                if !client.clockSynced { try await client.syncClock() }
                try await command(camera, client)
            } catch {
                let onvif = error as? OnvifError
                if let quiet {
                    logger.log(.info, "PTZ zoom query refused: \(onvif?.logDescription ?? "error")")
                    quiet()
                    return
                }
                logger.log(.info, "PTZ command refused: \(onvif?.logDescription ?? "error")")
                onCommandFailed(cameraId, onvif)
            }
        }
        return true
    }
}
