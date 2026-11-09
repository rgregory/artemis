import AppKit
import SwiftUI
import UniformTypeIdentifiers

enum Filter: String, CaseIterable {
    case unprotected, sandboxed, all
}

struct ContentView: View {
    @EnvironmentObject private var store: AppStore

    @State private var filter: Filter = .unprotected
    @State private var showApple = true
    @State private var search = ""
    @State private var selection: AppRecord.ID?
    @State private var sortOrder = [KeyPathComparator(\AppRecord.name)]
    @State private var showInspector = true

    /// Everything in scope (Apple toggle applied), before the sandbox filter and search.
    private var scoped: [AppRecord] {
        showApple ? store.apps : store.apps.filter { !$0.isApple }
    }

    private var visible: [AppRecord] {
        var rows = scoped
        switch filter {
        case .unprotected: rows = rows.filter { !$0.isSandboxed }
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

    private var selectedApp: AppRecord? {
        guard let selection else { return nil }
        return store.apps.first { $0.id == selection }
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            table
            Divider()
            statusBar
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
        .inspector(isPresented: $showInspector) {
            DetailView(app: selectedApp)
                .inspectorColumnWidth(min: 260, ideal: 320, max: 460)
        }
        .task { store.scan() }
    }

    // MARK: Header

    private var header: some View {
        let total = scoped.count
        let sandboxed = scoped.filter(\.isSandboxed).count
        let open = total - sandboxed

        return VStack(spacing: 10) {
            HStack(spacing: 10) {
                StatTile(title: "No sandbox", count: open, symbol: "lock.open.fill",
                         tint: .orange, isActive: filter == .unprotected) { filter = .unprotected }
                StatTile(title: "Sandboxed", count: sandboxed, symbol: "lock.shield.fill",
                         tint: .green, isActive: filter == .sandboxed) { filter = .sandboxed }
                StatTile(title: "All applications", count: total, symbol: "square.grid.2x2.fill",
                         tint: .accentColor, isActive: filter == .all) { filter = .all }
            }
            CoverageBar(sandboxed: sandboxed, total: total)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 12)
    }

    // MARK: Table

    private var table: some View {
        Table(visible, selection: $selection, sortOrder: $sortOrder) {
            TableColumn("Application", value: \.name) { app in
                HStack(spacing: 8) {
                    Image(nsImage: NSWorkspace.shared.icon(forFile: app.url.path))
                        .resizable()
                        .frame(width: 20, height: 20)
                    Text(app.name)
                    if app.runtime == .unsandboxed {
                        Circle().fill(.orange).frame(width: 6, height: 6)
                            .help("Running right now without a sandbox")
                    }
                }
            }
            .width(min: 160, ideal: 220)

            TableColumn("Sandbox", value: \.statusLabel) { app in
                StatusBadge(app: app)
            }
            .width(min: 100, ideal: 115)

            TableColumn("Signature", value: \.signingLabel)
                .width(min: 90, ideal: 130)

            TableColumn("Source", value: \.sourceLabel)
                .width(min: 80, ideal: 100)
        }
        .contextMenu(forSelectionType: AppRecord.ID.self) { ids in
            if let id = ids.first, let app = store.apps.first(where: { $0.id == id }) {
                Button("Reveal in Finder") { reveal(app) }
                Button("Copy Path") { copy(app.url.path) }
                Button("Copy Bundle ID") { copy(app.bundleID) }
            }
        } primaryAction: { ids in
            if let id = ids.first, let app = store.apps.first(where: { $0.id == id }) {
                reveal(app)
            }
        }
        .overlay {
            if store.isScanning && store.apps.isEmpty {
                ProgressView("Reading code signatures…")
            } else if visible.isEmpty && !store.isScanning {
                ContentUnavailableView(
                    filter == .unprotected ? "Everything here is sandboxed" : "No applications",
                    systemImage: filter == .unprotected ? "checkmark.shield" : "magnifyingglass",
                    description: Text("Nothing matches the current filter.")
                )
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
                if let last = store.lastScan {
                    Text("·")
                    Text("Scanned \(last.formatted(date: .omitted, time: .shortened))")
                }
            }
            Spacer()
            Text("Based on the com.apple.security.app-sandbox entitlement in each app's signature")
        }
        .font(.caption)
        .foregroundStyle(.secondary)
        .padding(.horizontal, 14)
        .padding(.vertical, 6)
    }

    // MARK: Actions

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

        var lines = ["name,bundle_id,version,sandboxed,signature,hardened_runtime,source,team_id,runtime,path"]
        for app in visible {
            lines.append([
                field(app.name), field(app.bundleID), field(app.version),
                app.isSandboxed ? "true" : "false",
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
                    Text(title)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 10)
            .background(
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .fill(isActive ? tint.opacity(0.14) : Color(nsColor: .controlBackgroundColor))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .strokeBorder(isActive ? tint.opacity(0.55) : Color(nsColor: .separatorColor), lineWidth: 1)
            )
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
                    Capsule().fill(Color.orange.opacity(0.55))
                    Capsule().fill(Color.green)
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

    var body: some View {
        let tint: Color = app.isSandboxed ? .green : (app.signing == .unsigned ? .red : .orange)
        let symbol = app.isSandboxed ? "lock.shield.fill" : "lock.open.fill"
        Label(app.statusLabel, systemImage: symbol)
            .font(.caption.weight(.medium))
            .foregroundStyle(tint)
            .padding(.horizontal, 7)
            .padding(.vertical, 2)
            .background(Capsule().fill(tint.opacity(0.14)))
    }
}
