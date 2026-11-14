import Darwin
import Foundation

/// One process kind inside an app bundle, with its own sandbox or none. Browsers built on
/// Chromium or Firefox split into many of these, each locked into its own Seatbelt profile
/// as it starts, so an app listed as "No sandbox" can still have several sandboxes inside it.
struct SandboxLayer: Identifiable, Hashable, Sendable {
    enum State: Hashable, Sendable {
        /// Seen running: how many processes, and how many of them are in a sandbox.
        case live(running: Int, sandboxed: Int)
        /// Not running. Its signature carries the App Sandbox entitlement.
        case appSandbox
        /// Not running. It locks itself into a sandbox when it starts (Chromium, Firefox).
        case sandboxesItself
        /// Not running, and nothing says it is sandboxed.
        case none
    }

    var id: String { name }
    let name: String
    let role: String
    var state: State
    let order: Int

    var isSandboxed: Bool? {
        switch state {
        case let .live(running, sandboxed): return sandboxed == running ? true : (sandboxed == 0 ? false : nil)
        case .appSandbox, .sandboxesItself: return true
        case .none: return false
        }
    }

    var stateLabel: String {
        switch state {
        case let .live(running, sandboxed):
            let count = running == 1 ? "1 running" : "\(running) running"
            if sandboxed == running { return running == 1 ? "\(count), sandboxed" : "\(count), all sandboxed" }
            if sandboxed == 0 { return "\(count), not sandboxed" }
            return "\(count), \(sandboxed) sandboxed"
        case .appSandbox: return "App Sandbox in its signature"
        case .sandboxesItself: return "Sandboxes itself when it starts"
        case .none: return "No sandbox"
        }
    }
}

struct SandboxLayerReport: Sendable {
    var layers: [SandboxLayer] = []
    var isLive = false

    var running: Int {
        layers.reduce(0) { total, layer in
            if case let .live(running, _) = layer.state { return total + running }
            return total
        }
    }
    var sandboxedRunning: Int {
        layers.reduce(0) { total, layer in
            if case let .live(_, sandboxed) = layer.state { return total + sandboxed }
            return total
        }
    }
    /// Worth showing: there is more than one layer and at least one of them is sandboxed.
    var isLayered: Bool { layers.count > 1 && layers.contains { $0.isSandboxed != false } }
}

enum SandboxLayerScanner {
    /// Live view when the app is running (every process whose executable is inside the bundle,
    /// asked of the kernel), otherwise what the bundle's helpers say about themselves.
    static func report(for app: AppRecord, codeURL: URL? = nil) -> SandboxLayerReport {
        let bundles = [app.url, codeURL].compactMap { $0?.resolvingSymlinksInPath().path }
        let live = liveLayers(app, bundles: bundles)
        if !live.isEmpty { return SandboxLayerReport(layers: live, isLive: true) }
        return SandboxLayerReport(layers: staticLayers(app, bundle: codeURL ?? app.url), isLive: false)
    }

    // MARK: - Running processes

    private static func liveLayers(_ app: AppRecord, bundles: [String]) -> [SandboxLayer] {
        var groups: [String: SandboxLayer] = [:]
        for pid in allPIDs() {
            guard let path = executablePath(pid),
                  let bundle = bundles.first(where: { path.hasPrefix($0 + "/") }) else { continue }
            let relative = String(path.dropFirst(bundle.count + 1))
            let (name, role, order) = classify(app, relative: relative, executable: path, arguments: arguments(of: pid))
            let sandboxed = SandboxInspector.isProcessSandboxed(pid) ? 1 : 0
            if var layer = groups[name], case let .live(running, done) = layer.state {
                layer.state = .live(running: running + 1, sandboxed: done + sandboxed)
                groups[name] = layer
            } else {
                groups[name] = SandboxLayer(name: name, role: role, state: .live(running: 1, sandboxed: sandboxed), order: order)
            }
        }
        return groups.values.sorted { ($0.order, $0.name) < ($1.order, $1.name) }
    }

    private static func classify(_ app: AppRecord, relative: String, executable: String,
                                 arguments: [String]) -> (String, String, Int) {
        let nested = relative.contains(".app/") || relative.contains(".xpc/")
        let exe = (executable as NSString).lastPathComponent

        if app.ownSandbox == .chromium {
            if exe.contains("crashpad") { return ("Crash reporter", "Collects crash reports", 8) }
            let type = value(of: "--type=", in: arguments)
            switch type {
            case nil where !nested: return ("Main process", "Runs the window, tabs and settings, and starts everything else", 0)
            case "renderer"?:
                return ("Renderers", app.isBrowser ? "Run web pages and their JavaScript" : "Run the app's web-based interface", 1)
            case "gpu-process"?: return ("GPU", "Draws to the screen", 2)
            case "utility"?:
                let sub = value(of: "--utility-sub-type=", in: arguments) ?? ""
                if sub.hasPrefix("network.") { return ("Network service", "Fetches everything from the internet", 3) }
                if sub.hasPrefix("storage.") { return ("Storage service", "Reads and writes site data", 4) }
                if sub.hasPrefix("audio.") { return ("Audio service", "Plays and records sound", 5) }
                return ("Utility services", "Decode files, audio and other untrusted data", 6)
            case "ppapi"?, "plugin"?: return ("Plugins", "Run plugin code", 7)
            default: break
            }
        }

        if app.ownSandbox == .firefox {
            if !nested { return ("Main process", "Runs the window, tabs and settings, and starts everything else", 0) }
            switch arguments.last {
            case "tab"?: return ("Web content", "Runs web pages and their JavaScript", 1)
            case "gpu"?: return ("GPU", "Draws to the screen", 2)
            case "socket"?: return ("Network", "Fetches everything from the internet", 3)
            case "rdd"?: return ("Media decoder", "Decodes audio and video from the web", 4)
            case "gmplugin"?: return ("Media plugins", "Run DRM and codec plugins", 5)
            case "utility"?: return ("Utility", "Decodes untrusted data", 6)
            default: break
            }
        }

        if !nested { return ("Main process", "The app itself", 0) }
        return (exe, relative.contains(".xpc/") ? "XPC service" : "Helper", 9)
    }

    private static func value(of prefix: String, in arguments: [String]) -> String? {
        arguments.first { $0.hasPrefix(prefix) }.map { String($0.dropFirst(prefix.count)) }
    }

    // MARK: - Bundle contents

    private static func staticLayers(_ app: AppRecord, bundle: URL) -> [SandboxLayer] {
        let fm = FileManager.default
        let contents = bundle.appendingPathComponent("Contents")
        var layers = [SandboxLayer(name: "Main process",
                                   role: app.ownSandbox == nil ? "The app itself" : "Runs the window, tabs and settings, and starts everything else",
                                   state: app.isSandboxed ? .appSandbox : .none, order: 0)]
        func add(_ name: String, _ role: String, _ state: SandboxLayer.State, _ order: Int) {
            if !layers.contains(where: { $0.name == name }) {
                layers.append(SandboxLayer(name: name, role: role, state: state, order: order))
            }
        }

        switch app.ownSandbox {
        case .chromium?:
            for helper in chromiumHelpers(contents) {
                switch helper {
                case let h where h.hasSuffix("(Renderer).app"):
                    add("Renderers", app.isBrowser ? "Run web pages and their JavaScript" : "Run the app's web-based interface", .sandboxesItself, 1)
                case let h where h.hasSuffix("(GPU).app"): add("GPU", "Draws to the screen", .sandboxesItself, 2)
                case let h where h.hasSuffix("(Plugin).app"): add("Plugins", "Run plugin code", .sandboxesItself, 7)
                case let h where h.hasSuffix(" Helper.app"):
                    add("Network and utility services", "Fetch from the internet and decode untrusted data", .sandboxesItself, 3)
                default: break
                }
            }
        case .firefox?:
            add("Web content, media and network", "Run web pages, decode media and fetch from the internet", .sandboxesItself, 1)
        case nil:
            break
        }

        // XPC services and helper apps declare their own sandbox in their signatures.
        var nested: [URL] = []
        for folder in ["XPCServices", "Library/LoginItems", "Helpers"] {
            let dir = contents.appendingPathComponent(folder)
            for name in (try? fm.contentsOfDirectory(atPath: dir.path)) ?? []
            where name.hasSuffix(".xpc") || name.hasSuffix(".app") {
                nested.append(dir.appendingPathComponent(name))
            }
        }
        if app.ownSandbox == nil {
            let frameworks = contents.appendingPathComponent("Frameworks")
            for name in (try? fm.contentsOfDirectory(atPath: frameworks.path)) ?? [] where name.hasSuffix(".framework") {
                let services = frameworks.appendingPathComponent(name).appendingPathComponent("XPCServices")
                for xpc in (try? fm.contentsOfDirectory(atPath: services.path)) ?? [] where xpc.hasSuffix(".xpc") {
                    nested.append(services.appendingPathComponent(xpc))
                }
            }
        }
        for url in nested {
            let name = url.deletingPathExtension().lastPathComponent
            let sandboxed = SandboxInspector.inspect(url).sandboxEntitlement
            add(name, url.pathExtension == "xpc" ? "XPC service" : "Helper", sandboxed ? .appSandbox : .none, 9)
        }
        return layers.sorted { ($0.order, $0.name) < ($1.order, $1.name) }
    }

    /// Counted while scanning, for the Sandbox column: sandboxed process kinds in the bundle.
    static func sandboxedLayerNames(bundle: URL, ownSandbox: OwnSandbox?) -> [String] {
        var names: [String] = []
        switch ownSandbox {
        case .chromium?:
            let helpers = chromiumHelpers(bundle.appendingPathComponent("Contents"))
            for (suffix, label) in [("(Renderer).app", "Pages"), ("(GPU).app", "GPU"),
                                    (" Helper.app", "Network"), ("(Plugin).app", "Plugins")]
            where helpers.contains(where: { $0.hasSuffix(suffix) }) {
                names.append(label)
            }
        case .firefox?:
            names = ["Pages", "GPU", "Network", "Media", "Utility"]
        case nil:
            break
        }
        let fm = FileManager.default
        let xpc = bundle.appendingPathComponent("Contents/XPCServices")
        for name in ((try? fm.contentsOfDirectory(atPath: xpc.path)) ?? []).sorted() where name.hasSuffix(".xpc") {
            if SandboxInspector.inspect(xpc.appendingPathComponent(name)).sandboxEntitlement {
                names.append((name as NSString).deletingPathExtension)
            }
        }
        return names
    }

    /// Chromium keeps its helpers in Contents/Frameworks, either loose or inside
    /// "<Name> Framework.framework/Helpers" (or Versions/*/Helpers).
    private static func chromiumHelpers(_ contents: URL) -> [String] {
        let fm = FileManager.default
        let frameworks = contents.appendingPathComponent("Frameworks")
        var found = (try? fm.contentsOfDirectory(atPath: frameworks.path)) ?? []
        for name in found where name.hasSuffix(".framework") {
            let framework = frameworks.appendingPathComponent(name)
            found += (try? fm.contentsOfDirectory(atPath: framework.appendingPathComponent("Helpers").path)) ?? []
            let versions = framework.appendingPathComponent("Versions")
            for version in (try? fm.contentsOfDirectory(atPath: versions.path)) ?? [] where version != "Current" {
                found += (try? fm.contentsOfDirectory(atPath: versions.appendingPathComponent(version).appendingPathComponent("Helpers").path)) ?? []
            }
        }
        return found.filter { $0.hasSuffix(".app") }
    }

    // MARK: - libproc / sysctl

    private static func allPIDs() -> [pid_t] {
        let estimate = proc_listallpids(nil, 0)
        guard estimate > 0 else { return [] }
        var pids = [pid_t](repeating: 0, count: Int(estimate) + 64)
        let count = pids.withUnsafeMutableBytes { proc_listallpids($0.baseAddress, Int32($0.count)) }
        guard count > 0 else { return [] }
        return Array(pids.prefix(Int(count))).filter { $0 > 0 }
    }

    private static func executablePath(_ pid: pid_t) -> String? {
        var buffer = [CChar](repeating: 0, count: 4 * Int(MAXPATHLEN))
        guard proc_pidpath(pid, &buffer, UInt32(buffer.count)) > 0 else { return nil }
        return String(cString: buffer)
    }

    /// The process's argv, from KERN_PROCARGS2. Only readable for your own processes.
    private static func arguments(of pid: pid_t) -> [String] {
        var mib: [Int32] = [CTL_KERN, KERN_PROCARGS2, pid]
        var size = 0
        guard sysctl(&mib, 3, nil, &size, nil, 0) == 0, size > MemoryLayout<Int32>.size else { return [] }
        var buffer = [UInt8](repeating: 0, count: size)
        guard sysctl(&mib, 3, &buffer, &size, nil, 0) == 0, size > MemoryLayout<Int32>.size else { return [] }
        let argc = buffer.withUnsafeBytes { Int($0.loadUnaligned(as: Int32.self)) }
        var index = MemoryLayout<Int32>.size
        while index < size, buffer[index] != 0 { index += 1 }   // executable path
        while index < size, buffer[index] == 0 { index += 1 }   // padding
        var args: [String] = []
        while args.count < argc, index < size {
            let start = index
            while index < size, buffer[index] != 0 { index += 1 }
            args.append(String(decoding: buffer[start..<index], as: UTF8.self))
            index += 1
        }
        return args
    }
}
