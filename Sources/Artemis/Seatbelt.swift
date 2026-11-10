import AppKit
import Foundation

/// The few choices a user makes per app. Everything else in the profile is fixed.
struct SeatbeltOptions: Codable, Hashable, Sendable {
    var blockIncoming = true
    var blockNetwork = false
    var protectUserFolders = false

    /// The chosen options as a short phrase, for the activity log.
    var summary: String {
        var parts: [String] = []
        if blockNetwork { parts.append("all network blocked") }
        else if blockIncoming { parts.append("incoming connections blocked") }
        if protectUserFolders { parts.append("Documents, Desktop, Downloads and iCloud blocked") }
        return parts.isEmpty ? "no optional blocks" : parts.joined(separator: "; ")
    }
}

struct SeatbeltEntry: Codable, Hashable, Sendable {
    /// Where the app is opened from, for example /Applications/Foo.app.
    var appPath: String
    var name: String
    var bundleID: String
    var options: SeatbeltOptions
    /// Set while the app is replaced: where the real app was moved to. `appPath` then holds a launcher.
    var originalPath: String?

    var isReplaced: Bool { originalPath != nil }
    /// Where the real app bundle is right now.
    var realPath: String { originalPath ?? appPath }
}

struct SeatbeltError: LocalizedError {
    let message: String
    var errorDescription: String? { message }
}

enum SeatbeltPaths {
    static let sandboxExec = URL(fileURLWithPath: "/usr/bin/sandbox-exec")

    static var home: URL { FileManager.default.homeDirectoryForCurrentUser.resolvingSymlinksInPath() }

    /// Artemis's own data: the saved list and the generated profiles.
    static var support: URL { home.appendingPathComponent("Library/Application Support/Artemis") }
    static var profiles: URL { support.appendingPathComponent("Profiles") }
    static var index: URL { support.appendingPathComponent("seatbelts.json") }
    static var logs: URL { support.appendingPathComponent("Logs") }

    /// Where the double-clickable launchers live. AppScanner skips this folder.
    static var launchers: URL { home.appendingPathComponent("Applications/Managed Applications") }
    /// Where real apps are kept while a launcher stands in for them.
    static var originals: URL { launchers.appendingPathComponent("Originals") }
    static let launcherIDPrefix = "com.rgregory.artemis.managed."
}

// MARK: - Profile

/// Builds an allow-by-default Seatbelt profile that denies what an attacker wants:
/// credentials, personal data stores, and the usual persistence locations.
enum SeatbeltProfile {
    /// A home-relative path, plus the apps (bundle ID prefixes) that legitimately own it.
    private struct Guarded {
        let path: String
        var owners: [String] = []
    }

    private static let credentials: [Guarded] = [
        Guarded(path: ".ssh"),
        Guarded(path: ".aws"),
        Guarded(path: ".gnupg"),
        Guarded(path: ".kube"),
        Guarded(path: ".docker"),
        Guarded(path: ".config/gcloud"),
        Guarded(path: ".config/gh"),
        Guarded(path: ".netrc"),
        Guarded(path: ".git-credentials"),
        Guarded(path: "Library/Keychains"),
        Guarded(path: "Library/Safari"),
        Guarded(path: "Library/Containers/com.apple.Safari"),
        Guarded(path: "Library/Application Support/Google/Chrome", owners: ["com.google.Chrome"]),
        Guarded(path: "Library/Application Support/Microsoft Edge", owners: ["com.microsoft.edgemac"]),
        Guarded(path: "Library/Application Support/BraveSoftware", owners: ["com.brave.Browser"]),
        Guarded(path: "Library/Application Support/Arc", owners: ["company.thebrowser.Browser"]),
        Guarded(path: "Library/Application Support/Firefox", owners: ["org.mozilla.firefox"]),
        Guarded(path: "Library/Application Support/1Password", owners: ["com.1password", "com.agilebits"]),
        Guarded(path: "Library/Group Containers/2BUA8C4S2C.com.1password", owners: ["com.1password", "com.agilebits"]),
    ]

    private static let personal: [Guarded] = [
        Guarded(path: "Library/Mail"),
        Guarded(path: "Library/Messages"),
        Guarded(path: "Library/Calendars"),
        Guarded(path: "Library/Application Support/AddressBook"),
    ]

    private static let userFolders = [
        "Documents", "Desktop", "Downloads", "Library/Mobile Documents", "Library/CloudStorage",
    ]

    /// Places malware writes to so it runs again later. Read access stays allowed.
    private static let persistenceInHome = [
        "Library/LaunchAgents",
        ".zshrc", ".zprofile", ".zshenv", ".zlogin",
        ".bash_profile", ".bashrc", ".profile",
        ".config/fish",
        "Library/Application Support/Artemis",
    ]

    private static let persistenceSystem = ["/Library/LaunchAgents", "/Library/LaunchDaemons"]

    static func make(appPath: String, name: String, bundleID: String, options: SeatbeltOptions) -> String {
        let home = SeatbeltPaths.home.path
        func inHome(_ relative: String) -> String { subpath(home + "/" + relative) }
        func owned(_ item: Guarded) -> Bool {
            !bundleID.isEmpty && item.owners.contains { bundleID.hasPrefix($0) }
        }

        var out: [String] = []
        out.append(";; Generated by Artemis for \(name). Edits are overwritten on Update.")
        out.append("(version 1)")
        out.append("(allow default)")

        out.append(block(
            ";; Credentials and other apps' secrets",
            "deny file-read* file-write*",
            credentials.filter { !owned($0) }.map { inHome($0.path) }
        ))

        out.append(block(
            ";; Personal data stores",
            "deny file-read* file-write*",
            personal.filter { !owned($0) }.map { inHome($0.path) }
        ))

        if options.protectUserFolders {
            out.append(block(
                ";; User folders",
                "deny file-read* file-write*",
                userFolders.map { inHome($0) }
            ))
        }

        out.append(block(
            ";; Persistence: nothing that makes code run again later",
            "deny file-write*",
            persistenceInHome.map { inHome($0) } + persistenceSystem.map { subpath($0) }
        ))

        // Other apps are off limits; the app's own bundle stays writable so its updater works.
        out.append("""
        ;; Other applications
        (deny file-write*
          (require-all
            (require-any \(subpath("/Applications")) \(inHome("Applications")))
            (require-not \(subpath(appPath)))))
        """)

        if options.blockNetwork {
            out.append("""
            ;; Network: none
            (deny network-outbound (remote ip "*:*"))
            (deny network-inbound (local ip "*:*"))
            (deny network-bind (local ip "*:*"))
            """)
        } else if options.blockIncoming {
            out.append("""
            ;; Network: outbound only, plus loopback listeners
            (deny network-inbound (local ip "*:*"))
            (allow network-inbound (local ip "localhost:*"))
            """)
        }

        return out.joined(separator: "\n\n") + "\n"
    }

    private static func block(_ comment: String, _ operation: String, _ filters: [String]) -> String {
        ([comment, "(\(operation)"] + filters.map { "  " + $0 }).joined(separator: "\n") + ")"
    }

    private static func subpath(_ path: String) -> String {
        let escaped = path
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
        return "(subpath \"\(escaped)\")"
    }
}

// MARK: - Store

@MainActor
final class SeatbeltStore: ObservableObject {
    /// Keyed by resolved bundle path, the same value as AppRecord.id.
    @Published private(set) var entries: [String: SeatbeltEntry] = [:]

    /// Where launches, exits and changes are recorded. Set once the app is up.
    weak var telemetry: TelemetryStore?

    init() { load() }

    static func isEligible(_ app: AppRecord) -> Bool {
        !app.isSandboxed && !app.isIOSApp && !app.url.path.hasPrefix("/System/")
    }

    func profileURL(for app: AppRecord) -> URL {
        SeatbeltPaths.profiles.appendingPathComponent(fileKey(app) + ".sb")
    }

    func launcherURL(for app: AppRecord) -> URL {
        SeatbeltPaths.launchers.appendingPathComponent("\(app.name) (Managed).app")
    }

    /// Writes the profile, checks that macOS accepts it, then builds the launcher.
    func apply(_ app: AppRecord, options: SeatbeltOptions) throws {
        guard Self.isEligible(app) else {
            throw SeatbeltError(message: "\(app.name) already runs in a sandbox, or is part of macOS.")
        }
        let executable = try executable(of: app)
        let fm = FileManager.default
        try fm.createDirectory(at: SeatbeltPaths.profiles, withIntermediateDirectories: true)

        let profile = profileURL(for: app)
        let original = entries[app.id]?.originalPath
        let text = SeatbeltProfile.make(appPath: original ?? app.url.path, name: app.name,
                                        bundleID: app.bundleID, options: options)
        try text.write(to: profile, atomically: true, encoding: .utf8)
        try validate(profile)
        try writeLauncher(at: launcherURL(for: app), title: "\(app.name) (Managed)", for: app,
                          profile: profile, executable: executable)

        let wasManaged = entries[app.id] != nil
        entries[app.id] = SeatbeltEntry(appPath: app.url.path, name: app.name, bundleID: app.bundleID,
                                        options: options, originalPath: original)
        save()
        telemetry?.record(wasManaged ? .optionsChanged : .managed, path: app.url.path, name: app.name,
                          detail: (wasManaged ? "Options changed: " : "Added to Managed Applications: ")
                              + options.summary + ".")
    }

    func remove(_ app: AppRecord) throws {
        if entries[app.id]?.isReplaced == true { try restore(app) }
        let fm = FileManager.default
        for url in [profileURL(for: app), launcherURL(for: app), logURL(for: app)] where fm.fileExists(atPath: url.path) {
            try fm.removeItem(at: url)
        }
        entries[app.id] = nil
        save()
        telemetry?.record(.unmanaged, path: app.url.path, name: app.name,
                          detail: "Removed from Managed Applications.")
    }

    /// Starts the app inside its profile. Refuses if it is already open, because most
    /// apps would just hand off to the running, unprotected instance.
    @discardableResult
    func launch(_ app: AppRecord) throws -> Process {
        guard entries[app.id] != nil else {
            throw SeatbeltError(message: "Add \(app.name) to Managed Applications first.")
        }
        if isRunning(app) {
            throw SeatbeltError(message: "Quit \(app.name) first, then launch it as a managed application.")
        }
        let process = Process()
        process.executableURL = SeatbeltPaths.sandboxExec
        process.arguments = ["-f", profileURL(for: app).path, try executable(of: app).path]
        process.standardOutput = FileHandle.nullDevice
        process.standardError = logHandle(for: app) ?? FileHandle.nullDevice

        let started = Date()
        let path = app.url.path
        let name = app.name
        let telemetry = self.telemetry
        process.terminationHandler = { finished in
            let code = finished.terminationStatus
            let ran = TelemetryStore.duration(Date().timeIntervalSince(started))
            Task { @MainActor in
                telemetry?.record(.exit, path: path, name: name,
                                  detail: "Quit after \(ran) (exit code \(code)).")
            }
        }
        try process.run()
        telemetry?.artemisLaunched(path: path, name: name, pid: process.processIdentifier)
        return process
    }

    /// Starts the app, waits a few seconds, and throws if it has already quit.
    func launchAndWatch(_ app: AppRecord) async throws {
        let process = try launch(app)
        try? await Task.sleep(for: .seconds(3))
        guard process.isRunning else {
            let tail = logTail(for: app)
            throw SeatbeltError(message:
                "\(app.name) quit right after starting (exit code \(process.terminationStatus)). "
                + "The seatbelt is probably blocking something it needs at startup."
                + (tail.isEmpty ? "" : "\n\n" + tail))
        }
    }

    func logURL(for app: AppRecord) -> URL {
        SeatbeltPaths.logs.appendingPathComponent(fileKey(app) + ".log")
    }

    /// The last few lines the app printed on its most recent protected launch.
    func logTail(for app: AppRecord) -> String {
        guard let text = try? String(contentsOf: logURL(for: app), encoding: .utf8) else { return "" }
        return text.split(separator: "\n").suffix(4).joined(separator: "\n")
    }

    private func logHandle(for app: AppRecord) -> FileHandle? {
        let fm = FileManager.default
        try? fm.createDirectory(at: SeatbeltPaths.logs, withIntermediateDirectories: true)
        let url = logURL(for: app)
        fm.createFile(atPath: url.path, contents: nil)   // start each launch with an empty log
        return try? FileHandle(forWritingTo: url)
    }

    // MARK: Pieces

    /// Where the real app bundle is: its usual place, or the Originals folder while it is replaced.
    func realURL(for app: AppRecord) -> URL {
        entries[app.id].map { URL(fileURLWithPath: $0.realPath) } ?? app.url
    }

    private func isRunning(_ app: AppRecord) -> Bool {
        let real = realURL(for: app).path
        return NSWorkspace.shared.runningApplications.contains {
            $0.bundleURL?.resolvingSymlinksInPath().path == real
        }
    }

    /// Asks the running copy of an app to quit and waits until it has gone.
    func quit(_ app: AppRecord) async throws {
        let real = realURL(for: app).path
        let running = NSWorkspace.shared.runningApplications.filter {
            $0.bundleURL?.resolvingSymlinksInPath().path == real
        }
        for instance in running { instance.terminate() }
        for _ in 0..<40 {                                   // up to ten seconds
            if running.allSatisfy(\.isTerminated) { return }
            try? await Task.sleep(for: .milliseconds(250))
        }
        throw SeatbeltError(message: "\(app.name) didn't quit. It may be waiting for you to save something. Quit it yourself, then choose Launch Protected.")
    }

    /// Moves the real app aside and puts a launcher in its place, so opening it from the Dock,
    /// Finder or Spotlight starts it with its seatbelt.
    func replace(_ app: AppRecord) throws {
        guard var entry = entries[app.id] else {
            throw SeatbeltError(message: "Add \(app.name) to Managed Applications first.")
        }
        guard !entry.isReplaced else { return }
        guard !isRunning(app) else {
            throw SeatbeltError(message: "Quit \(app.name) before replacing it.")
        }
        let fm = FileManager.default
        let publicURL = app.url
        let parked = SeatbeltPaths.originals.appendingPathComponent(publicURL.lastPathComponent)
        guard !fm.fileExists(atPath: parked.path) else {
            throw SeatbeltError(message: "There is already an app called \(publicURL.lastPathComponent) in the Originals folder.")
        }
        try fm.createDirectory(at: SeatbeltPaths.originals, withIntermediateDirectories: true)
        try fm.moveItem(at: publicURL, to: parked)

        do {
            entry.originalPath = parked.path
            entries[app.id] = entry
            try rebuild(app, entry: entry)
            let executable = try executable(of: app)
            try writeLauncher(at: publicURL, title: app.name, for: app,
                              profile: profileURL(for: app), executable: executable)
        } catch {
            // Put everything back the way it was.
            try? fm.removeItem(at: publicURL)
            try? fm.moveItem(at: parked, to: publicURL)
            entry.originalPath = nil
            entries[app.id] = entry
            try? rebuild(app, entry: entry)
            throw error
        }
        save()
        telemetry?.record(.optionsChanged, path: app.url.path, name: app.name,
                          detail: "Replaced with its protected launcher. The real app is in Managed Applications/Originals.")
    }

    /// Undoes `replace`: removes the launcher and moves the real app back.
    func restore(_ app: AppRecord) throws {
        guard var entry = entries[app.id], let parkedPath = entry.originalPath else { return }
        guard !isRunning(app) else {
            throw SeatbeltError(message: "Quit \(app.name) before restoring it.")
        }
        let fm = FileManager.default
        let publicURL = app.url
        let parked = URL(fileURLWithPath: parkedPath)
        guard fm.fileExists(atPath: parked.path) else {
            throw SeatbeltError(message: "The real \(app.name) is missing from \(parked.deletingLastPathComponent().path).")
        }
        if fm.fileExists(atPath: publicURL.path) {
            // Only ever delete something Artemis itself put there.
            let id = Self.bundleID(at: publicURL)
            guard id.hasPrefix(SeatbeltPaths.launcherIDPrefix) else {
                throw SeatbeltError(message: "\(publicURL.path) is not an Artemis launcher, so it was left alone. Move it away and try again.")
            }
            try fm.removeItem(at: publicURL)
        }
        try fm.moveItem(at: parked, to: publicURL)
        entry.originalPath = nil
        entries[app.id] = entry
        try rebuild(app, entry: entry)
        save()
        telemetry?.record(.optionsChanged, path: app.url.path, name: app.name,
                          detail: "Restored to its original place.")
    }

    /// Reads a bundle's identifier straight from disk. `Bundle` caches by path, which gives the
    /// wrong answer once an app and its launcher have swapped places.
    private static func bundleID(at bundle: URL) -> String {
        let url = bundle.appendingPathComponent("Contents/Info.plist")
        guard let data = try? Data(contentsOf: url),
              let plist = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any]
        else { return "" }
        return plist["CFBundleIdentifier"] as? String ?? ""
    }

    /// Rewrites the profile and the Managed Applications launcher for wherever the real app now is.
    private func rebuild(_ app: AppRecord, entry: SeatbeltEntry) throws {
        let profile = profileURL(for: app)
        let text = SeatbeltProfile.make(appPath: entry.realPath, name: app.name,
                                        bundleID: app.bundleID, options: entry.options)
        try text.write(to: profile, atomically: true, encoding: .utf8)
        try writeLauncher(at: launcherURL(for: app), title: "\(app.name) (Managed)", for: app,
                          profile: profile, executable: try executable(of: app))
    }

    private func executable(of app: AppRecord) throws -> URL {
        guard let url = Bundle(url: realURL(for: app))?.executableURL else {
            throw SeatbeltError(message: "Couldn't find the main program inside \(app.name).")
        }
        return url
    }

    /// Runs a no-op under the profile so a profile macOS rejects is caught now, not at launch.
    private func validate(_ profile: URL) throws {
        let process = Process()
        let errors = Pipe()
        process.executableURL = SeatbeltPaths.sandboxExec
        process.arguments = ["-f", profile.path, "/usr/bin/true"]
        process.standardOutput = FileHandle.nullDevice
        process.standardError = errors
        try process.run()
        let data = errors.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else {
            let detail = String(data: data, encoding: .utf8)?
                .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            throw SeatbeltError(message: "macOS rejected the profile. \(detail)")
        }
    }

    /// A tiny app whose only job is to start the real one under sandbox-exec, then exit.
    private func writeLauncher(at bundle: URL, title: String, for app: AppRecord,
                               profile: URL, executable: URL) throws {
        let fm = FileManager.default
        if fm.fileExists(atPath: bundle.path) {
            // Never overwrite a real app: only replace a launcher Artemis made earlier.
            let id = Self.bundleID(at: bundle)
            guard id.hasPrefix(SeatbeltPaths.launcherIDPrefix) else {
                throw SeatbeltError(message: "\(bundle.path) already exists and is not an Artemis launcher.")
            }
            try fm.removeItem(at: bundle)
        }
        let macOS = bundle.appendingPathComponent("Contents/MacOS")
        try fm.createDirectory(at: macOS, withIntermediateDirectories: true)

        let script = """
        #!/bin/sh
        # Generated by Artemis. Starts \(app.name) inside its seatbelt profile.
        /usr/bin/sandbox-exec -f \(shellQuote(profile.path)) \(shellQuote(executable.path)) "$@" >/dev/null 2>&1 &

        """
        let scriptURL = macOS.appendingPathComponent("launch")
        try script.write(to: scriptURL, atomically: true, encoding: .utf8)
        try fm.setAttributes([.posixPermissions: 0o755], ofItemAtPath: scriptURL.path)

        let info: [String: Any] = [
            "CFBundleName": title,
            "CFBundleExecutable": "launch",
            "CFBundleIdentifier": SeatbeltPaths.launcherIDPrefix + fileKey(app),
            "CFBundlePackageType": "APPL",
            "CFBundleShortVersionString": "1.0",
            "CFBundleVersion": "1",
            "LSUIElement": true,
        ]
        let plist = try PropertyListSerialization.data(fromPropertyList: info, format: .xml, options: 0)
        try plist.write(to: bundle.appendingPathComponent("Contents/Info.plist"))

        NSWorkspace.shared.setIcon(NSWorkspace.shared.icon(forFile: realURL(for: app).path),
                                   forFile: bundle.path, options: [])
    }

    private func fileKey(_ app: AppRecord) -> String {
        let source = app.bundleID.isEmpty ? app.name : app.bundleID
        let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: ".-_"))
        return String(source.unicodeScalars.map { allowed.contains($0) ? Character($0) : "-" })
    }

    private func shellQuote(_ value: String) -> String {
        "'" + value.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }

    private func load() {
        guard let data = try? Data(contentsOf: SeatbeltPaths.index),
              let list = try? JSONDecoder().decode([SeatbeltEntry].self, from: data) else { return }
        entries = Dictionary(list.map { ($0.appPath, $0) }, uniquingKeysWith: { first, _ in first })
    }

    private func save() {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let list = entries.values.sorted { $0.name < $1.name }
        guard let data = try? encoder.encode(list) else { return }
        try? FileManager.default.createDirectory(at: SeatbeltPaths.support, withIntermediateDirectories: true)
        try? data.write(to: SeatbeltPaths.index, options: .atomic)
    }
}

// MARK: - Plain-language summary

/// One group of things a profile blocks (or leaves open), for display.
struct SeatbeltProtection: Identifiable, Hashable {
    var id: String { title }
    let title: String
    /// Two or three words for the collapsed row.
    let short: String
    let rule: String
    let symbol: String
    let items: [String]
    /// False for the closing group that lists what the seatbelt does not cover.
    var isBlocked = true
    /// True when the items are file paths.
    var arePaths = true
}

extension SeatbeltProfile {
    /// The whole protection in three or four short sentences.
    static func stanza(options: SeatbeltOptions) -> [String] {
        var lines = ["Can't read your passwords, keys, browser data, Mail, Messages, Calendar or Contacts."]
        if options.protectUserFolders {
            lines.append("Can't open Documents, Desktop, Downloads or iCloud Drive.")
        }
        lines.append("Can't add anything that runs at login, or change other apps.")
        if options.blockNetwork {
            lines.append("Can't use the network.")
        } else if options.blockIncoming {
            lines.append("Can't accept incoming connections.")
        }
        return lines
    }

    /// The notable things the chosen options leave reachable, as short phrases.
    static func stillOpen(options: SeatbeltOptions) -> [String] {
        var open: [String] = []
        if !options.blockNetwork {
            open.append(options.blockIncoming ? "connecting out to the internet" : "network connections in and out")
        }
        if !options.protectUserFolders {
            open.append("reading and changing files in Documents, Desktop, Downloads and iCloud Drive")
        }
        return open
    }

    /// Which group of protected things a blocked attempt was aimed at.
    static func category(operation: String, target: String) -> String {
        if operation.hasPrefix("network") { return "Network" }
        let home = SeatbeltPaths.home.path + "/"
        func under(_ relatives: [String]) -> Bool {
            relatives.contains { target == home + $0 || target.hasPrefix(home + $0 + "/") }
        }
        if under(credentials.map(\.path)) { return "Passwords, keys and browser data" }
        if under(personal.map(\.path)) { return "Mail, Messages, Calendar, Contacts" }
        if under(userFolders) { return "Your files" }
        if under(persistenceInHome) || persistenceSystem.contains(where: { target.hasPrefix($0) }) {
            return "Startup and login items"
        }
        if target.hasPrefix("/Applications") || target.hasPrefix(home + "Applications") {
            return "Other applications"
        }
        return "Other"
    }

    /// Describes exactly what `make` puts in the profile, built from the same lists.
    static func protections(appName: String, bundleID: String, options: SeatbeltOptions) -> [SeatbeltProtection] {
        func owned(_ item: Guarded) -> Bool {
            !bundleID.isEmpty && item.owners.contains { bundleID.hasPrefix($0) }
        }
        func tilde(_ relative: String) -> String { "~/" + relative }

        var groups: [SeatbeltProtection] = [
            SeatbeltProtection(
                title: "Passwords, keys and browser data",
                short: "No access",
                rule: "Can't read or change",
                symbol: "key.fill",
                items: credentials.filter { !owned($0) }.map { tilde($0.path) }
            ),
            SeatbeltProtection(
                title: "Mail, Messages, Calendar, Contacts",
                short: "No access",
                rule: "Can't read or change",
                symbol: "envelope.fill",
                items: personal.filter { !owned($0) }.map { tilde($0.path) }
            ),
        ]

        if options.protectUserFolders {
            groups.append(SeatbeltProtection(
                title: "Your files",
                short: "No access",
                rule: "Can't read or change",
                symbol: "folder.fill",
                items: userFolders.map(tilde)
            ))
        }

        groups.append(SeatbeltProtection(
            title: "Startup and login items",
            short: "Read only",
                rule: "Can read, can't change",
            symbol: "arrow.clockwise.circle.fill",
            items: persistenceInHome.map(tilde) + persistenceSystem
        ))

        groups.append(SeatbeltProtection(
            title: "Other applications",
            short: "Read only",
                rule: "Can't change. \(appName) can still update itself.",
            symbol: "app.badge.fill",
            items: ["/Applications", "~/Applications"]
        ))

        if options.blockNetwork {
            groups.append(SeatbeltProtection(
                title: "Network",
                short: "Blocked",
                rule: "No connections in or out",
                symbol: "network.slash",
                items: ["Outgoing connections to any address",
                        "Incoming connections",
                        "Opening a listening port"],
                arePaths: false
            ))
        } else if options.blockIncoming {
            groups.append(SeatbeltProtection(
                title: "Network",
                short: "Outgoing only",
                rule: "Can't accept connections from other machines",
                symbol: "network.badge.shield.half.filled",
                items: ["Incoming connections on any network address",
                        "Listening on localhost is still allowed"],
                arePaths: false
            ))
        }

        var open: [String] = []
        if !options.blockNetwork {
            open.append("Outgoing network connections")
        } else {
            open.append("DNS lookups, which go through a macOS service")
        }
        if !options.blockNetwork && !options.blockIncoming {
            open.append("Incoming network connections")
        }
        if !options.protectUserFolders {
            open.append("Documents, Desktop, Downloads and iCloud Drive")
        }
        open.append("Keychain items the app is already allowed to use")
        open.append("The rest of your home folder, including other apps' settings and data not listed above")
        open.append("Camera, microphone, screen and location, which macOS privacy prompts still control")

        groups.append(SeatbeltProtection(
            title: "Everything else",
            short: "Still open",
                rule: "The seatbelt leaves these as they are",
            symbol: "exclamationmark.triangle.fill",
            items: open,
            isBlocked: false,
            arePaths: false
        ))
        return groups
    }
}
