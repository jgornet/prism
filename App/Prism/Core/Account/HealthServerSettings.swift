//
//  HealthServerSettings.swift
//  Prism
//

import Foundation

/// The health server of this build, read at runtime: the gateway in front of
/// Open Health Sync, at `health.jamesgornet.com` in the owner's build.
///
/// The value comes from the Info.plist key `HealthServerURL`, which
/// `Prism-Info.plist` fills from the build setting `HEALTH_SERVER_URL` in
/// `Config/HealthServer.xcconfig`. A development run can pass the same name as
/// a scheme environment variable instead. Without it there is no health
/// server, and the wearables go through the account's `ohs` function as in
/// Soma's own build.
nonisolated struct HealthServerSettings: Equatable, Sendable {
    var baseURL: URL

    static let infoKey = "HealthServerURL"
    static let environmentKey = "HEALTH_SERVER_URL"
    /// The client of this app at the gateway: a public client with PKCE.
    static let clientID = "prism-ios"
    /// Where the gateway sends the browser back after the sign in.
    static let redirectURI = "soma://oauth/health"
    static let callbackHost = "oauth"
    static let callbackPath = "/health"
    /// What the app asks for: device uploads and the connect pages. The read
    /// scope belongs to the assistants, not to the app.
    static let scope = "upload connect"
    /// The wearables the first release of the health server connects
    /// (health-mcp.org, open question 26).
    static let providerSlugs: Set<String> = ["oura", "withings", "strava", "whoop"]

    /// This build's health server, or nil when it was built without one.
    static var current: HealthServerSettings? {
        resolve(info: Bundle.main.infoDictionary ?? [:], environment: ProcessInfo.processInfo.environment)
    }

    /// Info.plist first, then the environment. A value still holding an
    /// unexpanded build setting counts as absent, and so does an address that
    /// is not https.
    static func resolve(info: [String: Any], environment: [String: String]) -> HealthServerSettings? {
        func clean(_ value: Any?) -> String? {
            guard let text = (value as? String)?.trimmingCharacters(in: .whitespacesAndNewlines),
                  !text.isEmpty, !text.contains("$(") else { return nil }
            return text
        }
        guard let address = clean(info[infoKey]) ?? clean(environment[environmentKey]),
              let url = URL(string: address), url.scheme == "https", url.host() != nil
        else { return nil }
        return HealthServerSettings(baseURL: url)
    }

    /// The server's address with a path of the gateway, such as `/auth/token`.
    func url(_ path: String) -> URL {
        var text = baseURL.absoluteString
        while text.hasSuffix("/") { text.removeLast() }
        return URL(string: text + path) ?? baseURL
    }

    /// The host the Health access page shows.
    var host: String { baseURL.host() ?? baseURL.absoluteString }
}
