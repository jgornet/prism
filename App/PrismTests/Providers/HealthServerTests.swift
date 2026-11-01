//
//  HealthServerTests.swift
//  PrismTests
//

import Foundation
import Testing
@testable import Prism

/// A token source with one token before a refresh and another after it.
private actor FakeTokens: HealthServerTokenProviding {
    private(set) var refreshes = 0
    private var token = "hlth_at_first"

    func currentToken() async throws -> String { token }

    func refreshedToken(replacing rejected: String) async throws -> String {
        refreshes += 1
        token = "hlth_at_second"
        return token
    }
}

/// The gateway stand in: the requests it got, and one canned answer each.
private final class FakeGateway: @unchecked Sendable {
    private let lock = NSLock()
    private var answers: [(Int, String)]
    private(set) var requests: [URLRequest] = []

    init(_ answers: [(Int, String)]) { self.answers = answers }

    var http: HealthServerHTTP {
        { request in
            self.lock.lock()
            defer { self.lock.unlock() }
            self.requests.append(request)
            let (status, json) = self.answers.isEmpty ? (404, "{}") : self.answers.removeFirst()
            return (Data(json.utf8), status)
        }
    }
}

private final class MemoryTokenStore: HealthServerTokenStore, @unchecked Sendable {
    var tokens: HealthServerTokens?
    init(_ tokens: HealthServerTokens?) { self.tokens = tokens }
    func load() -> HealthServerTokens? { tokens }
    func save(_ tokens: HealthServerTokens) throws { self.tokens = tokens }
    func delete() { tokens = nil }
}

@Suite("Health server")
struct HealthServerTests {
    private let settings = HealthServerSettings(baseURL: URL(string: "https://health.example.com")!)

    @Test("The address comes from the Info.plist, and an unexpanded or plain http value is no server")
    func settingsResolve() {
        let set = HealthServerSettings.resolve(info: ["HealthServerURL": "https://health.example.com"], environment: [:])
        #expect(set?.url("/app/v1/ohs").absoluteString == "https://health.example.com/app/v1/ohs")
        #expect(HealthServerSettings.resolve(info: ["HealthServerURL": "$(HEALTH_SERVER_URL)"], environment: [:]) == nil)
        #expect(HealthServerSettings.resolve(info: ["HealthServerURL": "http://health.example.com"], environment: [:]) == nil)
        #expect(HealthServerSettings.resolve(info: [:], environment: ["HEALTH_SERVER_URL": "https://dev.example.com"])?.host == "dev.example.com")
    }

    @Test("The sign in asks the gateway as prism-ios, with PKCE S256 and the upload and connect scopes")
    func authorizeURL() throws {
        let attempt = HealthServerSignIn(settings: settings, state: "s1", pkce: PKCE(verifier: "v".padding(toLength: 64, withPad: "v", startingAt: 0)))
        let url = attempt.authorizeURL
        #expect(url.host() == "health.example.com" && url.path() == "/auth/authorize")
        let items = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems ?? []
        func value(_ name: String) -> String? { items.first { $0.name == name }?.value }
        #expect(value("client_id") == "prism-ios")
        #expect(value("redirect_uri") == "soma://oauth/health")
        #expect(value("scope") == "upload connect")
        #expect(value("code_challenge_method") == "S256")
        #expect(value("code_challenge") == PKCE.challenge(for: attempt.pkce.verifier))
        #expect(value("state") == "s1")
        #expect(attempt.tokenForm(code: "c")["code_verifier"] == attempt.pkce.verifier)
        #expect(attempt.tokenForm(code: "c")["redirect_uri"] == "soma://oauth/health")
    }

    @Test("Only the health callback with the same state gives a code")
    func callback() throws {
        let attempt = HealthServerSignIn(settings: settings, state: "s1")
        #expect(try attempt.code(from: try #require(URL(string: "soma://oauth/health?code=abc&state=s1"))) == "abc")
        #expect(throws: HealthServerError.stateMismatch) {
            try attempt.code(from: try #require(URL(string: "soma://oauth/health?code=abc&state=other")))
        }
        #expect(throws: HealthServerError.refused("access_denied")) {
            try attempt.code(from: try #require(URL(string: "soma://oauth/health?error=access_denied&state=s1")))
        }
        #expect(throws: HealthServerError.missingCode) {
            try attempt.code(from: try #require(URL(string: "soma://oauth/ohs?code=abc&state=s1")))
        }
    }

    @Test("The gateway client posts the function's bodies to /app/v1/ohs with the member's bearer token")
    func gatewayBodies() async throws {
        let gateway = FakeGateway([
            (200, #"{"connections":[{"provider":"oura","status":"active","last_sync_at":null}]}"#),
            (200, #"{"url":"https://health.example.com/connect/abc","expires_at":"2026-11-01T10:15:00Z"}"#),
            (200, #"{"data":[]}"#),
        ])
        let client = OHSClient.gatewayClient(settings: settings, tokens: FakeTokens(), http: gateway.http)
        #expect(try await client.connections().map(\.provider) == ["oura"])
        #expect(try await client.connectURL(provider: "oura").host() == "health.example.com")
        #expect(try await client.daily(from: "2026-10-01", to: "2026-10-31").isEmpty)
        let bodies = try gateway.requests.map { try JSONDecoder().decode([String: String].self, from: try #require($0.httpBody)) }
        #expect(bodies == [
            ["action": "connections"],
            ["action": "connect", "provider": "oura"],
            ["action": "daily", "start": "2026-10-01", "end": "2026-10-31"],
        ])
        for request in gateway.requests {
            #expect(request.url?.absoluteString == "https://health.example.com/app/v1/ohs")
            #expect(request.httpMethod == "POST")
            #expect(request.value(forHTTPHeaderField: "Authorization") == "Bearer hlth_at_first")
            #expect(request.value(forHTTPHeaderField: "apikey") == nil)
        }
    }

    @Test("A 401 refreshes once and sends again; a second 401 signs out")
    func refreshOnce() async throws {
        let tokens = FakeTokens()
        let once = FakeGateway([(401, "{}"), (200, #"{"connections":[]}"#)])
        let client = OHSClient.gatewayClient(settings: settings, tokens: tokens, http: once.http)
        #expect(try await client.connections().isEmpty)
        #expect(await tokens.refreshes == 1)
        #expect(once.requests.map { $0.value(forHTTPHeaderField: "Authorization") } == ["Bearer hlth_at_first", "Bearer hlth_at_second"])

        let twice = FakeGateway([(401, "{}"), (401, "{}"), (200, "{}")])
        let refused = OHSClient.gatewayClient(settings: settings, tokens: FakeTokens(), http: twice.http)
        await #expect(throws: OHSError.signedOut) { _ = try await refused.connections() }
        #expect(twice.requests.count == 2)
    }

    @Test("An expired access token is refreshed before use, and a refused refresh forgets the tokens")
    func credentials() async throws {
        let now = Date(timeIntervalSince1970: 1_000_000)
        let store = MemoryTokenStore(HealthServerTokens(accessToken: "hlth_at_old", refreshToken: "hlth_rt_old", expiresAt: now))
        let fresh = FakeGateway([(200, #"{"access_token":"hlth_at_new","refresh_token":"hlth_rt_new","token_type":"Bearer","expires_in":3600}"#)])
        let credentials = HealthServerCredentials(settings: settings, store: store, http: fresh.http, now: { now })
        #expect(try await credentials.currentToken() == "hlth_at_new")
        #expect(store.tokens?.refreshToken == "hlth_rt_new")
        let form = String(decoding: try #require(fresh.requests.first?.httpBody), as: UTF8.self)
        #expect(form.contains("grant_type=refresh_token") && form.contains("refresh_token=hlth_rt_old") && form.contains("client_id=prism-ios"))
        #expect(fresh.requests.first?.url?.path() == "/auth/token")

        let gone = FakeGateway([(400, #"{"error":"invalid_grant"}"#)])
        let revoked = HealthServerCredentials(settings: settings, store: store, http: gone.http, now: { now.addingTimeInterval(7200) })
        await #expect(throws: HealthServerError.signedOut) { _ = try await revoked.currentToken() }
        #expect(store.tokens == nil)
    }

    @Test("With a health server, only the four providers it has apps for connect through it")
    func providers() {
        let through = DataProvider.all.filter { $0.connectsThroughOHS(healthServer: true) }.map(\.id).sorted()
        #expect(through == ["oura", "strava", "whoop", "withings"])
        #expect(DataProvider.all.filter { $0.connectsThroughOHS(healthServer: false) }.count > through.count)
        #expect(!DataProvider.appleHealth.connectsThroughOHS(healthServer: true))
    }
}
