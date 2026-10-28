import Foundation

/// Reads the answers of cameras (namespace-tolerant, `SoapXML`); each throws `OnvifError` when the answer is not usable
public enum OnvifParser {
    private static let mediaNamespace = "http://www.onvif.org/ver10/media/wsdl"
    private static let ptzNamespace = "http://www.onvif.org/ver20/ptz/wsdl"
    private static let eventsNamespace = "http://www.onvif.org/ver10/events/wsdl"

    /// Fault subcodes and reasons that mean the user name or password is wrong (ONVIF Core 5.11.2.1, and what cameras send)
    private static let authSubcodes: Set<String> = ["NotAuthorized", "FailedAuthentication", "InvalidSecurity", "FailedCheck"]
    private static let authReasons = ["not authorized", "not authorised", "unauthorized", "authentication", "authority failure"]

    /// The SOAP fault in `xml`, or nil. SOAP 1.2 (`Code/Value`, `Subcode/Value`, `Reason/Text`) and SOAP 1.1 (`faultcode`,
    /// `faultstring`); an authentication fault is `.unauthorized`.
    public static func fault(_ xml: SoapElement) -> OnvifError? {
        guard let fault = xml.name == "Fault" ? xml : xml.descendant("Fault") else { return nil }
        let code = fault.path("Code", "Value")?.text ?? fault.child("faultcode")?.text
        let subcode = fault.path("Code", "Subcode", "Value")?.text
        let reason = fault.path("Reason", "Text")?.text ?? fault.child("faultstring")?.text ?? fault.child("Reason")?.text
        let local = { (value: String?) in value.map(SoapElement.local) }
        let authFault = local(subcode).map(authSubcodes.contains) == true || local(code).map(authSubcodes.contains) == true
            || authReasons.contains { reason?.range(of: $0, options: .caseInsensitive) != nil }
        if authFault { return .unauthorized }
        return .fault(code: code, subcode: subcode, reason: (reason?.isEmpty ?? true) ? nil : reason)
    }

    /// GetSystemDateAndTime: the camera's UTC clock, or nil when it sent none
    public static func systemDateAndTime(_ xml: SoapElement) -> Date? {
        guard let utc = xml.descendant("UTCDateTime") else { return nil }
        let number = { (names: [String]) -> Int? in
            names.reduce(utc as SoapElement?) { $0?.child($1) }.flatMap { Int($0.text) }
        }
        guard let year = number(["Date", "Year"]) else { return nil }
        var components = DateComponents()
        components.year = year
        components.month = number(["Date", "Month"]) ?? 1
        components.day = number(["Date", "Day"]) ?? 1
        components.hour = number(["Time", "Hour"]) ?? 0
        components.minute = number(["Time", "Minute"]) ?? 0
        components.second = number(["Time", "Second"]) ?? 0
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        guard components.isValidDate(in: calendar) else { return nil }
        return calendar.date(from: components)
    }

    /// GetEndpointReference: the device's GUID (its WS-Discovery endpoint reference), or nil
    public static func endpointReference(_ xml: SoapElement) -> String? {
        guard let guid = xml.descendant("GetEndpointReferenceResponse")?.descendant("GUID")?.text, !guid.isEmpty else { return nil }
        return guid
    }

    /// GetDeviceInformation; missing fields are empty
    public static func deviceInformation(_ xml: SoapElement) throws -> OnvifDeviceInformation {
        guard let response = xml.descendant("GetDeviceInformationResponse") else { throw OnvifError.invalidResponse("GetDeviceInformationResponse") }
        let field = { (name: String) in response.descendant(name)?.text ?? "" }
        return OnvifDeviceInformation(manufacturer: field("Manufacturer"), model: field("Model"), firmwareVersion: field("FirmwareVersion"),
                                      serialNumber: field("SerialNumber"), hardwareId: field("HardwareId"))
    }

    /// GetCapabilities: the Media, PTZ and Events services. Without a Media service, the default path next to the device
    /// service. Service hosts are those of `deviceURL` (`OnvifURLs.onHost`).
    public static func capabilities(_ xml: SoapElement, deviceURL: String) throws -> OnvifEndpoints {
        guard let capabilities = xml.descendant("Capabilities") else { throw OnvifError.invalidResponse("Capabilities") }
        let address = { (category: String) -> String? in
            guard let text = capabilities.descendant(category)?.child("XAddr")?.text, !text.isEmpty else { return nil }
            return text
        }
        return endpoints(deviceURL: deviceURL, media: address("Media"), ptz: address("PTZ"), events: address("Events"))
    }

    /// GetServices: the same services by namespace (cameras that do not answer GetCapabilities)
    public static func services(_ xml: SoapElement, deviceURL: String) throws -> OnvifEndpoints {
        guard let response = xml.descendant("GetServicesResponse") else { throw OnvifError.invalidResponse("GetServicesResponse") }
        var byNamespace: [String: String] = [:]
        for service in response.descendants("Service") {
            let namespace = service.child("Namespace")?.text ?? ""
            if byNamespace[namespace] == nil, let address = service.child("XAddr")?.text { byNamespace[namespace] = address }
        }
        return endpoints(deviceURL: deviceURL, media: byNamespace[mediaNamespace], ptz: byNamespace[ptzNamespace], events: byNamespace[eventsNamespace])
    }

    private static func endpoints(deviceURL: String, media: String?, ptz: String?, events: String?) -> OnvifEndpoints {
        OnvifEndpoints(mediaURL: media.map { OnvifURLs.onHost($0, reference: deviceURL) } ?? OnvifURLs.sibling(deviceURL, "media_service"),
                       ptzURL: ptz.map { OnvifURLs.onHost($0, reference: deviceURL) },
                       eventsURL: events.map { OnvifURLs.onHost($0, reference: deviceURL) })
    }

    /// GetProfiles: every profile with its token, name (the token without one), resolution, encoding and PTZ
    public static func profiles(_ xml: SoapElement) throws -> [OnvifProfile] {
        guard let response = xml.descendant("GetProfilesResponse") else { throw OnvifError.invalidResponse("GetProfilesResponse") }
        return response.children("Profiles").map { profile in
            let token = profile.attribute("token") ?? ""
            let encoder = profile.child("VideoEncoderConfiguration")
            let name = profile.child("Name")?.text ?? ""
            return OnvifProfile(token: token, name: name.isEmpty ? token : name,
                                width: encoder?.path("Resolution", "Width").flatMap { Int($0.text) } ?? 0,
                                height: encoder?.path("Resolution", "Height").flatMap { Int($0.text) } ?? 0,
                                encoding: encoder?.child("Encoding")?.text ?? "",
                                hasPtz: profile.child("PTZConfiguration") != nil)
        }
    }

    private static let zoomSpaces = ["ContinuousZoomVelocitySpace", "AbsoluteZoomPositionSpace", "RelativeZoomTranslationSpace"]

    /// PTZ GetNodes: optical zoom when a node's SupportedPTZSpaces has a zoom space (continuous velocity,
    /// absolute position or relative translation) whose XRange is not empty (pan/tilt-only cameras may list one from 0
    /// to 0). The range of the absolute position space, when listed, scales GetStatus's position.
    public static func ptzZoomSupport(_ xml: SoapElement) throws -> PtzZoomSupport {
        guard let response = xml.descendant("GetNodesResponse") else { throw OnvifError.invalidResponse("GetNodesResponse") }
        for node in response.descendants("PTZNode") {
            guard let spaces = node.child("SupportedPTZSpaces"), zoomSpaces.flatMap({ spaces.children($0) }).contains(where: hasRange) else { continue }
            let absolute = spaces.children("AbsoluteZoomPositionSpace").first(where: hasRange)
            let min = absolute?.path("XRange", "Min").flatMap { Double($0.text) } ?? 0
            let max = absolute?.path("XRange", "Max").flatMap { Double($0.text) } ?? 1
            return max > min ? PtzZoomSupport(optical: true, min: min, max: max) : PtzZoomSupport(optical: true)
        }
        return .none
    }

    /// A space without a readable XRange counts; one whose Min is not below its Max moves nothing
    private static func hasRange(_ space: SoapElement) -> Bool {
        guard let range = space.child("XRange"), let min = range.child("Min").flatMap({ Double($0.text) }),
              let max = range.child("Max").flatMap({ Double($0.text) }) else { return true }
        return max > min
    }

    /// PTZ GetStatus: the zoom position (`PTZStatus/Position/Zoom@x`), or nil when the camera sent none
    public static func ptzZoomPosition(_ xml: SoapElement) throws -> Double? {
        guard let response = xml.descendant("GetStatusResponse") else { throw OnvifError.invalidResponse("GetStatusResponse") }
        return response.descendant("Position")?.child("Zoom")?.attribute("x").flatMap(Double.init)
    }

    /// GetStreamUri / GetSnapshotUri: the `MediaUri/Uri` (entities already decoded by the parser)
    public static func mediaURI(_ xml: SoapElement, response: String) throws -> String {
        guard let answer = xml.descendant(response) else { throw OnvifError.invalidResponse(response) }
        guard let uri = answer.descendant("Uri")?.text, !uri.isEmpty else { throw OnvifError.invalidResponse("Uri") }
        return uri
    }
}

/// URLs that cameras hand out
public enum OnvifURLs {
    /// `url` with the host of `reference`: many cameras report service and stream addresses with an address of another
    /// interface (or 0.0.0.0, or their address before DHCP), while the user reached them at `reference`'s host. The port,
    /// path and query the camera reported are kept.
    public static func onHost(_ url: String, reference: String) -> String {
        guard var target = URLComponents(string: url), let current = target.host, !current.isEmpty,
              let host = URLComponents(string: reference)?.host, !host.isEmpty else { return url }
        if current.caseInsensitiveCompare(host) == .orderedSame { return url }
        target.host = host
        return target.string ?? url
    }

    /// The service `name` next to the device service (`http://cam/onvif/device_service` → `http://cam/onvif/media_service`)
    public static func sibling(_ deviceURL: String, _ name: String) -> String {
        let withoutQuery = deviceURL.split(separator: "?", maxSplits: 1, omittingEmptySubsequences: false).first.map(String.init) ?? deviceURL
        let schemeEnd = (withoutQuery.range(of: "://")?.upperBound).map { withoutQuery.distance(from: withoutQuery.startIndex, to: $0) } ?? 0
        if let slash = withoutQuery.lastIndex(of: "/"), withoutQuery.distance(from: withoutQuery.startIndex, to: slash) >= schemeEnd {
            return String(withoutQuery[...slash]) + name
        }
        return "\(withoutQuery)/\(name)"
    }

    /// The device service of a camera at `host`:`port`
    public static func deviceService(host: String, port: Int) -> String {
        let bracketed = host.contains(":") && !host.hasPrefix("[") ? "[\(host)]" : host
        return port == 80 ? "http://\(bracketed)/onvif/device_service" : "http://\(bracketed):\(port)/onvif/device_service"
    }

    /// The request target of `url` (path and query) for HTTP and Digest
    public static func requestTarget(_ url: String) -> String { LanRequest.requestTarget(url) }
}
