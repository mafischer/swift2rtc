import Foundation

// What the ONVIF client reads from a camera

/// GetDeviceInformation; a field the camera leaves out is empty
public struct OnvifDeviceInformation: Equatable, Sendable {
    public var manufacturer: String
    public var model: String
    public var firmwareVersion: String
    public var serialNumber: String
    public var hardwareId: String

    public init(manufacturer: String = "", model: String = "", firmwareVersion: String = "", serialNumber: String = "", hardwareId: String = "") {
        self.manufacturer = manufacturer
        self.model = model
        self.firmwareVersion = firmwareVersion
        self.serialNumber = serialNumber
        self.hardwareId = hardwareId
    }

    /// "Amcrest IP8M-2493E", or nil when the camera named neither
    public var displayName: String? {
        let name = [manufacturer, model].filter { !$0.trimmingCharacters(in: .whitespaces).isEmpty }.joined(separator: " ")
        return name.isEmpty ? nil : name
    }
}

/// The services a camera offers (GetCapabilities, or GetServices on cameras without it)
public struct OnvifEndpoints: Equatable, Sendable {
    public var mediaURL: String
    public var ptzURL: String?
    public var eventsURL: String?

    public init(mediaURL: String, ptzURL: String? = nil, eventsURL: String? = nil) {
        self.mediaURL = mediaURL
        self.ptzURL = ptzURL
        self.eventsURL = eventsURL
    }
}

/// A media profile (GetProfiles): one stream of the camera, e.g. main and sub stream
public struct OnvifProfile: Equatable, Identifiable, Sendable {
    public var token: String
    public var name: String
    public var width: Int
    public var height: Int
    /// H264, H265, JPEG, ... or empty
    public var encoding: String
    /// The profile has a PTZ configuration: ContinuousMove and Stop work with its token
    public var hasPtz: Bool

    public init(token: String, name: String, width: Int = 0, height: Int = 0, encoding: String = "", hasPtz: Bool = false) {
        self.token = token
        self.name = name
        self.width = width
        self.height = height
        self.encoding = encoding
        self.hasPtz = hasPtz
    }

    public var id: String { token }
    /// The profile has a video encoder with a resolution
    public var hasVideo: Bool { width > 0 && height > 0 }
}

/// A WS-Discovery ProbeMatch: a camera on this network
public struct DiscoveredDevice: Equatable, Hashable, Identifiable, Sendable {
    /// The device's endpoint reference (a stable `urn:uuid:`), or its device URL when it sent none
    public var endpoint: String
    public var name: String
    public var hardware: String
    public var host: String
    public var port: Int
    /// The device service (`http://<host>/onvif/device_service`)
    public var deviceURL: String

    public init(endpoint: String, name: String, hardware: String, host: String, port: Int, deviceURL: String) {
        self.endpoint = endpoint
        self.name = name
        self.hardware = hardware
        self.host = host
        self.port = port
        self.deviceURL = deviceURL
    }

    public var id: String { endpoint }
}

/// A pan/tilt/zoom velocity in the generic space, each -1.0 ... 1.0
public struct PtzVelocity: Equatable, Sendable {
    public var pan: Double
    public var tilt: Double
    public var zoom: Double

    public init(pan: Double = 0, tilt: Double = 0, zoom: Double = 0) {
        self.pan = pan
        self.tilt = tilt
        self.zoom = zoom
    }
}

/// PTZ GetNodes: whether the camera zooms optically (a node lists a zoom space whose range is not empty) and the range
/// of its absolute zoom position (GetStatus): 0 ... 1 in the generic space unless the node says otherwise
public struct PtzZoomSupport: Equatable, Sendable {
    /// No optical zoom
    public static let none = Self(optical: false)

    public var optical: Bool
    public var min: Double
    public var max: Double

    public init(optical: Bool, min: Double = 0, max: Double = 1) {
        self.optical = optical
        self.min = min
        self.max = max
    }

    /// A GetStatus zoom position as 0 (widest) ... 1 (closest)
    public func normalized(_ position: Double) -> Double {
        max > min ? Swift.min(1, Swift.max(0, (position - min) / (max - min))) : 0
    }
}
