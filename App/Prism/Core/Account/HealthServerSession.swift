//
//  HealthServerSession.swift
//  Prism
//

import Foundation
import Observation
import Security

/// What the gateway hands back from `/auth/token`, as kept in the Keychain.
nonisolated struct HealthServerTokens: Codable, Equatable, Sendable {
    var accessToken: String
    var refreshToken: String
    var expiresAt: Date
}

nonisolated enum HealthServerError: Error, Equatable, Sendable {
    /// The build has no health server.
    case notConfigured
    /// Nobody is signed in, or the server refused the refresh token.
    case signedOut
    case stateMismatch
    case missingCode
    /// The server or the person refused, with the server's words.
    case refused(String)
    case offline
    case server(Int)
}

/// Sends one request and hands back the bytes and the status. URLSession in
/// the app, a stub in the tests.
typealias HealthServerHTTP = @Sendable (URLRequest) async throws -> (Data, Int)

/// The bearer token of the health server for a request, and a fresh one when
/// the server answered 401.
nonisolated protocol HealthServerTokenProviding: Sendable {
    func currentToken() async throws -> String
    func refreshedToken(replacing rejected: String) async throws -> String
}

// MARK: - The sign in

/// One sign in in flight: the authorize address with PKCE S256 and a state,
/// and the check on the callback. The gateway shows its own sign in page
/// there, with Apple and with Google, then its consent page for the app
/// (health-mcp.org, open question 23).
nonisolated struct HealthServerSignIn: Sendable, Equatable {
    let settings: HealthServerSettings
    let state: String
    let pkce: PKCE

    init(settings: HealthServerSettings, state: String? = nil, pkce: PKCE? = nil) {
        self.settings = settings
        self.state = state ?? PKCE.randomString(length: 32)
        self.pkce = pkce ?? .make()
    }

    var authorizeURL: URL {
        var components = URLComponents(url: settings.url("/auth/authorize"), resolvingAgainstBaseURL: false)
        components?.queryItems = [
            URLQueryItem(name: "response_type", value: "code"),
            URLQueryItem(name: "client_id", value: HealthServerSettings.clientID),
            URLQueryItem(name: "redirect_uri", value: HealthServerSettings.redirectURI),
            URLQueryItem(name: "scope", value: HealthServerSettings.scope),
            URLQueryItem(name: "state", value: state),
            URLQueryItem(name: "code_challenge", value: pkce.challenge),
            URLQueryItem(name: "code_challenge_method", value: "S256"),
        ]
        return components?.url ?? settings.baseURL
    }

    /// The code out of the callback, once it is the app's health server
    /// callback and its state matches.
    func code(from callback: URL) throws -> String {
        guard callback.scheme == ProviderConfig.callbackScheme, callback.host() == HealthServerSettings.callbackHost,
              callback.path() == HealthServerSettings.callbackPath else { throw HealthServerError.missingCode }
        let items = URLComponents(url: callback, resolvingAgainstBaseURL: false)?.queryItems ?? []
        func value(_ name: String) -> String? { items.first { $0.name == name }?.value }
        if let error = value("error") { throw HealthServerError.refused(error) }
        guard value("state") == state else { throw HealthServerError.stateMismatch }
        guard let code = value("code"), !code.isEmpty else { throw HealthServerError.missingCode }
        return code
    }

    /// The form `/auth/token` takes for `code`.
    func tokenForm(code: String) -> [String: String] {
        [
            "grant_type": "authorization_code",
            "code": code,
            "code_verifier": pkce.verifier,
            "client_id": HealthServerSettings.clientID,
            "redirect_uri": HealthServerSettings.redirectURI,
        ]
    }
}

// MARK: - Keychain

nonisolated protocol HealthServerTokenStore: Sendable {
    func load() -> HealthServerTokens?
    func save(_ tokens: HealthServerTokens) throws
    func delete()
}

/// One generic password, this device only, readable after the first unlock
/// so the background upload can use it.
nonisolated struct KeychainHealthServerStore: HealthServerTokenStore {
    var service = "Soma.Prism.health-server"

    private var query: [String: Any] {
        [kSecClass as String: kSecClassGenericPassword,
         kSecAttrService as String: service,
         kSecAttrAccount as String: "tokens"]
    }

    func load() -> HealthServerTokens? {
        var query = query
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: AnyObject?
        guard SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess, let data = result as? Data else { return nil }
        return try? JSONDecoder().decode(HealthServerTokens.self, from: data)
    }

    func save(_ tokens: HealthServerTokens) throws {
        let data = try JSONEncoder().encode(tokens)
        delete()
        var item = query
        item[kSecValueData as String] = data
        item[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        let status = SecItemAdd(item as CFDictionary, nil)
        guard status == errSecSuccess else { throw HealthServerError.server(Int(status)) }
    }

    func delete() {
        SecItemDelete(query as CFDictionary)
    }
}

// MARK: - Tokens

/// The gateway's access and refresh tokens. An access token close to its end
/// is refreshed before use; a 401 asks for one refresh, and two callers that
/// hold the same rejected token share it. A refresh token the server refuses
/// (revoked on the home page, member removed) signs the person out.
actor HealthServerCredentials: HealthServerTokenProviding {
    let settings: HealthServerSettings
    private let store: any HealthServerTokenStore
    private let http: HealthServerHTTP
    private let now: @Sendable () -> Date
    private let onSignedOut: @Sendable () async -> Void
    private var refreshing: Task<HealthServerTokens, any Error>?

    init(
        settings: HealthServerSettings,
        store: any HealthServerTokenStore = KeychainHealthServerStore(),
        http: @escaping HealthServerHTTP = HealthServerTransport.urlSession,
        now: @escaping @Sendable () -> Date = { Date() },
        onSignedOut: @escaping @Sendable () async -> Void = {}
    ) {
        self.settings = settings
        self.store = store
        self.http = http
        self.now = now
        self.onSignedOut = onSignedOut
    }

    var hasTokens: Bool { store.load() != nil }

    func currentToken() async throws -> String {
        guard let tokens = store.load() else { throw HealthServerError.signedOut }
        if tokens.expiresAt.timeIntervalSince(now()) > 30 { return tokens.accessToken }
        return try await refreshedToken(replacing: tokens.accessToken)
    }

    func refreshedToken(replacing rejected: String) async throws -> String {
        // Someone refreshed past this token already: hand over the new one.
        if let tokens = store.load(), tokens.accessToken != rejected, tokens.expiresAt > now() {
            return tokens.accessToken
        }
        let task: Task<HealthServerTokens, any Error>
        if let refreshing {
            task = refreshing
        } else {
            guard let tokens = store.load() else { throw HealthServerError.signedOut }
            let form = ["grant_type": "refresh_token", "refresh_token": tokens.refreshToken, "client_id": HealthServerSettings.clientID]
            let request = Self.formRequest(url: settings.url("/auth/token"), form: form)
            let http = self.http, now = self.now
            task = Task { () async throws -> HealthServerTokens in
                let (data, status) = try await http(request)
                return try Self.tokens(status: status, data: data, now: now())
            }
            refreshing = task
        }
        do {
            let fresh = try await task.value
            refreshing = nil
            try store.save(fresh)
            return fresh.accessToken
        } catch HealthServerError.signedOut {
            refreshing = nil
            store.delete()
            await onSignedOut()
            throw HealthServerError.signedOut
        } catch is URLError {
            refreshing = nil
            throw HealthServerError.offline
        } catch {
            refreshing = nil
            throw error
        }
    }

    /// Trades the code of a sign in for the first tokens.
    func exchange(_ form: [String: String]) async throws {
        let (data, status) = try await http(Self.formRequest(url: settings.url("/auth/token"), form: form))
        try store.save(Self.tokens(status: status, data: data, now: now()))
    }

    /// Revokes the grant at the gateway, best effort, and forgets the tokens.
    /// The device leaves the member's Devices list on the home page.
    func signOut() async {
        if let tokens = store.load() {
            let form = ["token": tokens.refreshToken, "client_id": HealthServerSettings.clientID]
            _ = try? await http(Self.formRequest(url: settings.url("/auth/revoke"), form: form))
        }
        store.delete()
    }

    // MARK: Wire format

    static func formRequest(url: URL, form: [String: String]) -> URLRequest {
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.timeoutInterval = 30
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        var components = URLComponents()
        components.queryItems = form.sorted { $0.key < $1.key }.map { URLQueryItem(name: $0.key, value: $0.value) }
        // A plus sign in a form body is a space: encode it.
        let body = (components.percentEncodedQuery ?? "").replacingOccurrences(of: "+", with: "%2B")
        request.httpBody = Data(body.utf8)
        return request
    }

    /// The tokens of a token answer (RFC 6749 5.1). `invalid_grant` means the
    /// refresh token is gone, so the person is signed out.
    static func tokens(status: Int, data: Data, now: Date) throws -> HealthServerTokens {
        let object = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] ?? [:]
        guard (200..<300).contains(status) else {
            let code = object["error"] as? String ?? ""
            if code == "invalid_grant" || status == 401 { throw HealthServerError.signedOut }
            if (400..<500).contains(status) { throw HealthServerError.refused(code) }
            throw HealthServerError.server(status)
        }
        guard let access = object["access_token"] as? String, let refresh = object["refresh_token"] as? String else {
            throw HealthServerError.server(status)
        }
        let expires = (object["expires_in"] as? Double) ?? (object["expires_in"] as? Int).map(Double.init) ?? 3600
        return HealthServerTokens(accessToken: access, refreshToken: refresh, expiresAt: now.addingTimeInterval(expires))
    }
}

/// Sends a request to the gateway with the bearer token, and on a 401 once
/// more with a refreshed token, as `OHSClient.live` does with Supabase.
nonisolated enum HealthServerTransport {
    static let urlSession: HealthServerHTTP = { request in
        let (data, response) = try await URLSession.shared.data(for: request)
        return (data, (response as? HTTPURLResponse)?.statusCode ?? 0)
    }

    static func send(_ request: URLRequest, tokens: any HealthServerTokenProviding, http: HealthServerHTTP) async throws -> (status: Int, data: Data) {
        var token = try await tokens.currentToken()
        var answer: (status: Int, data: Data) = (0, Data())
        for attempt in 0..<2 {
            var authorized = request
            authorized.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
            let (data, status) = try await http(authorized)
            answer = (status, data)
            guard status == 401, attempt == 0 else { break }
            token = try await tokens.refreshedToken(replacing: token)
        }
        return answer
    }
}

// MARK: - The session

/// The member signed in to the health server on this iPhone, for the Health
/// access page, the wearables and the Apple Health upload.
///
/// The member signs in on the gateway's own page, in the system's web
/// authentication sheet, as the client `prism-ios` with the scopes `upload`
/// and `connect`. The tokens stay in the Keychain. Nothing here reads health
/// data: the gateway gives the app a member's connections and an upload
/// token, never the data itself.
@MainActor
@Observable
final class HealthServerSession {
    static let shared = HealthServerSession()

    nonisolated enum State: Equatable, Sendable {
        case signedOut
        case signingIn
        case signedIn
        case failed(String)
    }

    /// Who the gateway says is signed in, from `GET /app/v1/me`.
    nonisolated struct Member: Codable, Equatable, Sendable {
        var id: String
        var label: String

        private enum CodingKeys: String, CodingKey {
            case id = "member_id"
            case label
        }
    }

    private(set) var state: State = .signedOut
    private(set) var member: Member?

    @ObservationIgnored let settings: HealthServerSettings?
    @ObservationIgnored private(set) var credentials: HealthServerCredentials?
    @ObservationIgnored private let http: HealthServerHTTP
    @ObservationIgnored private let defaults: UserDefaults
    static let memberKey = "HealthServer.member"

    init(
        settings: HealthServerSettings? = .current,
        store: any HealthServerTokenStore = KeychainHealthServerStore(),
        http: @escaping HealthServerHTTP = HealthServerTransport.urlSession,
        defaults: UserDefaults = .standard
    ) {
        self.settings = settings
        self.http = http
        self.defaults = defaults
        if settings != nil, store.load() != nil {
            state = .signedIn
            member = defaults.data(forKey: Self.memberKey).flatMap { try? JSONDecoder().decode(Member.self, from: $0) }
        }
        if let settings {
            credentials = HealthServerCredentials(settings: settings, store: store, http: http, onSignedOut: { [weak self] in
                await self?.didSignOut()
            })
        }
    }

    var isConfigured: Bool { settings != nil }
    var isSignedIn: Bool { state == .signedIn }

    /// Runs the sign in. `authenticate` opens the gateway's page and returns
    /// the callback URL: the system's web authentication session in the app,
    /// a stub in the tests.
    func signIn(authenticate: (URL, String) async throws -> URL) async {
        guard let settings, let credentials else {
            state = .failed(String(localized: "No health server in this build"))
            return
        }
        let attempt = HealthServerSignIn(settings: settings)
        let before = state
        state = .signingIn
        do {
            let callback = try await authenticate(attempt.authorizeURL, ProviderConfig.callbackScheme)
            let code = try attempt.code(from: callback)
            try await credentials.exchange(attempt.tokenForm(code: code))
            state = .signedIn
            await refreshMember()
        } catch {
            if ProviderConnections.isCancellation(error) {
                state = before == .signingIn ? .signedOut : before
            } else {
                state = .failed(Self.message(error))
            }
        }
    }

    /// Reads who is signed in. The member can change on this iPhone when
    /// another member signs in, which is why the upload checks it too.
    func refreshMember() async {
        guard let settings, let credentials, isSignedIn else { return }
        var request = URLRequest(url: settings.url("/app/v1/me"))
        request.timeoutInterval = 30
        do {
            let (status, data) = try await HealthServerTransport.send(request, tokens: credentials, http: http)
            guard (200..<300).contains(status) else {
                if status == 401 { didSignOut() }
                return
            }
            let fresh = try JSONDecoder().decode(Member.self, from: data)
            member = fresh
            defaults.set(try? JSONEncoder().encode(fresh), forKey: Self.memberKey)
        } catch HealthServerError.signedOut {
            didSignOut()
        } catch {
            // Offline: keep the last member shown.
        }
    }

    /// Revokes the grant at the gateway and forgets the tokens and the member.
    func signOut() async {
        await credentials?.signOut()
        didSignOut()
    }

    func didSignOut() {
        state = .signedOut
        member = nil
        defaults.removeObject(forKey: Self.memberKey)
    }

    static func message(_ error: any Error) -> String {
        switch error as? HealthServerError {
        case .offline: String(localized: "You're offline")
        case .stateMismatch: String(localized: "The sign in did not match. Try again.")
        case .refused, .missingCode: String(localized: "The sign in was refused")
        case .signedOut, .server, .notConfigured, nil:
            (error is URLError) ? String(localized: "You're offline") : String(localized: "Could not finish signing in")
        }
    }
}
