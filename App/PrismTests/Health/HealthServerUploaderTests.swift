//
//  HealthServerUploaderTests.swift
//  PrismTests
//

import Foundation
import Testing
@testable import Prism

/// A token source that never refreshes.
private actor StaticTokens: HealthServerTokenProviding {
    func currentToken() async throws -> String { "hlth_at_app" }
    func refreshedToken(replacing rejected: String) async throws -> String { "hlth_at_app" }
}

/// The gateway's upload token route: one canned answer per call.
private final class FakeUploadRoute: @unchecked Sendable {
    private let lock = NSLock()
    private var answers: [(Int, String)]
    private(set) var requests: [URLRequest] = []

    init(_ answers: [(Int, String)]) { self.answers = answers }

    var http: HealthServerHTTP {
        { request in
            self.lock.lock()
            defer { self.lock.unlock() }
            self.requests.append(request)
            let (status, json) = self.answers.isEmpty ? (500, "{}") : self.answers.removeFirst()
            return (Data(json.utf8), status)
        }
    }
}

private func freshDefaults() -> UserDefaults {
    let name = "HealthServerUploaderTests.\(UUID().uuidString)"
    let defaults = UserDefaults(suiteName: name) ?? .standard
    defaults.removePersistentDomain(forName: name)
    return defaults
}

@Suite("Health server upload")
struct HealthServerUploaderTests {
    private let settings = HealthServerSettings(baseURL: URL(string: "https://health.example.com")!)

    @Test("The first upload binds the iPhone to the member; the same member goes on; another member stops it")
    func memberSwitch() {
        #expect(HealthServerUploadGate.decide(bound: nil, incoming: "m1") == .proceed(bind: true))
        #expect(HealthServerUploadGate.decide(bound: "m1", incoming: "m1") == .proceed(bind: false))
        #expect(HealthServerUploadGate.decide(bound: "m1", incoming: "m2") == .paused(newMember: "m2"))
    }

    @Test("Turn on uploads clears every anchor and pending deletion, and nothing else")
    func clearAnchors() {
        let defaults = freshDefaults()
        let store = HealthServerAnchorStore(defaults: defaults)
        store.setAnchorData(Data([1]), for: "HKQuantityTypeIdentifierStepCount")
        store.setAnchorData(Data([2]), for: "HKQuantityTypeIdentifierStepCount.pendingDeletions")
        store.member = "m1"
        store.lastUpload = Date(timeIntervalSince1970: 1)
        defaults.set("kept", forKey: "OpenHealthSync.anchor.HKQuantityTypeIdentifierStepCount")
        store.clearAnchors()
        #expect(store.anchorData(for: "HKQuantityTypeIdentifierStepCount") == nil)
        #expect(store.anchorData(for: "HKQuantityTypeIdentifierStepCount.pendingDeletions") == nil)
        #expect(store.lastUpload == nil)
        #expect(store.member == "m1")
        #expect(defaults.string(forKey: "OpenHealthSync.anchor.HKQuantityTypeIdentifierStepCount") == "kept")
    }

    @Test("The upload token comes from /app/v1/upload-token with the app's bearer token, and is kept until 5 minutes before it ends")
    func tokenProvider() async throws {
        let start = Date(timeIntervalSince1970: 2_000_000_000)
        let route = FakeUploadRoute([
            (200, #"{"token":"ohs_ut_one","expires_at":"2033-05-18T04:33:20Z","member_id":"m1"}"#),
            (200, #"{"token":"ohs_ut_two","expires_at":"2033-05-18T05:33:20Z","member_id":"m1"}"#),
        ])
        let clock = TestClock(start)
        let tokens = HealthServerUploadTokens(settings: settings, tokens: StaticTokens(), http: route.http, now: { clock.now })
        // 2_000_000_000 s is 2033-05-18T03:33:20Z, so the first token lives one hour.
        #expect(try await tokens.token().token == "ohs_ut_one")
        clock.now = start.addingTimeInterval(30 * 60)
        #expect(try await tokens.token().token == "ohs_ut_one")
        #expect(route.requests.count == 1)
        clock.now = start.addingTimeInterval(56 * 60)
        #expect(try await tokens.token().token == "ohs_ut_two")
        #expect(route.requests.count == 2)
        let request = try #require(route.requests.first)
        #expect(request.url?.absoluteString == "https://health.example.com/app/v1/upload-token")
        #expect(request.httpMethod == "POST")
        #expect(request.value(forHTTPHeaderField: "Authorization") == "Bearer hlth_at_app")
    }

    @Test("The package's token provider refuses a token of another member")
    func providerChecksTheMember() async throws {
        let route = FakeUploadRoute([(200, #"{"token":"ohs_ut_x","expires_at":"2099-01-01T00:00:00Z","member_id":"m2"}"#)])
        let tokens = HealthServerUploadTokens(settings: settings, tokens: StaticTokens(), http: route.http)
        let provider = tokens.provider(for: "m1")
        await #expect(throws: HealthServerUploadError.memberChanged("m2")) { _ = try await provider() }
        #expect(try await tokens.provider(for: "m2")() == "ohs_ut_x")
    }

    @Test("A refused upload token reads as signed out")
    func refused() async throws {
        let route = FakeUploadRoute([(403, #"{"error":"scope"}"#)])
        let tokens = HealthServerUploadTokens(settings: settings, tokens: StaticTokens(), http: route.http)
        await #expect(throws: HealthServerUploadError.signedOut) { _ = try await tokens.token() }
    }

    @Test("Clinical records stay out of the upload")
    func types() {
        let kept = HealthServerUploader.uploadTypeIdentifiers([
            "HKQuantityTypeIdentifierHeartRate", "HKClinicalTypeIdentifierLabResultRecord", "HKWorkoutTypeIdentifier",
        ])
        #expect(kept == ["HKQuantityTypeIdentifierHeartRate", "HKWorkoutTypeIdentifier"])
    }
}

/// A clock the test moves.
private final class TestClock: @unchecked Sendable {
    var now: Date
    init(_ now: Date) { self.now = now }
}
