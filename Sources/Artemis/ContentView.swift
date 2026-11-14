import AppKit
import SwiftUI
import UniformTypeIdentifiers

enum Filter: String, CaseIterable {
    case unprotected, managed, sandboxed, all
}

struct ContentView: View {
    @EnvironmentObject private var store: AppStore
    @EnvironmentObject private var seatbelts: SeatbeltStore
    @EnvironmentObject private var telemetry: TelemetryStore

    @State private var filter: Filter = .unprotected
    @State private var showApple = true
    @State private var search = ""
    @State private var selection: AppRecord.ID?
    /// Riskiest first: apps that pull from the world or take orders from agents rise to the top.
    @State private var sortOrder = [
        KeyPathComparator(\AppRecord.riskScore, order: .reverse),
        KeyPathComparator(\AppRecord.name),
    ]
    @State private var showInspector = false
    @State private var managing: AppRecord?
    @AppStorage("sidebarWidth") private var sidebarWidth = 340.0
    @State private var widthAtDragStart: Double?
    @State private var problem: String?
    @AppStorage(AppTheme.storageKey) private var theme = AppTheme.standard
    private var themed: Bool { theme.isCustom }

    /// Everything in scope (Apple toggle applied), before the sandbox filter and search.
    private var scoped: [AppRecord] {
        showApple ? store.apps : store.apps.filter { !$0.isApple }
    }

    private var visible: [AppRecord] {
        var rows = scoped
        switch filter {
        case .unprotected: rows = rows.filter { !$0.isSandboxed }
        case .managed: rows = rows.filter { seatbelts.entries[$0.id] != nil }
        case .sandboxed: rows = rows.filter { $0.isSandboxed }
        case .all: break
        }
        let query = search.trimmingCharacters(in: .whitespaces)
        if !query.isEmpty {
            rows = rows.filter {
                $0.name.localizedCaseInsensitiveContains(query)
                    || $0.bundleID.localizedCaseInsensitiveContains(query)
                    || $0.teamID.localizedCaseInsensitiveContains(query)
            }
        }
        return rows.sorted(using: sortOrder)
    }

    /// The edge between the list and the details sidebar. Drag it to resize the sidebar.
    private var sidebarHandle: some View {
        Rectangle()
            .fill(Color.clear)
            .frame(width: 9)
            .frame(maxHeight: .infinity)
            .overlay(Divider())
            .contentShape(Rectangle())
            .onHover { inside in
                if inside { NSCursor.resizeLeftRight.push() } else { NSCursor.pop() }
            }
            .gesture(
                DragGesture(minimumDistance: 1, coordinateSpace: .global)
                    .onChanged { value in
                        let start = widthAtDragStart ?? sidebarWidth
                        widthAtDragStart = start
                        sidebarWidth = min(620, max(260, start - value.translation.width))
                    }
                    .onEnded { _ in widthAtDragStart = nil }
            )
            .help("Drag to resize the details sidebar")
    }

    /// Apps whose usual place now holds a launcher, mapped to where the real app is.
    private var replacedPaths: [String: String] {
        var paths: [String: String] = [:]
        for (path, entry) in seatbelts.entries {
            if let real = entry.originalPath { paths[path] = real }
        }
        return paths
    }

    private var selectedApp: AppRecord? {
        guard let selection else { return nil }
        return store.apps.first { $0.id == selection }
    }

    var body: some View {
        HStack(spacing: 0) {
            VStack(spacing: 0) {
                header
                Divider()
                table
                Divider()
                statusBar
            }

            // The details sidebar is an ordinary pane, not the system inspector: inside the
            // inspector, clicks were landing one row below where they were aimed.
            if showInspector {
                sidebarHandle
                DetailView(app: selectedApp)
                    .frame(width: sidebarWidth)
                    .frame(maxHeight: .infinity)
                    .background(theme.paper ?? Color(nsColor: .windowBackgroundColor))
            }
        }
        .searchable(text: $search, prompt: "Name, bundle ID, or team")
        .toolbar {
            ToolbarItemGroup {
                Toggle(isOn: $showApple) {
                    Label("Apple Apps", systemImage: "apple.logo")
                }
                .help("Include apps that ship with macOS")

                Button {
                    exportCSV()
                } label: {
                    Label("Export CSV", systemImage: "square.and.arrow.up")
                }
                .help("Export the current list as CSV")
                .disabled(visible.isEmpty)

                Button {
                    store.scan()
                } label: {
                    Label("Rescan", systemImage: "arrow.clockwise")
                }
                .help("Rescan installed applications")
                .disabled(store.isScanning)

                Button {
                    showInspector.toggle()
                } label: {
                    Label("Details", systemImage: "sidebar.trailing")
                }
                .help("Show or hide details")
            }
        }
        .task {
            seatbelts.telemetry = telemetry
            telemetry.managed = seatbelts.entries
            telemetry.start()
            store.replaced = replacedPaths
            store.scan()
        }
        .onChange(of: seatbelts.entries) {
            telemetry.managed = seatbelts.entries
            if store.replaced != replacedPaths {
                store.replaced = replacedPaths
                store.scan()
            }
        }
        .alert("Couldn't do that", isPresented: Binding(
            get: { problem != nil },
            set: { if !$0 { problem = nil } }
        )) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(problem ?? "")
        }
        .sheet(item: $managing) { app in
            ManageSheet(app: app) { _ in }
                .environmentObject(seatbelts)
        }
        .modifier(ThemeRoot(theme: theme))
    }

    // MARK: Header

    private var header: some View {
        let total = scoped.count
        let sandboxed = scoped.filter(\.isSandboxed).count
        let open = total - sandboxed
        let managed = scoped.filter { seatbelts.entries[$0.id] != nil }.count
        let exposedNow = scoped.filter { seatbelts.entries[$0.id] != nil && $0.runtime == .unsandboxed }.count

        return VStack(spacing: 10) {
            HStack(spacing: 10 + theme.gap * 2) {
                StatTile(title: "No sandbox", count: open, symbol: "lock.open.fill",
                         tint: Palette.orange, isActive: filter == .unprotected) { filter = .unprotected }
                StatTile(title: exposedNow == 0 ? "Managed" : "Managed · \(exposedNow) unprotected",
                         count: managed,
                         symbol: exposedNow == 0 ? "shield.lefthalf.filled" : "exclamationmark.shield.fill",
                         tint: exposedNow == 0 ? Palette.blue : Palette.red, isActive: filter == .managed) { filter = .managed }
                StatTile(title: "Sandboxed", count: sandboxed, symbol: "lock.shield.fill",
                         tint: Palette.green, isActive: filter == .sandboxed) { filter = .sandboxed }
                StatTile(title: "All applications", count: total, symbol: "square.grid.2x2.fill",
                         tint: .accentColor, isActive: filter == .all) { filter = .all }
            }
            CoverageBar(sandboxed: sandboxed, total: total)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 12)
    }

    // MARK: Table

    @ViewBuilder
    private var table: some View {
        if filter == .managed {
            managedCards
        } else {
            decorated(standardTable)
        }
    }

    private var standardTable: some View {
        Table(visible, selection: $selection, sortOrder: $sortOrder) {
            TableColumn("Application", value: \.name) { app in
                HStack(spacing: 8) {
                    Image(nsImage: NSWorkspace.shared.icon(forFile: app.url.path))
                        .resizable()
                        .frame(width: 20, height: 20)
                    Text(app.name)
                    if app.runtime == .unsandboxed {
                        Circle().fill(Palette.orange).frame(width: 6, height: 6)
                            .help(seatbelts.entries[app.id] != nil
                                  ? "Running right now without its seatbelt"
                                  : "Running right now without a sandbox")
                    } else if app.runtime == .sandboxed && seatbelts.entries[app.id] != nil {
                        Circle().fill(Palette.blue).frame(width: 6, height: 6)
                            .help("Running right now with its seatbelt")
                    }
                }
            }
            .width(min: 160, ideal: 220)

            TableColumn("Exposure", value: \.riskScore) { app in
                ExposureBadge(exposure: app.exposure)
            }
            .width(min: 110, ideal: 130)

            TableColumn("Sandbox", value: \.statusLabel) { app in
                StatusBadge(app: app, isManaged: seatbelts.entries[app.id] != nil)
            }
            .width(min: 100, ideal: 115)

            TableColumn("Manage") { app in
                if seatbelts.entries[app.id] != nil {
                    Label("Managed", systemImage: "shield.lefthalf.filled").foregroundStyle(Palette.blue)
                } else if SeatbeltStore.isEligible(app) {
                    Label("Can manage", systemImage: "plus.circle")
                } else if app.isSandboxed {
                    Text("Not needed").foregroundStyle(.tertiary)
                } else {
                    Label("Part of macOS", systemImage: "nosign").foregroundStyle(.secondary)
                }
            }
            .width(min: 100, ideal: 125)

            TableColumn("Signature", value: \.signingLabel)
                .width(min: 90, ideal: 130)
        }
    }

    /// The Managed view is a set of cards, one per app, each saying what that app is kept from.
    private var managedCards: some View {
        ScrollView {
            if theme.showsHeadings {
                SectionHeading(title: "Managed applications", trailing: "\(visible.count)")
                    .padding([.horizontal, .top], 14)
            }
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 320, maximum: 460), spacing: 20, alignment: .top)],
                      alignment: .leading, spacing: 20) {
                ForEach(visible) { app in
                    ManagedCard(app: app, isSelected: selection == app.id) {
                        selection = app.id
                        showInspector = true
                    }
                        .onTapGesture(count: 2) {
                            selection = app.id
                            showInspector = true
                        }
                        .onTapGesture { selection = app.id }
                        .contextMenu {
                            Button("Reveal Launcher") {
                                NSWorkspace.shared.activateFileViewerSelecting([seatbelts.launcherURL(for: app)])
                            }
                            Button("Reveal in Finder") { reveal(app) }
                            Button("Copy Path") { copy(app.url.path) }
                            Divider()
                            Button("Delete from Managed Applications", role: .destructive) {
                                attempt { try seatbelts.remove(app) }
                            }
                        }
                }
            }
            .padding(14)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(theme.paper ?? Color(nsColor: .windowBackgroundColor))
        .overlay {
            if visible.isEmpty && !store.isScanning {
                ContentUnavailableView(
                    "No managed applications",
                    systemImage: "shield.lefthalf.filled",
                    description: Text("Right-click an app with no sandbox and choose Manage.")
                )
            }
        }
    }

    /// Row menu, double-click and empty states shared by both tables.
    private func decorated<Content: View>(_ content: Content) -> some View {
        content
        .clipShape(RoundedRectangle(cornerRadius: theme.panel.corner, style: .continuous))
        .themedPanel()
        .padding(.leading, themed ? 14 : 0)
        .padding(.top, themed ? 6 : 0)
        .padding(.trailing, themed ? 14 + theme.gap : 0)
        .padding(.bottom, themed ? 10 + theme.gap : 0)
        .contextMenu(forSelectionType: AppRecord.ID.self) { ids in
            if let id = ids.first, let app = store.apps.first(where: { $0.id == id }) {
                if seatbelts.entries[app.id] != nil {
                    Button("Launch Protected") {
                        attempt { try seatbelts.launch(app) }
                        store.scan(after: 2)
                    }
                    Button("Reveal Launcher") {
                        NSWorkspace.shared.activateFileViewerSelecting([seatbelts.launcherURL(for: app)])
                    }
                    Button("Stop Managing") { attempt { try seatbelts.remove(app) } }
                    Divider()
                } else if SeatbeltStore.isEligible(app) {
                    Button("Manage…") {
                        selection = app.id
                        managing = app
                    }
                    Divider()
                } else {
                    Button(app.isSandboxed ? "Already sandboxed" : "Can't manage: part of macOS") {}
                        .disabled(true)
                    Divider()
                }
                Button("Reveal in Finder") { reveal(app) }
                Button("Copy Path") { copy(app.url.path) }
                Button("Copy Bundle ID") { copy(app.bundleID) }
            }
        } primaryAction: { ids in
            // Double-click opens the details sidebar for that app.
            if let id = ids.first {
                selection = id
                showInspector = true
            }
        }
        .overlay {
            if store.isScanning && store.apps.isEmpty {
                ProgressView("Reading code signatures…")
            } else if visible.isEmpty && !store.isScanning {
                switch filter {
                case .unprotected:
                    ContentUnavailableView(
                        "Everything here is sandboxed",
                        systemImage: "checkmark.shield",
                        description: Text("Nothing matches the current filter.")
                    )
                default:
                    ContentUnavailableView(
                        "No applications",
                        systemImage: "magnifyingglass",
                        description: Text("Nothing matches the current filter.")
                    )
                }
            }
        }
    }

    private var statusBar: some View {
        HStack(spacing: 8) {
            if store.isScanning {
                ProgressView().controlSize(.small)
                Text("Scanning…")
            } else {
                Text("\(visible.count) shown")
                if filter == .unprotected {
                    let manageable = visible.filter { SeatbeltStore.isEligible($0) }.count
                    Text("·")
                    Text("\(manageable) can be managed, \(visible.count - manageable) are part of macOS")
                }
                if let last = store.lastScan {
                    Text("·")
                    Text("Scanned \(last.formatted(date: .omitted, time: .shortened))")
                }
            }
            Spacer()
            Text(filter == .managed
                 ? "What each managed app can reach when launched from Artemis"
                 : "Based on the com.apple.security.app-sandbox entitlement in each app's signature")
                .truncationMode(.tail)
                .layoutPriority(-1)
        }
        .lineLimit(1)
        .font(.caption)
        .foregroundStyle(.secondary)
        .padding(.horizontal, 14)
        .padding(.vertical, 6)
    }

    // MARK: Actions

    private func attempt(_ action: () throws -> Void) {
        do { try action() } catch { problem = error.localizedDescription }
    }

    private func reveal(_ app: AppRecord) {
        NSWorkspace.shared.activateFileViewerSelecting([app.url])
    }

    private func copy(_ text: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
    }

    private func exportCSV() {
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.commaSeparatedText]
        panel.nameFieldStringValue = "artemis-\(filter.rawValue).csv"
        guard panel.runModal() == .OK, let url = panel.url else { return }

        func field(_ value: String) -> String {
            "\"" + value.replacingOccurrences(of: "\"", with: "\"\"") + "\""
        }

        var lines = ["name,bundle_id,version,sandboxed,exposure,exposure_reasons,signature,hardened_runtime,source,team_id,runtime,path"]
        for app in visible {
            lines.append([
                field(app.name), field(app.bundleID), field(app.version),
                app.isSandboxed ? "true" : "false",
                field(app.exposure.label), field(app.exposure.reasons.joined(separator: "; ")),
                field(app.signing.rawValue),
                app.hardenedRuntime ? "true" : "false",
                field(app.sourceLabel), field(app.teamID),
                field(app.runtimeLabel), field(app.url.path),
            ].joined(separator: ","))
        }
        try? lines.joined(separator: "\n").write(to: url, atomically: true, encoding: .utf8)
    }
}

// MARK: - Pieces

struct StatTile: View {
    let title: String
    let count: Int
    let symbol: String
    let tint: Color
    let isActive: Bool
    let action: () -> Void
    @Environment(\.theme) private var theme
    private var themed: Bool { theme.isCustom }

    var body: some View {
        Button(action: action) {
            HStack(spacing: 12) {
                Image(systemName: symbol)
                    .font(.title2)
                    .foregroundStyle(tint)
                    .frame(width: 30)
                VStack(alignment: .leading, spacing: 1) {
                    Text("\(count)")
                        .font(.system(.title, design: .rounded, weight: .semibold))
                        .monospacedDigit()
                        .lineLimit(1)
                    Text(theme.uppercaseLabels ? title.uppercased() : title)
                        .font(themed ? .caption.weight(.medium) : .caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .minimumScaleFactor(0.7)
                }
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 10)
            .background(
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .fill(isActive ? tint.opacity(0.14) : Color(nsColor: .controlBackgroundColor))
                    .opacity(themed ? 0 : 1)
            )
            .overlay(
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .strokeBorder(isActive ? tint.opacity(0.55) : Color(nsColor: .separatorColor), lineWidth: 1)
                    .opacity(themed ? 0 : 1)
            )
            .themedPanel(tint: isActive ? tint.opacity(0.22) : nil, isSelection: true)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel("\(title): \(count)")
        .accessibilityAddTraits(isActive ? .isSelected : [])
    }
}

/// Thin proportion bar: how much of the scanned set is sandboxed.
struct CoverageBar: View {
    let sandboxed: Int
    let total: Int

    private var fraction: Double { total == 0 ? 0 : Double(sandboxed) / Double(total) }

    var body: some View {
        HStack(spacing: 10) {
            GeometryReader { geo in
                ZStack(alignment: .leading) {
                    Capsule().fill(Palette.orange.opacity(0.55))
                    Capsule().fill(Palette.green)
                        .frame(width: max(0, geo.size.width * fraction))
                }
            }
            .frame(height: 6)
            Text("\(Int((fraction * 100).rounded()))% sandboxed")
                .font(.caption)
                .monospacedDigit()
                .foregroundStyle(.secondary)
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(Int((fraction * 100).rounded())) percent of applications are sandboxed")
    }
}

struct StatusBadge: View {
    let app: AppRecord
    var isManaged = false

    var body: some View {
        let layered = app.isLayered && !isManaged
        let tint: Color = isManaged ? Palette.blue
            : app.isSandboxed ? Palette.green
            : layered ? Palette.indigo
            : (app.signing == .unsigned ? Palette.red : Palette.orange)
        let symbol = isManaged ? "shield.lefthalf.filled"
            : app.isSandboxed ? "lock.shield.fill"
            : layered ? "square.stack.3d.up.fill" : "lock.open.fill"
        Label(isManaged ? "Managed" : app.statusLabel, systemImage: symbol)
            .help(layered
                  ? "The main process has no App Sandbox, but \(app.sandboxLayers) kinds of helper process (web pages, GPU, network…) each run in a sandbox of their own. See Sandbox layers in the details."
                  : "")
            .font(.caption.weight(.semibold))
            .foregroundStyle(tint)
            .padding(.horizontal, 7)
            .padding(.vertical, 2)
            .background(Capsule().fill(tint.opacity(0.16)))
            .overlay(Capsule().strokeBorder(tint.opacity(layered ? 0.75 : 0.35), lineWidth: 1))
    }
}

/// One managed app: what state it is in, what it is kept from, and the button to start it.
struct ManagedCard: View {
    let app: AppRecord
    let isSelected: Bool
    /// Opens the details sidebar for this app.
    let showOptions: () -> Void
    @EnvironmentObject private var seatbelts: SeatbeltStore
    @EnvironmentObject private var store: AppStore
    @EnvironmentObject private var telemetry: TelemetryStore
    @State private var isStarting = false
    @State private var problem: String?
    @State private var confirmReplace = false
    @Environment(\.theme) private var theme
    private var themed: Bool { theme.isCustom }

    private var options: SeatbeltOptions { seatbelts.entries[app.id]?.options ?? SeatbeltOptions() }

    private var state: (text: String, symbol: String, tint: Color) {
        switch app.runtime {
        case .sandboxed: return ("Protected now", "checkmark.shield.fill", Palette.green)
        case .unsandboxed: return ("Running unprotected", "exclamationmark.shield.fill", Palette.red)
        case .notRunning: return ("Not running", "shield.lefthalf.filled", Palette.blue)
        }
    }

    private var isUnprotected: Bool { app.runtime == .unsandboxed }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            if isUnprotected {
                // Impossible to miss: the seatbelt exists but is not on this running copy.
                Label {
                    VStack(alignment: .leading, spacing: 1) {
                        Text("RUNNING UNPROTECTED").font(.headline.weight(.heavy))
                        Text("Opened outside Artemis. None of the blocks below are in force.")
                            .font(.caption.weight(.medium))
                    }
                } icon: {
                    Image(systemName: "exclamationmark.triangle.fill").font(.title2)
                }
                .foregroundStyle(.white)
                .padding(.horizontal, 12)
                .padding(.vertical, 8)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(Palette.red)
            }

            HStack(spacing: 10) {
                Image(nsImage: NSWorkspace.shared.icon(forFile: app.url.path))
                    .resizable()
                    .frame(width: 40, height: 40)
                VStack(alignment: .leading, spacing: 2) {
                    Text(app.name).font(.title3.weight(.semibold))
                    Label(state.text, systemImage: state.symbol)
                        .font(.callout.weight(.medium))
                        .foregroundStyle(state.tint)
                }
                Spacer(minLength: 0)
            }

            VStack(alignment: .leading, spacing: 4) {
                ForEach(SeatbeltProfile.stanza(options: options), id: \.self) { line in
                    if isUnprotected {
                        // Struck through: these are not being enforced right now.
                        Label { Text(line).strikethrough() } icon: { Image(systemName: "lock.slash.fill") }
                            .font(.callout)
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    } else {
                        Label { emphasized(line) } icon: { Image(systemName: "lock.fill") }
                            .font(.callout)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                let open = SeatbeltProfile.stillOpen(options: options)
                if !open.isEmpty && !isUnprotected {
                    Label("Not restricted: " + open.joined(separator: "; ") + ".", systemImage: "lock.open.fill")
                        .font(.callout)
                        .foregroundStyle(Palette.orange)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }

            if seatbelts.entries[app.id]?.isReplaced == true {
                Label("Replaces the original: opening it the usual way starts it protected.",
                      systemImage: "arrow.triangle.2.circlepath")
                    .font(.caption)
                    .foregroundStyle(Palette.blue)
            }

            VitalsStrip(samples: telemetry.traces[app.id] ?? [], isLive: app.runtime == .sandboxed)

            ActivitySummary(activity: telemetry.activity(for: app.id))

            if let problem {
                Text(problem)
                    .font(.caption)
                    .foregroundStyle(Palette.red)
                    .fixedSize(horizontal: false, vertical: true)
                    .textSelection(.enabled)
            }

            HStack {
                Button(isStarting ? "Starting…" : (isUnprotected ? "Quit & Relaunch Protected" : "Launch Protected")) {
                    problem = nil
                    isStarting = true
                    Task {
                        do {
                            if isUnprotected { try await seatbelts.quit(app) }
                            try await seatbelts.launchAndWatch(app)
                            store.scan()
                        } catch {
                            problem = error.localizedDescription
                        }
                        isStarting = false
                    }
                }
                .buttonStyle(.borderedProminent)
                .tint(isUnprotected ? Palette.red : nil)
                .disabled(app.runtime == .sandboxed || isStarting)

                if seatbelts.entries[app.id]?.isReplaced == true {
                    Button("Restore Original App") {
                        do { try seatbelts.restore(app); problem = nil } catch { problem = error.localizedDescription }
                    }
                    .disabled(app.runtime != .notRunning)
                } else {
                    Button("Replace App…") { confirmReplace = true }
                        .disabled(app.runtime != .notRunning)
                }

                Spacer(minLength: 0)
                Button("Options") { showOptions() }
            }
        }
        .confirmationDialog("Replace \(app.name) with its protected launcher?", isPresented: $confirmReplace) {
            Button("Replace App") {
                do { try seatbelts.replace(app); problem = nil } catch { problem = error.localizedDescription }
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Artemis moves the real app to ~/Applications/Managed Applications/Originals and puts a launcher with the same name and icon in its place. macOS may ask for permission to change apps. Files and links that open in \(app.name) can still start it without its seatbelt, and its own updater may complain that it has moved. Restore Original App undoes this.")
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(Color(nsColor: .controlBackgroundColor))
                .opacity(themed ? 0 : 1)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .strokeBorder(isSelected ? Color.accentColor : Color(nsColor: .separatorColor),
                              lineWidth: isSelected ? 2 : 1)
                .opacity(themed ? 0 : 1)
        )
        .themedPanel(tint: isSelected ? Color.accentColor.opacity(0.12) : nil, isSelection: true)
        .overlay(
            RoundedRectangle(cornerRadius: themed ? theme.panel.corner : 12, style: .continuous)
                .strokeBorder(Palette.red, lineWidth: isUnprotected ? 4 : 0)
                .allowsHitTesting(false)
        )
        .contentShape(Rectangle())
    }
}

/// The few lines of logging shown on a managed app's card.
struct ActivitySummary: View {
    let activity: AppActivity

    private var blockedText: String {
        guard activity.blocked > 0 else { return "No blocked attempts recorded." }
        let top = activity.byCategory.prefix(3).map { "\($0.name) ×\($0.count)" }.joined(separator: ", ")
        return "\(activity.blocked) blocked \(activity.blocked == 1 ? "attempt" : "attempts"): \(top)."
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Divider()
            Label(blockedText, systemImage: "hand.raised.fill")
                .foregroundStyle(activity.blocked > 0 ? Color.primary : Color.secondary)
            if activity.unprotectedRuns > 0 {
                Label("Opened without its seatbelt \(activity.unprotectedRuns) \(activity.unprotectedRuns == 1 ? "time" : "times").",
                      systemImage: "exclamationmark.triangle.fill")
                    .foregroundStyle(Palette.orange)
            }
            if let last = activity.lastProtectedLaunch {
                Label("Last protected launch \(last.formatted(date: .abbreviated, time: .shortened)). \(activity.protectedLaunches) in total.",
                      systemImage: "play.fill")
                    .foregroundStyle(.secondary)
            } else {
                Label("Never launched with its seatbelt.", systemImage: "play.slash.fill")
                    .foregroundStyle(.secondary)
            }
        }
        .font(.caption)
    }
}

/// How exposed an app is to outside content and to agents, as a small coloured tag.
struct ExposureBadge: View {
    let exposure: Exposure

    var body: some View {
        let both = !exposure.pull.isEmpty && !exposure.push.isEmpty
        let none = exposure.pull.isEmpty && exposure.push.isEmpty
        let tint: Color = both ? Palette.red : (none ? .secondary : Palette.orange)
        let symbol = both ? "arrow.up.arrow.down.circle.fill"
            : exposure.push.isEmpty ? (none ? "minus.circle" : "arrow.down.circle.fill") : "arrow.up.circle.fill"
        Label(exposure.label, systemImage: symbol)
            .font(.caption.weight(.semibold))
            .foregroundStyle(tint)
            .help(none ? "No signs that it pulls in outside content or acts for an agent"
                  : exposure.reasons.joined(separator: "\n"))
    }
}

/// A live, EEG-style trace of a protected app: one line each for CPU, disk reads, disk writes
/// and blocked attempts, scrolling right to left over the last two minutes.
struct VitalsStrip: View {
    let samples: [VitalSample]
    let isLive: Bool

    private struct Channel {
        let name: String
        let color: Color
        let value: KeyPath<VitalSample, Double>
        /// The smallest full-scale value, so idle noise doesn't fill the row.
        let floor: Double
    }

    private let channels = [
        Channel(name: "CPU", color: Palette.green, value: \.cpu, floor: 25),
        Channel(name: "READ", color: Palette.blue, value: \.read, floor: 256_000),
        Channel(name: "WRITE", color: .purple, value: \.write, floor: 256_000),
        Channel(name: "BLOCK", color: Palette.red, value: \.blocked, floor: 1),
    ]

    private var caption: String {
        guard isLive, let last = samples.last else { return "No signal: not running with its seatbelt." }
        func rate(_ bytes: Double) -> String {
            bytes >= 1_048_576 ? String(format: "%.1f MB/s", bytes / 1_048_576) : String(format: "%.0f KB/s", bytes / 1024)
        }
        return String(format: "CPU %.0f%%", last.cpu) + " · read " + rate(last.read) + " · write " + rate(last.write)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Canvas { context, size in
                let labelWidth: CGFloat = 40
                let rowHeight = size.height / CGFloat(channels.count)
                let step = (size.width - labelWidth) / CGFloat(TelemetryStore.traceLength - 1)

                for (index, channel) in channels.enumerated() {
                    let top = rowHeight * CGFloat(index) + 3
                    let base = rowHeight * CGFloat(index + 1) - 3

                    context.draw(
                        Text(channel.name)
                            .font(.system(size: 8, weight: .semibold, design: .monospaced))
                            .foregroundColor(.secondary),
                        at: CGPoint(x: 0, y: (top + base) / 2), anchor: .leading
                    )

                    var rule = Path()
                    rule.move(to: CGPoint(x: labelWidth, y: base))
                    rule.addLine(to: CGPoint(x: size.width, y: base))
                    context.stroke(rule, with: .color(Color.secondary.opacity(0.25)), lineWidth: 0.5)

                    guard isLive, samples.count > 1 else { continue }
                    let values = samples.map { $0[keyPath: channel.value] }
                    let peak = max(values.max() ?? 0, channel.floor)
                    let offset = TelemetryStore.traceLength - values.count

                    var trace = Path()
                    for (position, value) in values.enumerated() {
                        let point = CGPoint(
                            x: labelWidth + CGFloat(offset + position) * step,
                            y: base - CGFloat(value / peak) * (base - top)
                        )
                        if position == 0 { trace.move(to: point) } else { trace.addLine(to: point) }
                    }
                    context.stroke(trace, with: .color(channel.color), lineWidth: 1.2)
                }
            }
            .frame(height: 76)

            Text(caption)
                .font(.system(.caption2, design: .monospaced))
                .foregroundStyle(.secondary)
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(caption)
    }
}
