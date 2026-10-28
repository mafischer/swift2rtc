# Swift2RTCTapo (planned)

Not implemented yet. This target only reserves the module name; it is not a product of the package.

## What it will do

Talk to a TP-Link Tapo camera's speaker (an audio backchannel) over Tapo's private streaming protocol, the way
[go2rtc](https://github.com/AlexxIT/go2rtc) (`pkg/tapo`) and [pytapo](https://github.com/JurajNyiri/pytapo) do. Tapo
cameras do not offer ONVIF Profile T's RTSP backchannel, so the ONVIF/RTSP route used for other cameras does not work
for their speaker.

## Planned design

- **Transport:** HTTP on the camera's port **8800** (not the RTSP port 554), one long-lived connection carrying
  multipart parts in both directions.
- **Authentication:** HTTP Digest (the same `HTTPDigest` as the rest of the package), where the password is not the
  password as typed but its hash as TP-Link's apps derive it (MD5 or SHA-256 in upper-case hex, depending on what the
  firmware's challenge asks for). The user name is `admin`.
- **Talk session:** after authentication the client asks the camera, in a JSON request part, to open a talk session
  (two-way audio), then sends audio parts tagged with that session.
- **Audio:** G.711 A-law (PCMA), 8 kHz mono, packed in **MPEG-TS** inside the multipart parts.
- **Camera setting:** the camera accepts these sessions from a local client only when **"Third-Party Compatibility"**
  is on in the Tapo app (under Tapo Lab; the menu differs between app versions). The RTSP/ONVIF side additionally
  needs a camera account created in the Tapo app (Advanced Settings > Camera Account).

The kotlin2rtc sibling project (`kotlin2rtc-tapo`) is planned the same way; both should agree on the wire.

## Acknowledgements

go2rtc (Copyright (c) 2022 Alexey Khit) and pytapo (Copyright (c) 2020 Juraj Nyíri) are MIT-licensed protocol
references; their licences are in [THIRD-PARTY-NOTICES.md](../../THIRD-PARTY-NOTICES.md).
