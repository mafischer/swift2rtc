# swift2rtc

Talk to IP cameras from Swift: find them with WS-Discovery, read and control them over ONVIF (device information,
profiles, stream and snapshot URIs, PTZ), and play their RTSP streams with Apple's own decoders (VideoToolbox for
H.264/H.265, AVAudioEngine for G.711 and AAC). No dependencies beyond Apple's frameworks.

It is extracted from the iOS app of [Baby Zzz](https://babyzzz.app), a baby monitor that also shows ONVIF cameras, and
is the Swift sibling of [kotlin2rtc](https://github.com/mafischer/kotlin2rtc), which carries the same protocol code for
the JVM and Android. The name nods to [go2rtc](https://github.com/AlexxIT/go2rtc).

**Status: pre-1.0.** The public API may still change between minor versions.

## Products

| Product | What it holds |
|---------|---------------|
| `Swift2RTCCore` | HTTP Digest (RFC 7616: MD5, MD5-sess, qop `auth`), the namespace-tolerant SOAP/XML reader (`SoapXML`, no DTDs), the `LanHTTPTransport` protocol with its Network.framework default `SocketLanTransport` (plain HTTP only to addresses you allow), `InetAddress` / `LinkSubnet` / `LocalNetwork` (which addresses count as local or private), `RTSPURLs` (credentials and hosts in camera URLs), the `Swift2RTCLogger` protocol (no-op by default), `OnvifCredentials` and `OnvifError` |
| `Swift2RTCOnvif` | WS-Discovery (`WSDiscovery`, `WSDiscoveryMessages`), `OnvifClient` (WS-Security UsernameToken with the camera's clock, Digest fallback, GetCapabilities/GetServices, profiles, stream and snapshot URIs, PTZ ContinuousMove/Stop/GetNodes/GetStatus), `OnvifSoap` and `OnvifParser`, `PTZController` (ordered per-camera commands, optical zoom probe), `NetworkCameraProbe` and `CameraIdentity` (is the device at this address the camera, before any login goes to it) |
| `Swift2RTCRTSP` | `RTSPSession` (RFC 2326 over TCP with interleaved RTP, Digest or Basic, keep-alive, media timeout), `SDP`, `RTPPacket`, H.264/H.265 depacketization (`VideoDepacketizer`), AAC (RFC 3640) and G.711, `VideoDecoder` (VideoToolbox, NV12 output), `AudioPlayback`, and `RTSPPlayer`, which ties them together and hands you decoded `CVPixelBuffer`s |

`Swift2RTCOnvif` and `Swift2RTCRTSP` re-export `Swift2RTCCore`. A fourth target, `Swift2RTCTapo`, is a placeholder
for the planned Tapo backchannel (see below).

Platforms: iOS 17 and macOS 14 or later. Swift 6.2 or later (Swift 6 language mode, strict concurrency).

## Supported protocols and cameras

- **ONVIF Profile S** device and media services (media1), PTZ service. Tested with answers captured from an Amcrest
  IP8M-2493E (Dahua firmware) and a DoorBird D101S, plus hand-written answers in other vendors' styles. Cameras that only answer GetServices (no GetCapabilities) are handled, as are cameras that check HTTP Digest
  instead of (or in addition to) the WS-Security header, and cameras that report service addresses on another
  interface (the address you reached them at is used instead).
- **WS-Discovery** Probe for `NetworkVideoTransmitter`, multicast or unicast.
- **RTSP** 1.0 over TCP (RTP interleaved), video **H.264** and **H.265**, audio **G.711 µ-law/A-law** and **AAC**
  (`mpeg4-generic`, AAC-hbr). No UDP transport, no RTSPS, no MJPEG.
- **Not yet:** the ONVIF Profile T **audio backchannel** (talking to the camera's speaker over RTSP). kotlin2rtc has it
  (taken from the Android app); a Swift port is planned. The **Tapo** private protocol backchannel is planned for both
  (see [Sources/Swift2RTCTapo/README.md](Sources/Swift2RTCTapo/README.md)).

### Notes for iOS apps

- ONVIF is plain `http://`. `SocketLanTransport` uses Network.framework TCP, which App Transport Security does not
  cover, so the app keeps ATS on for everything else. Give it an `allows` closure that accepts only local addresses
  (`LocalNetwork.allowsCamera` accepts the device's own subnets and private ranges, never the internet).
- Discovery and local connections need `NSLocalNetworkUsageDescription`; multicast WS-Discovery on a device also needs
  the `com.apple.developer.networking.multicast` entitlement (granted by Apple on request). Without it `discover`
  throws `DiscoveryError.multicastNotPermitted`; unicast probes (`NetworkCameraProbe`) do not need it.
- Configure the `AVAudioSession` before playing a stream with sound.

## Installation

Swift Package Manager, in `Package.swift`:

```swift
dependencies: [
    .package(url: "https://github.com/mafischer/swift2rtc.git", from: "0.1.0"),
],
targets: [
    .target(name: "MyApp", dependencies: [
        .product(name: "Swift2RTCOnvif", package: "swift2rtc"),
        .product(name: "Swift2RTCRTSP", package: "swift2rtc"),
    ]),
]
```

In Xcode: File > Add Package Dependencies... and enter `https://github.com/mafischer/swift2rtc.git`.

## Quick start

### Find cameras

```swift
import Swift2RTCOnvif

let network = LocalNetwork()   // @MainActor; network.start() follows the current Wi-Fi
network.start()
let discovery = WSDiscovery(accept: { network.allowsFromAnyThread($0) })
let cameras = try await discovery.discover(timeout: WSDiscovery.defaultTimeout)
for camera in cameras { print(camera.name, camera.hardware, camera.deviceURL) }
```

### Read a camera over ONVIF

```swift
import Swift2RTCOnvif

let transport = SocketLanTransport(allows: { $0.isPrivate })
let credentials = OnvifCredentials(username: "admin", password: "camera-password")
let client = OnvifClient(transport: transport, deviceURL: "http://192.168.1.64/onvif/device_service", credentials: credentials)

try await client.syncClock()                         // the camera's clock for the WS-Security timestamp
let info = try await client.deviceInformation()      // manufacturer, model, firmware
let endpoints = try await client.endpoints()         // media, PTZ, events services
let profiles = try await client.profiles(mediaURL: endpoints.mediaURL)
let main = profiles.first { $0.hasVideo }!
let stream = try await client.streamURI(mediaURL: endpoints.mediaURL, profileToken: main.token)
```

Errors are `OnvifError`: `.unreachable`, `.notLocal`, `.unauthorized`, `.fault(code:subcode:reason:)`, `.http(status)`,
`.invalidResponse`.

### Play the stream

```swift
import Swift2RTCRTSP

// The login goes into the URL in memory only; it is never sent in a request line or logged
let url = RTSPURLs.withCredentials(stream, credentials)
let player = RTSPPlayer(url: url) { pixelBuffer in
    // NV12 CVPixelBuffer on VideoToolbox's thread: draw it with Metal, an AVSampleBufferDisplayLayer, or a WebRTC source
}
player.onEvent = { event in
    switch event {
    case .playing: print("first picture")
    case .failed(let reason): print("stopped:", reason)   // .unreachable, .unauthorized, .other
    }
}
player.isAudioMuted = true
// later
let thumbnail = player.stillJPEG()   // the last non-black picture, at most 640 px wide
player.close()
```

For lower-level use, `RTSPSession` gives you the RTP packets and `VideoDepacketizer` / `VideoDecoder` /
`AudioPlayback` decode them.

### Pan, tilt and zoom

```swift
let ptz = PTZController(transport: transport, target: { id in
    PTZTarget(deviceURL: client.deviceURL, ptzURL: endpoints.ptzURL, profileToken: main.token, credentials: credentials)
}, onCommandFailed: { id, error in print("PTZ refused:", error?.logDescription ?? "error") })
ptz.move("nursery", .left)   // until stop
ptz.stop("nursery")
ptz.probeZoom("nursery")     // then ptz.opticalZoom("nursery")
```

### Logging

The library logs a few diagnostic lines (kinds only: never credentials or full URLs) through `Swift2RTCLogger`, a
no-op by default:

```swift
import os

struct OSLogger: Swift2RTCLogger {
    let logger = os.Logger(subsystem: "com.example.app", category: "cameras")
    func log(_ level: LogLevel, _ message: String) { logger.log("\(message, privacy: .public)") }
}
let player = RTSPPlayer(url: url, logger: OSLogger()) { _ in }
```

## Running the tests

```sh
swift build
swift test
```

The tests (Swift Testing) run on macOS without any camera or network: ONVIF answers captured from real cameras
(`Tests/Swift2RTCTests/Fixtures/onvif`, shared with kotlin2rtc; addresses and identifiers replaced), an in-process fake
ONVIF camera, a fake RTSP camera on 127.0.0.1 that streams an H.264 test pattern encoded with VideoToolbox, and UDP
and HTTP responders on the loopback interface.

## Acknowledgements

- [go2rtc](https://github.com/AlexxIT/go2rtc) (MIT, Copyright (c) 2022 Alexey Khit) and
  [pytapo](https://github.com/JurajNyiri/pytapo) (MIT, Copyright (c) 2020 Juraj Nyíri) are the protocol references
  for the planned Tapo module; see [THIRD-PARTY-NOTICES.md](THIRD-PARTY-NOTICES.md).
- The WS-Security password digest is checked against the example in the ONVIF Application Programmer's Guide, and HTTP
  Digest against RFC 2617's example.

## License

[ISC](LICENSE), Copyright (c) 2026 Michael Fischer.
