import Foundation

enum SigningState: String, Sendable {
    case signed = "Signed"
    case adHoc = "Ad hoc"
    case unsigned = "Unsigned"
}

/// Live state of the app's main process, if it is running right now.
enum RuntimeState: Sendable {
    case notRunning
    case sandboxed
    case unsandboxed
}

struct EntitlementItem: Identifiable, Hashable, Sendable {
    var id: String { key }
    let key: String
    let value: String
}

struct AppRecord: Identifiable, Hashable, Sendable {
    let id: String              // resolved bundle path
    let url: URL
    let name: String
    let bundleID: String
    let version: String
    /// True when the main executable's signature carries com.apple.security.app-sandbox = true.
    let isSandboxed: Bool
    let signing: SigningState
    let teamID: String
    let hardenedRuntime: Bool
    let isApple: Bool
    let isAppStore: Bool
    let isIOSApp: Bool
    let runtime: RuntimeState
    let entitlements: [EntitlementItem]

    var statusLabel: String { isSandboxed ? "Sandboxed" : "No sandbox" }

    var signingLabel: String {
        switch signing {
        case .signed: return hardenedRuntime ? "Signed · Hardened" : "Signed"
        case .adHoc: return "Ad hoc"
        case .unsigned: return "Unsigned"
        }
    }

    var sourceLabel: String {
        if isIOSApp { return "iOS app" }
        if isAppStore { return "App Store" }
        if isApple { return "Apple" }
        switch signing {
        case .signed: return "Developer ID"
        case .adHoc: return "Local build"
        case .unsigned: return "Unknown"
        }
    }

    var runtimeLabel: String {
        switch runtime {
        case .notRunning: return "Not running"
        case .sandboxed: return "Running, sandboxed"
        case .unsandboxed: return "Running, not sandboxed"
        }
    }

    var location: String { url.deletingLastPathComponent().path }
}
