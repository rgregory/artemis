import AppKit
import Foundation

/// One thing that happened to a managed application.
struct TelemetryEvent: Codable, Identifiable, Hashable, Sendable {
    enum Kind: String, Codable, Sendable {
        case managed            // added to Managed Applications
        case optionsChanged     // checkboxes changed
        case unmanaged          // removed
        case launch             // started with its seatbelt
        case exit               // a protected run ended
        case unprotectedRun     // opened outside Artemis, no seatbelt
        case blocked            // the seatbelt denied something
    }

    var id = UUID()
    var date = Date()
    let kind: Kind
    let appPath: String
    let appName: String
    /// A plain sentence describing the event.
    var detail = ""
    // Filled for blocked attempts:
    var process = ""
    var pid: Int32 = 0
    var operation = ""
    var target = ""
    var category = ""

    var symbol: String {
        switch kind {
        case .managed: return "shield.lefthalf.filled"
        case .optionsChanged: return "slider.horizontal.3"
        case .unmanaged: return "shield.slash"
        case .launch: return "play.fill"
        case .exit: return "stop.fill"
        case .unprotectedRun: return "exclamationmark.triangle.fill"
        case .blocked: return "hand.raised.fill"
        }
    }
}

/// Rolled-up numbers for one app, for its card.
struct AppActivity {
    var blocked = 0
    var byCategory: [(name: String, count: Int)] = []
    var unprotectedRuns = 0
    var protectedLaunches = 0
    var lastProtectedLaunch: Date?
}

/// One second of a protected app's vital signs, for the live trace on its card.
struct VitalSample: Hashable, Sendable {
    var cpu = 0.0          // percent of one core
    var read = 0.0         // bytes read from disk per second
    var write = 0.0        // bytes written to disk per second
    var blocked = 0.0      // attempts the seatbelt blocked in that second
}

/// A seatbelt denial as macOS logged it.
private struct Denial: Sendable {
    let process: String
    let pid: Int32
    let operation: String
    let target: String

    /// Parses one ndjson line from `log stream`. The message looks like
    /// "Sandbox: ClaudeBar(1234) deny(1) file-read-data /Users/me/.ssh/id_ed25519".
    static func parse(_ line: String) -> Denial? {
        guard let data = line.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let message = object["eventMessage"] as? String,
              message.hasPrefix("Sandbox: "),
              let marker = message.range(of: ") deny(") else { return nil }

        let head = message[message.index(message.startIndex, offsetBy: 9)..<marker.lowerBound]
        guard let paren = head.lastIndex(of: "("),
              let pid = Int32(head[head.index(after: paren)...]) else { return nil }
        let process = String(head[..<paren])

        let tail = message[marker.upperBound...]
        guard let close = tail.range(of: ") ") else { return nil }
        let rest = tail[close.upperBound...]
        let parts = rest.split(separator: " ", maxSplits: 1)
        guard let operation = parts.first else { return nil }
        let target = parts.count > 1 ? String(parts[1]) : ""
        return Denial(process: process, pid: pid, operation: String(operation), target: target)
    }
}

/// Collects bytes from a pipe and hands back whole lines.
private final class LineBuffer: @unchecked Sendable {
    private var pending = Data()

    func append(_ data: Data) -> [String] {
        pending.append(data)
        var lines: [String] = []
        while let newline = pending.firstIndex(of: 0x0A) {
            let lineData = pending[pending.startIndex..<newline]
            if let line = String(data: lineData, encoding: .utf8), !line.isEmpty { lines.append(line) }
            pending.removeSubrange(pending.startIndex...newline)
        }
        return lines
    }
}

/// Records what managed applications do: launches, exits, runs without a seatbelt, and
/// every attempt the seatbelt blocked. Kept in memory for the UI and appended to a
/// JSON-lines file for anything downstream. Only records while Artemis is open.
@MainActor
final class TelemetryStore: ObservableObject {
    @Published private(set) var events: [TelemetryEvent] = []
    /// Set when blocked attempts can't be read from the system log.
    @Published private(set) var streamProblem: String?
    /// The last two minutes of vital signs for each protected app that is running, keyed by bundle path.
    @Published private(set) var traces: [String: [VitalSample]] = [:]
    nonisolated static let traceLength = 120

    /// The current Managed Applications, keyed by bundle path. Set by the UI whenever it changes.
    var managed: [String: SeatbeltEntry] = [:] {
        didSet { rebuildExecutableNames() }
    }

    static var fileURL: URL { SeatbeltPaths.logs.appendingPathComponent("events.jsonl") }

    private let maxInMemory = 3000
    private var executableNames: [String: String] = [:]     // main program name -> bundle path
    private var realToPublic: [String: String] = [:]        // where a replaced app really is -> its usual path
    private var trackedPIDs: [Int32: String] = [:]          // live protected process -> bundle path
    private var artemisLaunches: [String: Date] = [:]       // bundle path -> when Artemis started it
    private var lastSeen: [String: Date] = [:]              // de-duplication of repeated denials
    private var stream: Process?
    private var sampler: Timer?
    private var lastTotals: [Int32: (cpu: Double, read: Double, write: Double, at: Date)] = [:]
    private var blockedThisSecond: [String: Int] = [:]
    private var observers: [NSObjectProtocol] = []
    private var started = false

    private let encoder: JSONEncoder = {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        return encoder
    }()

    init() { load() }

    // MARK: Recording

    func record(_ event: TelemetryEvent) {
        events.append(event)
        if events.count > maxInMemory { events.removeFirst(events.count - maxInMemory) }
        append(event)
    }

    func record(_ kind: TelemetryEvent.Kind, path: String, name: String, detail: String) {
        record(TelemetryEvent(kind: kind, appPath: path, appName: name, detail: detail))
    }

    /// Called when Artemis itself has started an app under its seatbelt.
    func artemisLaunched(path: String, name: String, pid: Int32) {
        trackedPIDs[pid] = path
        artemisLaunches[path] = Date()
        var event = TelemetryEvent(kind: .launch, appPath: path, appName: name,
                                   detail: "Started from Artemis with its seatbelt.")
        event.pid = pid
        record(event)
    }

    // MARK: Reading

    func events(for path: String) -> [TelemetryEvent] {
        events.filter { $0.appPath == path }
    }

    func activity(for path: String) -> AppActivity {
        var result = AppActivity()
        var categories: [String: Int] = [:]
        for event in events where event.appPath == path {
            switch event.kind {
            case .blocked:
                result.blocked += 1
                categories[event.category, default: 0] += 1
            case .unprotectedRun:
                result.unprotectedRuns += 1
            case .launch:
                result.protectedLaunches += 1
                result.lastProtectedLaunch = event.date
            default:
                break
            }
        }
        result.byCategory = categories
            .map { (name: $0.key, count: $0.value) }
            .sorted { $0.count != $1.count ? $0.count > $1.count : $0.name < $1.name }
        return result
    }

    /// Writes one app's events to a file as JSON lines.
    func export(path: String, to url: URL) throws {
        let lines = try events(for: path).map { String(data: try encoder.encode($0), encoding: .utf8) ?? "" }
        try (lines.joined(separator: "\n") + "\n").write(to: url, atomically: true, encoding: .utf8)
    }

    nonisolated static func duration(_ seconds: TimeInterval) -> String {
        let minutes = Int(seconds / 60)
        if minutes < 1 { return "less than a minute" }
        if minutes < 60 { return "\(minutes) min" }
        return "\(minutes / 60) h \(minutes % 60) min"
    }

    // MARK: Watching

    /// Begins watching app launches and the system log. Safe to call more than once.
    func start() {
        guard !started else { return }
        started = true

        let workspace = NSWorkspace.shared.notificationCenter
        observers.append(workspace.addObserver(
            forName: NSWorkspace.didLaunchApplicationNotification, object: nil, queue: .main
        ) { [weak self] note in
            guard let app = note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication,
                  let path = app.bundleURL?.resolvingSymlinksInPath().path else { return }
            let pid = app.processIdentifier
            Task { @MainActor in self?.appLaunched(path: path, pid: pid) }
        })
        observers.append(workspace.addObserver(
            forName: NSWorkspace.didTerminateApplicationNotification, object: nil, queue: .main
        ) { [weak self] note in
            guard let app = note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication else { return }
            let pid = app.processIdentifier
            Task { @MainActor in
                // Keep the pid a little longer: its last denials can arrive after it quits.
                try? await Task.sleep(for: .seconds(5))
                self?.trackedPIDs[pid] = nil
            }
        })
        observers.append(NotificationCenter.default.addObserver(
            forName: NSApplication.willTerminateNotification, object: nil, queue: .main
        ) { [weak self] _ in
            Task { @MainActor in self?.stream?.terminate() }
        })

        startLogStream()

        sampler = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.sample() }
        }
    }

    /// Once a second: read each protected process's CPU and disk counters and add a point to its trace.
    private func sample() {
        var perApp: [String: VitalSample] = [:]
        let now = Date()
        for (pid, path) in trackedPIDs {
            guard let totals = Self.usage(of: pid) else {
                lastTotals[pid] = nil
                continue
            }
            var point = perApp[path] ?? VitalSample()
            if let last = lastTotals[pid] {
                let seconds = max(0.001, now.timeIntervalSince(last.at))
                point.cpu += max(0, totals.cpu - last.cpu) / seconds * 100
                point.read += max(0, totals.read - last.read) / seconds
                point.write += max(0, totals.write - last.write) / seconds
            }
            lastTotals[pid] = (totals.cpu, totals.read, totals.write, now)
            perApp[path] = point
        }
        for (path, var point) in perApp {
            point.blocked = Double(blockedThisSecond[path] ?? 0)
            var trace = traces[path] ?? []
            trace.append(point)
            if trace.count > Self.traceLength { trace.removeFirst(trace.count - Self.traceLength) }
            traces[path] = trace
        }
        blockedThisSecond.removeAll()
        // Drop the trace of an app that is no longer running.
        for path in traces.keys where perApp[path] == nil { traces[path] = nil }
    }

    /// Cumulative CPU seconds and disk bytes for a process, or nil once it has gone.
    private nonisolated static func usage(of pid: Int32) -> (cpu: Double, read: Double, write: Double)? {
        var info = rusage_info_v4()
        let result = withUnsafeMutablePointer(to: &info) {
            $0.withMemoryRebound(to: rusage_info_t?.self, capacity: 1) {
                proc_pid_rusage(pid, RUSAGE_INFO_V4, $0)
            }
        }
        guard result == 0 else { return nil }
        // CPU times are in Mach time units, which are not nanoseconds on Apple silicon.
        var timebase = mach_timebase_info_data_t()
        mach_timebase_info(&timebase)
        let ticks = Double(info.ri_user_time + info.ri_system_time)
        let seconds = ticks * Double(timebase.numer) / Double(max(1, timebase.denom)) / 1_000_000_000
        return (seconds, Double(info.ri_diskio_bytesread), Double(info.ri_diskio_byteswritten))
    }

    /// A managed app appeared. Work out whether it has its seatbelt on.
    private func appLaunched(path launchedPath: String, pid: Int32) {
        let path = realToPublic[launchedPath] ?? launchedPath
        guard let entry = managed[path] else { return }
        // A replaced app's launcher stub also "launches"; only the real app counts.
        if entry.isReplaced && launchedPath == path { return }
        Task {
            try? await Task.sleep(for: .seconds(1))     // give the process time to finish starting
            if SandboxInspector.isProcessSandboxed(pid) {
                trackedPIDs[pid] = path
                let byArtemis = artemisLaunches[path].map { Date().timeIntervalSince($0) < 15 } ?? false
                if !byArtemis {
                    var event = TelemetryEvent(kind: .launch, appPath: path, appName: entry.name,
                                               detail: "Started from its launcher with its seatbelt.")
                    event.pid = pid
                    record(event)
                }
            } else {
                var event = TelemetryEvent(kind: .unprotectedRun, appPath: path, appName: entry.name,
                                           detail: "Opened outside Artemis. It ran with no seatbelt.")
                event.pid = pid
                record(event)
            }
        }
    }

    /// Follows the system log for seatbelt denials. macOS writes one line per blocked attempt.
    private func startLogStream() {
        let process = Process()
        let output = Pipe()
        let errors = Pipe()
        let buffer = LineBuffer()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/log")
        process.arguments = ["stream", "--style", "ndjson", "--predicate",
                             "sender == \"Sandbox\" AND eventMessage CONTAINS \"deny(\""]
        process.standardOutput = output
        process.standardError = errors

        output.fileHandleForReading.readabilityHandler = { [weak self] handle in
            let data = handle.availableData
            guard !data.isEmpty else { return }
            let denials = buffer.append(data).compactMap(Denial.parse)
            guard !denials.isEmpty else { return }
            Task { @MainActor in self?.ingest(denials) }
        }
        process.terminationHandler = { [weak self] finished in
            output.fileHandleForReading.readabilityHandler = nil
            let data = errors.fileHandleForReading.readDataToEndOfFile()
            let text = String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            let code = finished.terminationStatus
            Task { @MainActor in
                self?.stream = nil
                if code != 0 && code != 15 {
                    self?.streamProblem = "Blocked attempts aren't being recorded: macOS wouldn't let Artemis read the system log."
                        + (text.isEmpty ? "" : " (\(text))")
                }
            }
        }

        do {
            try process.run()
            stream = process
        } catch {
            streamProblem = "Blocked attempts aren't being recorded: \(error.localizedDescription)"
        }
    }

    private func ingest(_ denials: [Denial]) {
        for denial in denials {
            guard let path = trackedPIDs[denial.pid] ?? pathForProcess(named: denial.process),
                  let entry = managed[path] else { continue }
            blockedThisSecond[path, default: 0] += 1

            // The same attempt often repeats many times a second; keep one every five seconds.
            let key = path + "|" + denial.operation + "|" + denial.target
            if let seen = lastSeen[key], Date().timeIntervalSince(seen) < 5 { continue }
            lastSeen[key] = Date()
            if lastSeen.count > 2000 { lastSeen.removeAll() }

            var event = TelemetryEvent(kind: .blocked, appPath: path, appName: entry.name)
            event.process = denial.process
            event.pid = denial.pid
            event.operation = denial.operation
            event.target = denial.target
            event.category = SeatbeltProfile.category(operation: denial.operation, target: denial.target)
            event.detail = "Blocked: \(denial.operation) \(denial.target)"
            record(event)
        }
    }

    /// Matches a process name from the log to a managed app, including its helper processes.
    private func pathForProcess(named name: String) -> String? {
        if let path = executableNames[name] { return path }
        return executableNames.first { name.hasPrefix($0.key + " ") }?.value
    }

    private func rebuildExecutableNames() {
        var names: [String: String] = [:]
        var reals: [String: String] = [:]
        for (path, entry) in managed {
            if let name = Bundle(url: URL(fileURLWithPath: entry.realPath))?.executableURL?.lastPathComponent {
                names[name] = path
            }
            if entry.isReplaced { reals[entry.realPath] = path }
        }
        executableNames = names
        realToPublic = reals
    }

    // MARK: File

    private func append(_ event: TelemetryEvent) {
        guard var data = try? encoder.encode(event) else { return }
        data.append(0x0A)
        let fm = FileManager.default
        let url = Self.fileURL
        try? fm.createDirectory(at: SeatbeltPaths.logs, withIntermediateDirectories: true)
        if !fm.fileExists(atPath: url.path) { fm.createFile(atPath: url.path, contents: nil) }
        guard let handle = try? FileHandle(forWritingTo: url) else { return }
        defer { try? handle.close() }
        _ = try? handle.seekToEnd()
        try? handle.write(contentsOf: data)
    }

    private func load() {
        guard let text = try? String(contentsOf: Self.fileURL, encoding: .utf8) else { return }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        events = text.split(separator: "\n").suffix(maxInMemory).compactMap {
            try? decoder.decode(TelemetryEvent.self, from: Data($0.utf8))
        }
    }
}
