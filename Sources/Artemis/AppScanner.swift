import AppKit
import Foundation

enum AppScanner {
    static var roots: [URL] {
        let home = FileManager.default.homeDirectoryForCurrentUser
        return [
            URL(fileURLWithPath: "/Applications"),
            home.appendingPathComponent("Applications"),
            URL(fileURLWithPath: "/System/Applications"),
            URL(fileURLWithPath: "/System/Library/CoreServices/Applications"),
            URL(fileURLWithPath: "/System/Volumes/Preboot/Cryptexes/App/System/Applications"),
        ]
    }

    /// `running` maps resolved bundle paths to the pid of the running instance.
    /// `replaced` maps a public path that now holds an Artemis launcher to where the real app is.
    static func scanAll(running: [String: pid_t], replaced: [String: String] = [:]) -> [AppRecord] {
        var seen = Set<String>()
        var bundles: [URL] = []
        for root in roots {
            collect(root, depth: 0, into: &bundles, seen: &seen)
        }
        guard !bundles.isEmpty else { return [] }

        var results = [AppRecord?](repeating: nil, count: bundles.count)
        let found = bundles
        results.withUnsafeMutableBufferPointer { buffer in
            let slots = buffer
            DispatchQueue.concurrentPerform(iterations: found.count) { index in
                slots[index] = makeRecord(found[index], running: running, replaced: replaced)
            }
        }
        return results.compactMap { $0 }
    }

    private static func collect(_ dir: URL, depth: Int, into bundles: inout [URL], seen: inout Set<String>) {
        guard depth <= 3,
              let items = try? FileManager.default.contentsOfDirectory(
                at: dir,
                includingPropertiesForKeys: [.isDirectoryKey],
                options: [.skipsHiddenFiles]
              ) else { return }

        for item in items {
            // Managed Applications launchers are not installed applications.
            if item.resolvingSymlinksInPath().path == SeatbeltPaths.launchers.path { continue }
            if item.pathExtension.lowercased() == "app" {
                let resolved = item.resolvingSymlinksInPath()
                if seen.insert(resolved.path).inserted { bundles.append(resolved) }
            } else if (try? item.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true {
                collect(item, depth: depth + 1, into: &bundles, seen: &seen)
            }
        }
    }

    private static func makeRecord(_ url: URL, running: [String: pid_t], replaced: [String: String]) -> AppRecord? {
        let fm = FileManager.default

        // iOS/iPadOS apps on Apple silicon are wrapped: Foo.app/WrappedBundle -> Wrapper/Foo.app
        let wrapped = url.appendingPathComponent("WrappedBundle")
        let isIOSApp = fm.fileExists(atPath: wrapped.path)
        var codeURL = isIOSApp ? wrapped.resolvingSymlinksInPath() : url
        if let real = replaced[url.path] { codeURL = URL(fileURLWithPath: real) }

        let plist = Bundle(url: codeURL)?.infoDictionary ?? [:]
        let bundleID = plist["CFBundleIdentifier"] as? String ?? ""
        let version = plist["CFBundleShortVersionString"] as? String
            ?? plist["CFBundleVersion"] as? String ?? ""

        var name = fm.displayName(atPath: url.path)
        if name.lowercased().hasSuffix(".app") { name = String(name.dropLast(4)) }

        let info = SandboxInspector.inspect(codeURL)
        let isAppStore = fm.fileExists(atPath: url.appendingPathComponent("Contents/_MASReceipt/receipt").path)

        var runtime = RuntimeState.notRunning
        if let pid = running[url.path] ?? running[codeURL.path] {
            runtime = SandboxInspector.isProcessSandboxed(pid) ? .sandboxed : .unsandboxed
        }

        // iOS apps always run in a container, whatever their macOS-visible entitlements say.
        let sandboxed = info.sandboxEntitlement || isIOSApp

        let ownSandbox = OwnSandbox.detect(bundle: codeURL)
        return AppRecord(
            id: url.path,
            url: url,
            name: name,
            bundleID: bundleID,
            version: version,
            isSandboxed: sandboxed,
            signing: info.signing,
            teamID: info.teamID,
            hardenedRuntime: info.hardenedRuntime,
            isApple: bundleID.hasPrefix("com.apple.") && info.signing == .signed && info.teamID.isEmpty
                || url.path.hasPrefix("/System/"),
            isAppStore: isAppStore,
            isIOSApp: isIOSApp,
            runtime: runtime,
            entitlements: info.entitlements,
            exposure: ExposureScanner.assess(bundle: codeURL, plist: plist, bundleID: bundleID,
                                             name: name, entitlements: info.entitlements),
            ownSandbox: ownSandbox,
            sandboxLayerNames: SandboxLayerScanner.sandboxedLayerNames(bundle: codeURL, ownSandbox: ownSandbox)
        )
    }
}

@MainActor
final class AppStore: ObservableObject {
    @Published var apps: [AppRecord] = []
    @Published var isScanning = false
    @Published var lastScan: Date?
    /// Public path -> real path for apps Artemis has replaced with a launcher. Set by the UI.
    var replaced: [String: String] = [:]

    /// Rescans after a short wait, for when an app has just been started or quit.
    func scan(after seconds: Double) {
        Task {
            try? await Task.sleep(for: .seconds(seconds))
            scan()
        }
    }

    func scan() {
        guard !isScanning else { return }
        isScanning = true

        var running: [String: pid_t] = [:]
        for app in NSWorkspace.shared.runningApplications {
            if let path = app.bundleURL?.resolvingSymlinksInPath().path {
                running[path] = app.processIdentifier
            }
        }
        let snapshot = running
        let replacedSnapshot = replaced

        Task {
            let result = await Task.detached(priority: .userInitiated) {
                AppScanner.scanAll(running: snapshot, replaced: replacedSnapshot)
            }.value
            self.apps = result
            self.lastScan = Date()
            self.isScanning = false
        }
    }
}
