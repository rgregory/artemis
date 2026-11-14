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

/// A sandbox the app sets up for its own helper processes. macOS refuses to start one sandbox
/// inside another ("forbidden-sandbox-reinit"), so such an app only runs under a seatbelt with
/// its own sandbox switched off.
enum OwnSandbox: String, Sendable, Hashable {
    /// Chromium, Chrome, Edge, Brave, Electron and CEF apps.
    case chromium
    /// Firefox and its relatives.
    case firefox

    static func detect(bundle: URL) -> OwnSandbox? {
        let fm = FileManager.default
        let contents = bundle.appendingPathComponent("Contents")
        if fm.fileExists(atPath: contents.appendingPathComponent("MacOS/plugin-container.app").path) {
            return .firefox
        }
        let frameworks = contents.appendingPathComponent("Frameworks")
        let names = (try? fm.contentsOfDirectory(atPath: frameworks.path)) ?? []
        func isRenderer(_ name: String) -> Bool { name.hasSuffix("Helper (Renderer).app") }
        if names.contains(where: isRenderer)
            || names.contains("Electron Framework.framework")
            || names.contains("Chromium Embedded Framework.framework") {
            return .chromium
        }
        // Browsers keep their helpers inside "<Name> Framework.framework/Helpers".
        for name in names where name.hasSuffix(" Framework.framework") {
            let helpers = frameworks.appendingPathComponent(name).appendingPathComponent("Helpers")
            if ((try? fm.contentsOfDirectory(atPath: helpers.path)) ?? []).contains(where: isRenderer) {
                return .chromium
            }
        }
        return nil
    }

    /// Extra command-line arguments that switch the app's own sandbox off.
    var arguments: [String] {
        self == .chromium ? ["--no-sandbox"] : []
    }

    /// Extra environment variables that switch the app's own sandbox off.
    var environment: [String: String] {
        guard self == .firefox else { return [:] }
        return [
            "MOZ_DISABLE_CONTENT_SANDBOX": "1",
            "MOZ_DISABLE_GMP_SANDBOX": "1",
            "MOZ_DISABLE_RDD_SANDBOX": "1",
            "MOZ_DISABLE_SOCKET_PROCESS_SANDBOX": "1",
            "MOZ_DISABLE_UTILITY_SANDBOX": "1",
        ]
    }
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
    let exposure: Exposure
    /// Set when the app sandboxes its own helper processes.
    let ownSandbox: OwnSandbox?

    var isBrowser: Bool { exposure.pull.contains { $0.hasPrefix("Web browser") } }

    /// For sorting: an app with no sandbox ranks by its exposure, a sandboxed one ranks last.
    var riskScore: Int { isSandboxed ? -1 : exposure.score }
    var riskLabel: String { exposure.label }

    /// "Own sandbox" for Chromium and Firefox apps: no App Sandbox on the main process, but
    /// their helpers lock themselves into Seatbelt profiles of their own.
    var statusLabel: String { isSandboxed ? "Sandboxed" : (ownSandbox != nil ? "Own sandbox" : "No sandbox") }

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
