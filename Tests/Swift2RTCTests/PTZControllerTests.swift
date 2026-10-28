import Foundation
import Testing
@testable import Swift2RTCCore
@testable import Swift2RTCOnvif

/// Pan, tilt and zoom: in order per camera, the clock once, a callback when refused, the optical zoom probe
@Suite("PTZ")
@MainActor
struct PTZControllerTests {
    /// The cameras by id, the failures reported and the nudges' naps
    @MainActor
    final class World {
        var cameras: [String: PTZTarget] = [
            "garden": PTZTarget(deviceURL: FakeOnvifCamera.device.deviceURL, ptzURL: "http://\(FakeOnvifCamera.host)/onvif/ptz_service", profileToken: "MainStream",
                                credentials: OnvifCredentials(username: FakeOnvifCamera.username, password: FakeOnvifCamera.password)),
        ]
        var failures: [(String, OnvifError?)] = []
        var naps: [Duration] = []

        func ptz(_ transport: any LanHTTPTransport, verified: @escaping (String) -> Bool = { _ in true }) -> PTZController {
            PTZController(transport: transport, target: { [unowned self] in cameras[$0] }, verified: verified,
                          onCommandFailed: { [unowned self] in failures.append(($0, $1)) }, sleep: { [unowned self] in naps.append($0) })
        }
    }

    /// The fake camera behind a recorder that can hold the first move back
    final class GatedCamera: LanHTTPTransport {
        let camera = FakeOnvifCamera.Transport()
        var gate: CheckedContinuation<Void, Never>?
        var holdFirstMove = false
        private(set) var operations: [String] = []
        private(set) var bodies: [String] = []

        func send(_ request: LanRequest) async throws -> LanResponse {
            operations.append(request.operation ?? "")
            bodies.append(request.text)
            if request.operation == "ContinuousMove", holdFirstMove {
                holdFirstMove = false
                await withCheckedContinuation { gate = $0 }
            }
            return try await camera.send(request)
        }
    }

    @Test func aCameraThatIsNotVerifiedGetsNoCommand() async {
        let world = World()
        let camera = GatedCamera()
        var verified = false
        let ptz = world.ptz(camera, verified: { _ in verified })
        ptz.move("garden", .left)
        ptz.stop("garden")
        await ptz.idle()
        #expect(camera.operations.isEmpty)
        verified = true
        ptz.move("garden", .left)
        await ptz.idle()
        #expect(camera.operations == ["GetSystemDateAndTime", "ContinuousMove"])
    }

    @Test func holdingMovesReleasingStopsInThatOrderTheClockReadOnce() async throws {
        let world = World()
        let camera = GatedCamera()
        camera.holdFirstMove = true
        let ptz = world.ptz(camera)
        ptz.move("garden", .left)
        ptz.stop("garden")
        try await waitUntil("move sent") { camera.gate != nil }
        #expect(camera.operations == ["GetSystemDateAndTime", "ContinuousMove"])
        camera.gate?.resume()
        await ptz.idle()
        #expect(camera.operations == ["GetSystemDateAndTime", "ContinuousMove", "Stop"])
        #expect(camera.bodies[1].contains("<tt:PanTilt x=\"-0.5\" y=\"0.0\""))
        #expect(camera.bodies[2].contains("<tptz:ProfileToken>MainStream</tptz:ProfileToken>"))

        ptz.move("garden", .zoomIn)
        await ptz.idle()
        #expect(camera.bodies.last?.contains("<tt:Zoom x=\"0.5\"") == true)
        // No second clock request
        #expect(camera.operations.filter { $0 == "GetSystemDateAndTime" }.count == 1)
        #expect(world.failures.isEmpty)
    }

    @Test func aNudgeMovesWaitsAndStops() async {
        let world = World()
        let camera = GatedCamera()
        let ptz = world.ptz(camera)
        ptz.nudge("garden", .up)
        await ptz.idle()
        #expect(camera.operations == ["GetSystemDateAndTime", "ContinuousMove", "Stop"])
        #expect(world.naps == [PTZController.nudge])
        #expect(camera.bodies[1].contains("<tt:PanTilt x=\"0.0\" y=\"0.5\""))
    }

    @Test func aRefusedCommandIsReportedCamerasWithoutPTZAreLeftAlone() async throws {
        let world = World()
        let transport = RecordingLanTransport { request in
            request.operation == "GetSystemDateAndTime" ? OnvifFixtures.soap(200, FakeOnvifCamera.systemDateAndTime) : LanResponse(status: 500)
        }
        let ptz = world.ptz(transport)
        ptz.move("garden", .right)
        ptz.stop("garden")
        await ptz.idle()
        // Each refused command is reported (a UI shows at most one alert per camera)
        #expect(world.failures.map(\.0) == ["garden", "garden"])
        #expect(world.failures.map(\.1) == [.http(500), .http(500)])

        var fixed = world.cameras["garden"]!
        fixed.ptzURL = nil
        world.cameras["fixed"] = fixed
        let before = transport.requests.count
        ptz.move("fixed", .left)
        ptz.move("unknown", .left)
        await ptz.idle()
        #expect(transport.requests.count == before)

        ptz.reset()
        ptz.stop("garden")
        await ptz.idle()
        // A new client after a reset reads the clock again
        #expect(transport.requests.filter { $0.operation == "GetSystemDateAndTime" }.count == 2)
    }

    // MARK: The optical zoom probe

    /// The fake camera behind a recorder; `answer` may replace its answers
    final class RecordingCamera: LanHTTPTransport {
        private let camera: FakeOnvifCamera.Transport
        private let answer: ((LanRequest) async throws -> LanResponse)?
        private(set) var requests: [LanRequest] = []
        var last: LanRequest { requests[requests.count - 1] }

        init(_ camera: FakeOnvifCamera.Transport, answer: ((LanRequest) async throws -> LanResponse)? = nil) {
            self.camera = camera
            self.answer = answer
        }

        func send(_ request: LanRequest) async throws -> LanResponse {
            requests.append(request)
            if let answer { return try await answer(request) }
            return try await camera.send(request)
        }
    }

    @Test func itLearnsOnceWhetherTheCameraZoomsOpticallyAndWhereItsLensIs() async {
        let world = World()
        let camera = FakeOnvifCamera.Transport()
        let transport = RecordingCamera(camera)
        let ptz = world.ptz(transport)
        #expect(ptz.opticalZoom("garden") == .unknown)
        ptz.probeZoom("garden")
        ptz.probeZoom("garden")
        await ptz.idle()
        #expect(transport.requests.map(\.operation) == ["GetSystemDateAndTime", "GetNodes", "GetStatus"])
        #expect(ptz.opticalZoom("garden") == OpticalZoom(available: true, level: 0))
        #expect(ptz.opticalZoom("garden").atWidest)

        // The lens zooms in (the fake's lens is fast): the next read finds it at its closest
        ptz.move("garden", .zoomIn)
        ptz.stop("garden")
        ptz.refreshZoom("garden")
        await ptz.idle()
        #expect(transport.last.operation == "GetStatus")
        #expect(ptz.opticalZoom("garden").atClosest)
        // Probed once
        #expect(transport.requests.filter { $0.operation == "GetNodes" }.count == 1)
        #expect(world.failures.isEmpty)
    }

    @Test func aPanAndTiltCameraHasNoOpticalZoomAndNeverAsksWhereItsLensIs() async {
        let world = World()
        let transport = RecordingCamera(FakeOnvifCamera.Transport(opticalZoom: false))
        let ptz = world.ptz(transport)
        ptz.probeZoom("garden")
        await ptz.idle()
        #expect(ptz.opticalZoom("garden") == .none)
        ptz.refreshZoom("garden")
        await ptz.idle()
        #expect(!transport.requests.contains { $0.operation == "GetStatus" })
    }

    @Test func aCameraRefusingGetNodesKeepsTheLensButtonsQuietlyAndIsAskedAgainNextTime() async {
        let world = World()
        let camera = FakeOnvifCamera.Transport()
        let transport = RecordingCamera(camera) { request in
            request.operation == "GetNodes" ? LanResponse(status: 500) : try await camera.send(request)
        }
        let ptz = world.ptz(transport)
        ptz.probeZoom("garden")
        await ptz.idle()
        #expect(ptz.opticalZoom("garden") == .unknown)
        #expect(world.failures.isEmpty)
        ptz.probeZoom("garden")
        await ptz.idle()
        #expect(transport.requests.filter { $0.operation == "GetNodes" }.count == 2)
        ptz.reset()
        #expect(ptz.opticalZoom("garden") == .unknown)
    }

    @Test func theDirectionsVelocitiesAndTheZoomEnds() {
        #expect(PtzDirection.left.velocity == PtzVelocity(pan: -0.5))
        #expect(PtzDirection.down.velocity == PtzVelocity(tilt: -0.5))
        #expect(PtzDirection.zoomOut.velocity == PtzVelocity(zoom: -0.5))
        #expect(OpticalZoom(available: true, level: 0.99).atClosest)
        #expect(!OpticalZoom(available: true, level: 0.5).atWidest)
        #expect(!OpticalZoom.unknown.atWidest && !OpticalZoom.unknown.atClosest)
        #expect(PtzZoomSupport(optical: true, min: 0, max: 10).normalized(2.5) == 0.25)
        #expect(PtzZoomSupport(optical: true, min: 1, max: 1).normalized(2) == 0)
    }
}
