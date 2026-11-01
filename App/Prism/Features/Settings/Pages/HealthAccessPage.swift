//
//  HealthAccessPage.swift
//  Prism
//

import SwiftUI
import SomaUI
#if !os(visionOS)
import AuthenticationServices
#endif

/// Every source Soma reads, one row each: Apple's own, the ones that sign in
/// directly, then the rest, each with where it stands on the trailing edge.
///
/// With an account, every provider Open Health Sync knows signs in there and
/// sits under Connect, with when it last pulled.
///
/// A build with a health server shows a Health server section first: the
/// server, the member signed in to it, and Sign out. The wearables then
/// connect through that server, and only the ones it has an app for.
struct HealthAccessPage: View {
    @Environment(HealthDashboard.self) private var health
    @State private var account = AccountSession.shared
    @State private var healthServer = HealthServerSession.shared
    @State private var uploader = HealthServerUploader.shared
    @Environment(\.openURL) private var openURL
    @Environment(\.somaTheme) private var theme
    @State private var connections = ProviderConnections.shared
#if !os(visionOS)
    @Environment(\.webAuthenticationSession) private var webAuthentication
#endif

    private struct ProviderGroup: Identifiable {
        var id: String
        var heading: LocalizedStringKey
        var providers: [DataProvider]
    }

    private var groups: [ProviderGroup] {
        let apple = [DataProvider.appleHealth, .iPhoneMotion, .appleWatch]
        let direct = DataProvider.all.filter { $0.oauth != nil || usesOHS($0) }
        let rest = DataProvider.all.filter { provider in
            !apple.contains(provider) && !direct.contains(provider)
        }
        return [
            ProviderGroup(id: "apple", heading: "Apple", providers: apple),
            ProviderGroup(id: "direct", heading: "Connect", providers: direct),
            ProviderGroup(id: "more", heading: "More", providers: rest),
        ]
    }

    var body: some View {
        ListScaffold(eyebrow: "Settings", title: "Health access") {
            if healthServer.isConfigured {
                SettingsSection("Health server") {
                    SomaBrowseGroup(healthServerRows) { row in
                        healthServerRow(row)
                    }
                }
            }
            ForEach(groups) { group in
                SettingsSection(group.heading) {
                    SomaBrowseGroup(group.providers) { provider in
                        row(provider)
                    }
                }
            }
        }
        .task(id: signedInForOHS) {
            if signedInForOHS { await connections.refreshFromOHS() }
            if healthServer.isSignedIn { await healthServer.refreshMember() }
        }
    }

    /// Who the wearables connect for: the member of the health server in a
    /// build that has one, else the account.
    private var signedInForOHS: Bool {
        healthServer.isConfigured ? healthServer.isSignedIn : account.isSignedIn
    }

    // MARK: Health server

    private enum HealthServerRow: String, Identifiable {
        case server, upload, signOut
        var id: String { rawValue }
    }

    private var healthServerRows: [HealthServerRow] {
        healthServer.isSignedIn ? [.server, .upload, .signOut] : [.server]
    }

    @ViewBuilder
    private func healthServerRow(_ row: HealthServerRow) -> some View {
        switch row {
        case .server:
            SettingsTileLine(healthServer.settings?.host ?? "", symbol: "server.rack", detail: healthServerDetail) {
                switch healthServer.state {
                case .signingIn:
                    ProgressView().controlSize(.small)
                case .signedIn:
                    SettingsStateDot(isOn: true)
                case .signedOut, .failed:
                    if Self.canSignIn {
                        Button { signInToHealthServer() } label: {
                            Text(healthServer.state == .signedOut ? "Sign in" : "Retry")
                                .somaFont(theme.typography.rowValue)
                                .foregroundStyle(theme.colors.accent.color)
                                .frame(minHeight: theme.metrics.minimumTapTarget)
                                .contentShape(.rect)
                        }
                        .buttonStyle(.plain)
                    } else {
                        SettingsStateDot(isOn: false)
                    }
                }
            }
        case .upload:
            SettingsTileLine(String(localized: "Apple Health upload"), symbol: "arrow.up.heart", detail: uploadDetail) {
                uploadControl
            }
        case .signOut:
            SettingsTileRow(String(localized: "Sign out of the health server"), symbol: "rectangle.portrait.and.arrow.right",
                            role: .destructive, opensSomething: false, action: {
                Task { await healthServer.signOut() }
            })
        }
    }

    @ViewBuilder
    private var uploadControl: some View {
        switch uploader.state {
        case .uploading:
            ProgressView().controlSize(.small)
        case .paused:
            uploadButton("Turn on uploads") { Task { await uploader.turnOnUploads() } }
        case .idle, .failed:
            uploadButton("Upload now") { Task { await uploader.uploadNow() } }
        }
    }

    private func uploadButton(_ title: LocalizedStringKey, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(title)
                .somaFont(theme.typography.rowValue)
                .foregroundStyle(theme.colors.accent.color)
                .frame(minHeight: theme.metrics.minimumTapTarget)
                .contentShape(.rect)
        }
        .buttonStyle(.plain)
    }

    /// The upload's line: the last upload, or whose user the Apple Health of
    /// this iPhone would go to when another member signed in (open question 27).
    private var uploadDetail: String {
        switch uploader.state {
        case .uploading:
            return String(localized: "Uploading")
        case .paused:
            let who = healthServer.member?.label ?? String(localized: "the member signed in")
            return String(localized: "Uploads stopped. Turn on to send this iPhone's Apple Health to \(who)")
        case .failed(let message):
            return message
        case .idle:
            guard let last = uploader.lastUpload else { return String(localized: "Not uploaded yet") }
            let when = last.formatted(date: .omitted, time: .shortened)
            if let types = uploader.lastTypeCount { return String(localized: "Last upload \(when), \(types) types") }
            return String(localized: "Last upload \(when)")
        }
    }

    private var healthServerDetail: String {
        switch healthServer.state {
        case .signedIn:
            if let label = healthServer.member?.label {
                return String(localized: "Signed in as \(label), upload and connect")
            }
            return String(localized: "Signed in, upload and connect")
        case .signingIn: return String(localized: "Signing in")
        case .signedOut: return String(localized: "Not signed in")
        case .failed(let message): return message
        }
    }

    private func signInToHealthServer() {
        #if !os(visionOS)
        Task {
            await healthServer.signIn { url, scheme in
                try await webAuthentication.authenticate(
                    using: url, callback: .customScheme(scheme),
                    preferredBrowserSession: .ephemeral, additionalHeaderFields: [:]
                )
            }
            if healthServer.isSignedIn { await connections.refreshFromOHS() }
        }
        #endif
    }

    /// Whether this row connects through Open Health Sync: the provider is one
    /// it knows, someone is signed in, and the instance has not said it is
    /// missing.
    private func usesOHS(_ provider: DataProvider) -> Bool {
        provider.connectsThroughOHS(healthServer: healthServer.isConfigured) && signedInForOHS
            && connections.ohsAvailable != false && Self.canSignIn
    }

    @ViewBuilder
    private func row(_ provider: DataProvider) -> some View {
        if usesOHS(provider) {
            SettingsTileRow(provider.name, symbol: provider.symbol, opensSomething: false) {
                connectControl(provider)
            }
        } else {
            accessRow(provider)
        }
    }

    @ViewBuilder
    private func accessRow(_ provider: DataProvider) -> some View {
        switch provider.access {
        case .appleHealth:
            SettingsTileRow(provider.name, symbol: provider.symbol, detail: healthState, action: openHealth) {
                SettingsStateDot(isOn: health.status == .ready)
            }
        case .phoneMotion:
            SettingsTileRow(provider.name, symbol: provider.symbol,
                            detail: motionState, opensSomething: false)
        case .throughHealth:
            SettingsTileRow(provider.name, symbol: provider.symbol,
                            detail: String(localized: "Through Apple Health"), opensSomething: false)
        case .soon:
            SettingsTileRow(provider.name, symbol: provider.symbol,
                            detail: String(localized: "Soon"), opensSomething: false)
        case .direct:
            SettingsTileRow(provider.name, symbol: provider.symbol, opensSomething: false) {
                connectControl(provider)
            }
        }
    }

    @ViewBuilder
    private func connectControl(_ provider: DataProvider) -> some View {
        switch connections.state(provider) {
        case .connecting:
            ProgressView().controlSize(.small)
        case .connected(let account, let lastSync):
            Menu {
                Button(role: .destructive) { disconnect(provider) } label: {
                    Label("Disconnect", systemImage: "xmark.circle")
                }
            } label: {
                Text(Self.connectedLabel(account: account, lastSync: lastSync))
                    .somaFont(theme.typography.rowValue)
                    .foregroundStyle(theme.colors.inkSecondary.color)
                    .frame(minHeight: theme.metrics.minimumTapTarget)
                    .contentShape(.rect)
            }
            .menuStyle(.button)
            .buttonStyle(.plain)
        case .notConnected, .failed:
            if (provider.canConnect || usesOHS(provider)) && Self.canSignIn {
                Button { connect(provider) } label: {
                    Text(connections.state(provider) == .notConnected ? "Connect" : "Retry")
                        .somaFont(theme.typography.rowValue)
                        .foregroundStyle(theme.colors.accent.color)
                        .frame(minHeight: theme.metrics.minimumTapTarget)
                        .contentShape(.rect)
                }
                .buttonStyle(.plain)
            } else {
                Text("Soon")
                    .somaFont(theme.typography.rowValue)
                    .foregroundStyle(theme.colors.inkSecondary.color)
                    .accessibilityLabel(Text("Connect, not available yet"))
            }
        }
    }

    private var healthState: String {
        switch health.status {
        case .ready: String(localized: "Connected")
        case .idle: String(localized: "Not connected")
        case .loading: String(localized: "Reading")
        case .unavailable: String(localized: "Not on this device")
        case .failed: String(localized: "Couldn't read")
        }
    }

    private var motionState: String {
        switch health.motion.authorization {
        case .authorized: String(localized: "On")
        case .denied: String(localized: "Off")
        case .notDetermined: String(localized: "Not asked")
        case .restricted: String(localized: "Restricted")
        case .unavailable: String(localized: "Not on this device")
        }
    }

    private func openHealth() {
        #if os(iOS)
        if let url = URL(string: "x-apple-health://") { openURL(url) }
        #endif
    }

    private static var canSignIn: Bool {
        #if os(visionOS)
        false
        #else
        true
        #endif
    }

    /// A connected row's words: when it last pulled when that is known (Open
    /// Health Sync says), else the account it signed in as.
    static func connectedLabel(account: String?, lastSync: Date?) -> String {
        if let lastSync { return String(localized: "Synced \(lastSync.formatted(.relative(presentation: .named)))") }
        return account.map { String(localized: "Connected, \($0)") } ?? String(localized: "Connected")
    }

    private func disconnect(_ provider: DataProvider) {
        if usesOHS(provider) {
            Task { await connections.disconnectThroughOHS(provider) }
        } else {
            connections.disconnect(provider)
        }
    }

    private func connect(_ provider: DataProvider) {
        #if !os(visionOS)
        if usesOHS(provider) {
            Task {
                await connections.connectThroughOHS(provider) { url, scheme in
                    try await webAuthentication.authenticate(
                        using: url, callback: .customScheme(scheme),
                        preferredBrowserSession: .ephemeral, additionalHeaderFields: [:]
                    )
                }
            }
            return
        }
        Task {
            await connections.connect(provider) { url, scheme in
                try await webAuthentication.authenticate(
                    using: url, callback: .customScheme(scheme),
                    preferredBrowserSession: .ephemeral, additionalHeaderFields: [:]
                )
            }
        }
        #endif
    }
}

#Preview("Health access") {
    NavigationStack {
        HealthAccessPage()
            .environment(HealthDashboard())
    }
}
