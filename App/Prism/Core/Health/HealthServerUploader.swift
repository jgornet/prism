//
//  HealthServerUploader.swift
//  Prism
//

import Foundation
import Observation
import OpenHealthSync
#if canImport(HealthKit)
import HealthKit
import OpenHealthSyncHealthKit
#endif
#if os(iOS) || os(visionOS)
import BackgroundTasks
#endif

/// The answer of `POST /app/v1/upload-token`: an Open Health Sync user token
/// with the `upload` scope, for the member of the app's grant.
nonisolated struct HealthServerUploadToken: Decodable, Equatable, Sendable {
    var token: String
    var expiresAt: Date
    var memberID: String

    private enum CodingKeys: String, CodingKey {
        case token
        case expiresAt = "expires_at"
        case memberID = "member_id"
    }

    init(token: String, expiresAt: Date, memberID: String) {
        self.token = token
        self.expiresAt = expiresAt
        self.memberID = memberID
    }

    init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        token = try container.decode(String.self, forKey: .token)
        memberID = try container.decode(String.self, forKey: .memberID)
        let text = try container.decode(String.self, forKey: .expiresAt)
        guard let date = (try? Date(text, strategy: Date.ISO8601FormatStyle(includingFractionalSeconds: true)))
            ?? (try? Date(text, strategy: Date.ISO8601FormatStyle())) else {
            throw DecodingError.dataCorruptedError(forKey: .expiresAt, in: container, debugDescription: "not RFC 3339")
        }
        expiresAt = date
    }
}

nonisolated enum HealthServerUploadError: Error, Equatable, Sendable {
    /// The token is for another member than the one the anchors belong to.
    case memberChanged(String)
    case signedOut
    case offline
    case server(Int)
}

/// Whose user gets the Apple Health of this iPhone (health-mcp.org, open
/// question 27). The anchors belong to one member: the first upload binds
/// them, and a token of another member stops the uploads until that member
/// turns them on, which clears the anchors and sends the whole history.
nonisolated enum HealthServerUploadGate {
    nonisolated enum Decision: Equatable, Sendable {
        /// Upload. `bind` is true for the first upload of this iPhone.
        case proceed(bind: Bool)
        /// Another member is signed in: stop, and ask.
        case paused(newMember: String)
    }

    static func decide(bound: String?, incoming: String) -> Decision {
        guard let bound else { return .proceed(bind: true) }
        return bound == incoming ? .proceed(bind: false) : .paused(newMember: incoming)
    }
}

/// The query anchors of the health server upload, one per type, with the
/// member they belong to and the last upload. Kept in `UserDefaults` under
/// one prefix, apart from any other anchors of the app.
nonisolated final class HealthServerAnchorStore: AnchorStore, @unchecked Sendable {
    private let defaults: UserDefaults
    static let prefix = "HealthServer.anchor."
    static let memberKey = "HealthServer.upload.member"
    static let lastUploadKey = "HealthServer.upload.last"
    static let lastTypesKey = "HealthServer.upload.types"

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    func anchorData(for typeIdentifier: String) -> Data? {
        defaults.data(forKey: Self.prefix + typeIdentifier)
    }

    func setAnchorData(_ data: Data?, for typeIdentifier: String) {
        if let data {
            defaults.set(data, forKey: Self.prefix + typeIdentifier)
        } else {
            defaults.removeObject(forKey: Self.prefix + typeIdentifier)
        }
    }

    /// The member whose user the anchors describe, or nil before the first
    /// upload.
    var member: String? {
        get { defaults.string(forKey: Self.memberKey) }
        set { defaults.set(newValue, forKey: Self.memberKey) }
    }

    var lastUpload: Date? {
        get { defaults.object(forKey: Self.lastUploadKey) as? Date }
        set { defaults.set(newValue, forKey: Self.lastUploadKey) }
    }

    var lastTypeCount: Int? {
        get { defaults.object(forKey: Self.lastTypesKey) as? Int }
        set { defaults.set(newValue, forKey: Self.lastTypesKey) }
    }

    /// Forgets every anchor and every pending deletion, so the next upload
    /// sends the whole history.
    func clearAnchors() {
        for key in defaults.dictionaryRepresentation().keys where key.hasPrefix(Self.prefix) {
            defaults.removeObject(forKey: key)
        }
        lastUpload = nil
        lastTypeCount = nil
    }
}

/// Upload tokens from the gateway. A token is kept until 5 minutes before it
/// ends, so one upload of many parts asks once.
actor HealthServerUploadTokens {
    private let settings: HealthServerSettings
    private let tokens: any HealthServerTokenProviding
    private let http: HealthServerHTTP
    private let now: @Sendable () -> Date
    private var cached: HealthServerUploadToken?

    init(
        settings: HealthServerSettings,
        tokens: any HealthServerTokenProviding,
        http: @escaping HealthServerHTTP = HealthServerTransport.urlSession,
        now: @escaping @Sendable () -> Date = { Date() }
    ) {
        self.settings = settings
        self.tokens = tokens
        self.http = http
        self.now = now
    }

    func token() async throws -> HealthServerUploadToken {
        if let cached, cached.expiresAt.timeIntervalSince(now()) > 5 * 60 { return cached }
        let answer: (status: Int, data: Data)
        do {
            answer = try await HealthServerTransport.send(Self.request(settings: settings), tokens: tokens, http: http)
        } catch HealthServerError.signedOut {
            throw HealthServerUploadError.signedOut
        } catch HealthServerError.offline {
            throw HealthServerUploadError.offline
        } catch is URLError {
            throw HealthServerUploadError.offline
        }
        switch answer.status {
        case 200..<300: break
        case 401, 403: throw HealthServerUploadError.signedOut
        default: throw HealthServerUploadError.server(answer.status)
        }
        let fresh = try JSONDecoder().decode(HealthServerUploadToken.self, from: answer.data)
        cached = fresh
        return fresh
    }

    func invalidate() { cached = nil }

    static func request(settings: HealthServerSettings) -> URLRequest {
        var request = URLRequest(url: settings.url("/app/v1/upload-token"))
        request.httpMethod = "POST"
        request.timeoutInterval = 30
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = Data("{}".utf8)
        return request
    }

    /// The token provider of the Swift package's client: the upload token of
    /// `member`, and an error when the token is for anyone else, so no part
    /// of one member's Apple Health goes to another's user.
    nonisolated func provider(for member: String) -> TokenProvider {
        { [self] in
            let token = try await self.token()
            guard token.memberID == member else { throw HealthServerUploadError.memberChanged(token.memberID) }
            return token.token
        }
    }
}

/// Uploads this iPhone's Apple Health to the health server, with the Swift
/// package of Open Health Sync at the server's own commit.
///
/// It reads every type the app already has access to, except clinical
/// records, and sends what changed since the last anchor: the whole history
/// the first time. It runs from Upload now on the Health access page, when
/// the app comes forward and in the background task
/// `Soma.Prism.health-server-upload`. Nothing runs without a signed in member.
@MainActor
@Observable
final class HealthServerUploader {
    static let shared = HealthServerUploader()
    static let taskIdentifier = "Soma.Prism.health-server-upload"

    nonisolated enum State: Equatable, Sendable {
        case idle
        case uploading
        /// Another member is signed in, and the anchors belong to the first.
        case paused(newMember: String)
        case failed(String)
    }

    private(set) var state: State = .idle
    private(set) var lastUpload: Date?
    private(set) var lastTypeCount: Int?

    @ObservationIgnored let anchors: HealthServerAnchorStore
    @ObservationIgnored private let session: HealthServerSession
    @ObservationIgnored private var tokens: HealthServerUploadTokens?

    init(anchors: HealthServerAnchorStore = HealthServerAnchorStore(), session: HealthServerSession = .shared) {
        self.anchors = anchors
        self.session = session
        lastUpload = anchors.lastUpload
        lastTypeCount = anchors.lastTypeCount
    }

    var isPaused: Bool {
        if case .paused = state { return true }
        return false
    }

    /// One upload pass. Returns true when it finished.
    @discardableResult
    func uploadNow() async -> Bool {
        guard session.isSignedIn, let settings = session.settings, let credentials = session.credentials else { return false }
        guard state != .uploading, !isPaused else { return false }
        let source = tokens ?? HealthServerUploadTokens(settings: settings, tokens: credentials)
        tokens = source
        state = .uploading
        do {
            let first = try await source.token()
            switch HealthServerUploadGate.decide(bound: anchors.member, incoming: first.memberID) {
            case .paused(let newMember):
                state = .paused(newMember: newMember)
                return false
            case .proceed(let bind):
                if bind { anchors.member = first.memberID }
            }
            let types = try await Self.upload(baseURL: settings.baseURL, provider: source.provider(for: first.memberID), anchors: anchors)
            lastUpload = Date()
            lastTypeCount = types
            anchors.lastUpload = lastUpload
            anchors.lastTypeCount = types
            state = .idle
            return true
        } catch HealthServerUploadError.memberChanged(let newMember) {
            await source.invalidate()
            state = .paused(newMember: newMember)
        } catch HealthServerUploadError.signedOut {
            await source.invalidate()
            state = .failed(String(localized: "Sign in to the health server"))
        } catch HealthServerUploadError.offline {
            state = .failed(String(localized: "You're offline"))
        } catch is URLError {
            state = .failed(String(localized: "You're offline"))
        } catch {
            state = .failed(String(localized: "Couldn't upload. Try again."))
        }
        return false
    }

    /// The member signed in now takes this iPhone's Apple Health: the anchors
    /// of the member before are cleared, so the next upload sends the whole
    /// history to the new member's user.
    func turnOnUploads() async {
        guard case .paused(let newMember) = state else { return }
        anchors.clearAnchors()
        anchors.member = newMember
        lastUpload = nil
        lastTypeCount = nil
        state = .idle
        await uploadNow()
    }

    /// The types of the upload: every sample type the app reads, without the
    /// clinical records.
    nonisolated static func uploadTypeIdentifiers(_ identifiers: [String]) -> [String] {
        identifiers.filter { !$0.hasPrefix("HKClinicalTypeIdentifier") }
    }

    /// Runs the anchored sync and returns how many types sent something.
    private static func upload(baseURL: URL, provider: @escaping TokenProvider, anchors: HealthServerAnchorStore) async throws -> Int {
#if canImport(HealthKit)
        guard HKHealthStore.isHealthDataAvailable() else { return 0 }
        let client = OpenHealthSync.OHSClient(baseURL: baseURL, tokenProvider: provider)
        let sync = HealthKitSync(store: HKHealthStore(), client: client, anchors: anchors, batchPrefix: "prism")
        let all = HealthAccess.readTypes().compactMap { $0 as? HKSampleType }
        let kept = Set(uploadTypeIdentifiers(all.map(\.identifier)))
        let report = try await sync.sync(types: Set(all.filter { kept.contains($0.identifier) }))
        return report.linesByType.values.filter { $0 > 0 }.count
#else
        return 0
#endif
    }

    // MARK: Background

    /// Registers the background task. Must run before launch finishes, which
    /// is why `PrismApp.init` calls it.
    static func register() {
#if os(iOS) || os(visionOS)
        guard HealthServerSettings.current != nil else { return }
        BGTaskScheduler.shared.register(forTaskWithIdentifier: taskIdentifier, using: nil) { task in
            let handle = UploadTaskHandle(task)
            let work = Task { @MainActor in
                let finished = await HealthServerUploader.shared.uploadNow()
                schedule()
                handle.complete(finished)
            }
            task.expirationHandler = { work.cancel() }
        }
#endif
    }

    /// Asks for the next background pass, when a member is signed in.
    static func schedule() {
#if os(iOS) || os(visionOS)
        guard HealthServerSession.shared.isSignedIn else { return }
        let request = BGProcessingTaskRequest(identifier: taskIdentifier)
        request.requiresNetworkConnectivity = true
        request.requiresExternalPower = false
        request.earliestBeginDate = Date(timeIntervalSinceNow: 60 * 60)
        do {
            try BGTaskScheduler.shared.submit(request)
        } catch {
            // Refused in the simulator and when background refresh is off;
            // the next foreground pass does the work instead.
        }
#endif
    }
}

#if os(iOS) || os(visionOS)
/// Carries the system's task into the main actor's work, as `CloudBackground`
/// does.
private final class UploadTaskHandle: @unchecked Sendable {
    private let task: BGTask
    init(_ task: BGTask) { self.task = task }
    func complete(_ success: Bool) { task.setTaskCompleted(success: success) }
}
#endif
