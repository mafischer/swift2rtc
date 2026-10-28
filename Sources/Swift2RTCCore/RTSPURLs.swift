import Foundation

/// Camera URLs with credentials and hosts: RTSP (and ONVIF device) URLs keep the login out of storage; it is added in
/// memory for playback only, and a checked address replaces the host so nothing is looked up twice
public enum RTSPURLs {
    /// The URL without its user info, and the credentials it carried (percent-decoded), if any
    public static func split(_ url: String) -> (String, OnvifCredentials?) {
        guard let schemeEnd = url.range(of: "://") else { return (url, nil) }
        let afterScheme = url[schemeEnd.upperBound...]
        let authorityEnd = afterScheme.firstIndex(where: { $0 == "/" || $0 == "?" || $0 == "#" }) ?? afterScheme.endIndex
        let authority = afterScheme[..<authorityEnd]
        guard let at = authority.lastIndex(of: "@") else { return (url, nil) }
        let userInfo = String(authority[..<at])
        let stripped = String(url[..<schemeEnd.upperBound]) + String(afterScheme[afterScheme.index(after: at)...])
        let user: String
        let password: String
        if let colon = userInfo.firstIndex(of: ":") {
            user = decode(String(userInfo[..<colon]))
            password = decode(String(userInfo[userInfo.index(after: colon)...]))
        } else {
            user = decode(userInfo)
            password = ""
        }
        return (stripped, user.isEmpty ? nil : OnvifCredentials(username: user, password: password))
    }

    /// `url` with `credentials` as percent-encoded user info (the RTSP client decodes it for Digest/Basic); as is without
    public static func withCredentials(_ url: String, _ credentials: OnvifCredentials?) -> String {
        guard let credentials, !credentials.username.isEmpty else { return url }
        let (bare, _) = split(url)
        guard let schemeEnd = bare.range(of: "://") else { return bare }
        return String(bare[..<schemeEnd.upperBound]) + encode(credentials.username) + ":" + encode(credentials.password) + "@" + String(bare[schemeEnd.upperBound...])
    }

    /// `url` with `address` as its host (user info, port, path and query kept): played without a second lookup
    public static func withHost(_ url: String, _ address: InetAddress) -> String {
        guard let schemeEnd = url.range(of: "://") else { return url }
        let afterScheme = url[schemeEnd.upperBound...]
        let authorityEnd = afterScheme.firstIndex(where: { $0 == "/" || $0 == "?" || $0 == "#" }) ?? afterScheme.endIndex
        let authority = afterScheme[..<authorityEnd]
        let userInfo = authority.lastIndex(of: "@").map { String(authority[...$0]) } ?? ""
        let hostPort = authority.lastIndex(of: "@").map { String(authority[authority.index(after: $0)...]) } ?? String(authority)
        var port = ""
        if hostPort.hasPrefix("[") {
            guard let close = hostPort.firstIndex(of: "]") else { return url }
            port = String(hostPort[hostPort.index(after: close)...])
        } else if let colon = hostPort.lastIndex(of: ":") {
            port = String(hostPort[colon...])
        }
        return String(url[..<schemeEnd.upperBound]) + userInfo + address.urlHost + port + String(afterScheme[authorityEnd...])
    }

    /// For logs: the URL without user info, query or fragment
    public static func redacted(_ url: String) -> String {
        let (bare, _) = split(url)
        return String(bare.prefix { $0 != "?" && $0 != "#" })
    }

    private static let userInfoAllowed: CharacterSet = {
        var set = CharacterSet.alphanumerics
        set.insert(charactersIn: "-._~")
        return set
    }()

    private static func encode(_ value: String) -> String { value.addingPercentEncoding(withAllowedCharacters: userInfoAllowed) ?? value }
    private static func decode(_ value: String) -> String { value.removingPercentEncoding ?? value }
}
