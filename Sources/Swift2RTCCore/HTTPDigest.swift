import CryptoKit
import Foundation
import Security

/// HTTP Digest authentication (RFC 7616, MD5 and MD5-sess, qop `auth` or none). Many cameras (Amcrest/Dahua among them)
/// answer ONVIF calls with `401` and a Digest challenge instead of checking the WS-Security header, and RTSP DESCRIBE
/// asks for it too: the client then sends the request again with an `Authorization` header.
public enum HTTPDigest {
    /// A `WWW-Authenticate: Digest ...` challenge
    public struct Challenge: Equatable, Sendable {
        public var realm: String
        public var nonce: String
        /// `auth` when the server offered it, else nil (no qop)
        public var qop: String?
        public var opaque: String?
        /// `MD5` or `MD5-sess`
        public var algorithm: String

        public init(realm: String, nonce: String, qop: String? = nil, opaque: String? = nil, algorithm: String = "MD5") {
            self.realm = realm
            self.nonce = nonce
            self.qop = qop
            self.opaque = opaque
            self.algorithm = algorithm
        }
    }

    /// The Digest challenge in a `WWW-Authenticate` value, or nil (Basic, or a Digest without realm or nonce)
    public static func parseChallenge(_ header: String?) -> Challenge? {
        guard let header else { return nil }
        let trimmed = header.trimmingCharacters(in: .whitespaces)
        guard trimmed.lowercased().hasPrefix("digest") else { return nil }
        let params = parameters(String(trimmed.dropFirst("Digest".count)))
        guard let realm = params["realm"], let nonce = params["nonce"] else { return nil }
        // "auth" when offered (possibly next to auth-int, which these clients do not need)
        let qop = params["qop"].flatMap { options in options.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }.contains("auth") ? "auth" : nil }
        return Challenge(realm: realm, nonce: nonce, qop: qop, opaque: params["opaque"], algorithm: params["algorithm"] ?? "MD5")
    }

    /// Comma-separated `name=value` / `name="quoted, value"` pairs, names lower-cased
    public static func parameters(_ text: String) -> [String: String] {
        var result: [String: String] = [:]
        let chars = Array(text)
        var index = 0
        while index < chars.count {
            while index < chars.count, chars[index] == "," || chars[index].isWhitespace { index += 1 }
            guard let equals = chars[index...].firstIndex(of: "=") else { break }
            let name = String(chars[index..<equals]).trimmingCharacters(in: .whitespaces).lowercased()
            index = equals + 1
            var value = ""
            if index < chars.count, chars[index] == "\"" {
                index += 1
                while index < chars.count, chars[index] != "\"" {
                    if chars[index] == "\\", index + 1 < chars.count { index += 1 }
                    value.append(chars[index])
                    index += 1
                }
                index += 1
            } else {
                let end = chars[index...].firstIndex(of: ",") ?? chars.count
                value = String(chars[index..<end]).trimmingCharacters(in: .whitespaces)
                index = end
            }
            if !name.isEmpty { result[name] = value }
        }
        return result
    }

    /// The `Authorization` value answering `challenge` for `method` on `uri` (the request target, or the RTSP URL)
    public static func authorization(_ challenge: Challenge, credentials: OnvifCredentials, method: String, uri: String, cnonce: String, nonceCount: Int = 1) -> String {
        let nc = String(format: "%08x", nonceCount)
        var ha1 = md5("\(credentials.username):\(challenge.realm):\(credentials.password)")
        if challenge.algorithm.caseInsensitiveCompare("MD5-sess") == .orderedSame { ha1 = md5("\(ha1):\(challenge.nonce):\(cnonce)") }
        let ha2 = md5("\(method):\(uri)")
        let response = challenge.qop.map { md5("\(ha1):\(challenge.nonce):\(nc):\(cnonce):\($0):\(ha2)") } ?? md5("\(ha1):\(challenge.nonce):\(ha2)")
        var header = "Digest username=\"\(quote(credentials.username))\", realm=\"\(quote(challenge.realm))\", nonce=\"\(quote(challenge.nonce))\""
        header += ", uri=\"\(quote(uri))\""
        if let qop = challenge.qop { header += ", qop=\(qop), nc=\(nc), cnonce=\"\(cnonce)\"" }
        header += ", response=\"\(response)\""
        if let opaque = challenge.opaque { header += ", opaque=\"\(quote(opaque))\"" }
        header += ", algorithm=\(challenge.algorithm)"
        return header
    }

    /// `Authorization: Basic ...` (RTSP cameras that ask for Basic; never for plain HTTP ONVIF)
    public static func basic(_ credentials: OnvifCredentials) -> String {
        "Basic " + Data("\(credentials.username):\(credentials.password)".utf8).base64EncodedString()
    }

    /// A client nonce: 16 random bytes in hex
    public static func cnonce() -> String {
        var bytes = [UInt8](repeating: 0, count: 16)
        _ = SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes)
        return bytes.map { String(format: "%02x", $0) }.joined()
    }

    private static func quote(_ value: String) -> String {
        value.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"")
    }

    /// MD5 of the UTF-8 text in lower-case hex (Digest's hash; not for anything else)
    public static func md5(_ text: String) -> String {
        Insecure.MD5.hash(data: Data(text.utf8)).map { String(format: "%02x", $0) }.joined()
    }
}
