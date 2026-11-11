import AppKit
import SwiftUI

struct DetailView: View {
    let app: AppRecord?
    @EnvironmentObject private var seatbelts: SeatbeltStore
    @Environment(\.theme) private var theme
    private var themed: Bool { theme.isCustom }

    var body: some View {
        if let app {
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    HStack(spacing: 12) {
                        Image(nsImage: NSWorkspace.shared.icon(forFile: app.url.path))
                            .resizable()
                            .frame(width: 56, height: 56)
                        VStack(alignment: .leading, spacing: 3) {
                            Text(app.name).font(.title3.weight(.semibold))
                            if !app.version.isEmpty {
                                Text("Version \(app.version)").font(.caption).foregroundStyle(.secondary)
                            }
                            StatusBadge(app: app, isManaged: seatbelts.entries[app.id] != nil)
                        }
                    }

                    if let entry = seatbelts.entries[app.id] {
                        ProtectionStanza(name: app.name, options: entry.options, runtime: app.runtime)
                    } else {
                        Text(explanation(for: app))
                            .font(.callout)
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }

                    if SeatbeltStore.isEligible(app) {
                        SeatbeltSection(app: app, saved: seatbelts.entries[app.id]?.options)
                            .id(app.id)
                    }

                    Panel {
                        VStack(alignment: .leading, spacing: 6) {
                            HStack {
                                Text("Exposure").font(.headline)
                                Spacer()
                                ExposureBadge(exposure: app.exposure)
                            }
                            if app.exposure.reasons.isEmpty {
                                Text("No signs that it pulls in outside content or acts on instructions from an agent.")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                                    .fixedSize(horizontal: false, vertical: true)
                            } else {
                                ForEach(app.exposure.push, id: \.self) { reason in
                                    Label(reason, systemImage: "arrow.up.circle.fill")
                                        .font(.caption)
                                        .fixedSize(horizontal: false, vertical: true)
                                }
                                ForEach(app.exposure.pull, id: \.self) { reason in
                                    Label(reason, systemImage: "arrow.down.circle.fill")
                                        .font(.caption)
                                        .fixedSize(horizontal: false, vertical: true)
                                }
                            }
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(4)
                    }

                    if seatbelts.entries[app.id] != nil {
                        ActivitySection(app: app)
                    }

                    Panel {
                        VStack(alignment: .leading, spacing: 6) {
                            fact("Signature", app.signingLabel)
                            fact("Source", app.sourceLabel)
                            fact("Team ID", app.teamID.isEmpty ? "None" : app.teamID)
                            fact("Process", app.runtimeLabel)
                            fact("Bundle ID", app.bundleID.isEmpty ? "None" : app.bundleID)
                            fact("Location", app.location)
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(4)
                    }

                    HStack {
                        Button("Reveal in Finder") {
                            NSWorkspace.shared.activateFileViewerSelecting([app.url])
                        }
                        Button("Copy Path") {
                            NSPasteboard.general.clearContents()
                            NSPasteboard.general.setString(app.url.path, forType: .string)
                        }
                    }

                    VStack(alignment: .leading, spacing: 6) {
                        Text("Entitlements (\(app.entitlements.count))").font(.headline)
                        if app.entitlements.isEmpty {
                            Text("This app's signature declares no entitlements.")
                                .font(.callout)
                                .foregroundStyle(.secondary)
                        } else {
                            ForEach(app.entitlements) { item in
                                VStack(alignment: .leading, spacing: 1) {
                                    Text(item.key)
                                        .font(.system(.caption, design: .monospaced))
                                        .textSelection(.enabled)
                                    Text(item.value)
                                        .font(.system(.caption, design: .monospaced))
                                        .foregroundStyle(.secondary)
                                        .textSelection(.enabled)
                                }
                                .padding(.vertical, 2)
                            }
                        }
                    }
                }
                .padding(16)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        } else {
            ContentUnavailableView(
                "No Selection",
                systemImage: "app.dashed",
                description: Text("Select an application to see its signature and entitlements.")
            )
        }
    }

    private func fact(_ label: String, _ value: String) -> some View {
        VStack(alignment: .leading, spacing: 1) {
            Text(theme.uppercaseLabels ? label.uppercased() : label).font(.caption).foregroundStyle(.secondary)
            Text(value).font(.callout).textSelection(.enabled)
        }
    }

    private func explanation(for app: AppRecord) -> String {
        if app.isIOSApp {
            return "An iPhone or iPad app. These always run inside a container on macOS."
        }
        if app.isSandboxed {
            return "Opts in to App Sandbox. The system limits it to its own container plus whatever its entitlements below allow."
        }
        switch app.signing {
        case .unsigned:
            return "Not code signed and not sandboxed. It runs with your full user permissions, and its origin can't be verified."
        case .adHoc:
            return "Ad hoc signed and not sandboxed. It runs with your full user permissions, limited only by macOS privacy prompts."
        case .signed:
            return "Not sandboxed. It runs with your full user permissions, limited only by macOS privacy prompts (TCC) and System Integrity Protection."
        }
    }
}

/// Add, adjust, launch or remove one unsandboxed app as a Managed Application.
struct SeatbeltSection: View {
    let app: AppRecord
    @EnvironmentObject private var seatbelts: SeatbeltStore
    @EnvironmentObject private var store: AppStore
    @State private var options: SeatbeltOptions
    @State private var problem: String?
    @State private var isStarting = false
    @State private var showDetails = false
    @State private var showManage = false
    @State private var confirmReplace = false

    init(app: AppRecord, saved: SeatbeltOptions?) {
        self.app = app
        _options = State(initialValue: saved ?? SeatbeltOptions())
    }

    private var entry: SeatbeltEntry? { seatbelts.entries[app.id] }
    private var hasUnsavedChanges: Bool { entry != nil && entry?.options != options }

    var body: some View {
        Panel {
            VStack(alignment: .leading, spacing: 10) {
                Text("Managed Application").font(.headline)

                HStack {
                    if entry == nil {
                        Button("Manage \(app.name)…") { showManage = true }
                            .buttonStyle(.borderedProminent)
                    } else {
                        Button(isStarting ? "Starting…" : "Launch Protected") { launchProtected() }
                        .buttonStyle(.borderedProminent)
                        .disabled(app.runtime != .notRunning || hasUnsavedChanges || isStarting)
                        Button("Stop Managing", role: .destructive) {
                            attempt { try seatbelts.remove(app) }
                        }
                    }
                }

                if let problem {
                    Text(problem)
                        .font(.caption)
                        .foregroundStyle(.red)
                        .fixedSize(horizontal: false, vertical: true)
                        .textSelection(.enabled)
                }

                Divider()

                Text("Options").font(.subheadline.weight(.semibold))
                CheckRow(options.blockNetwork ? "Block incoming connections (included below)" : "Block incoming connections",
                         isOn: options.blockNetwork ? .constant(true) : $options.blockIncoming)
                    .disabled(options.blockNetwork)
                CheckRow("Block all network access", isOn: $options.blockNetwork)
                CheckRow("Block Documents, Desktop, Downloads and iCloud", isOn: $options.protectUserFolders)
                CheckRow("Block the Keychain (breaks browsers and saved passwords)", isOn: $options.blockKeychain)
                if app.ownSandbox != nil {
                    CheckRow("Turn off \(app.name)'s own sandbox (needed for it to run managed)",
                             isOn: $options.disableOwnSandbox)
                }

                if hasUnsavedChanges {
                    HStack {
                        Button("Save Changes") { attempt { try seatbelts.apply(app, options: options) } }
                        Text(app.runtime == .sandboxed ? "Takes effect the next time it is launched." : "Not saved yet.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }

                Divider()

                Disclosure(isExpanded: $showDetails) {
                    Text(entry == nil ? "What managing it would block" : "Exactly what is blocked")
                        .font(.subheadline)
                } content: {
                    VStack(alignment: .leading, spacing: 4) {
                        ForEach(SeatbeltProfile.protections(appName: app.name, bundleID: app.bundleID, options: options)) { group in
                            ProtectionRow(group: group)
                        }
                    }
                    .padding(.top, 4)
                }

                if let entry {
                    Divider()
                    Text("Replace App").font(.subheadline.weight(.semibold))
                    Text(entry.isReplaced
                         ? "\(app.name) is replaced. Opening it from the Dock, Finder or Spotlight starts it with its seatbelt. The real app is in Managed Applications/Originals."
                         : "Put the protected launcher where \(app.name) is now, so opening it the usual way starts it with its seatbelt.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                    if entry.isReplaced {
                        Button("Restore Original App") { attempt { try seatbelts.restore(app) } }
                            .disabled(app.runtime != .notRunning)
                    } else {
                        Button("Replace App…") { confirmReplace = true }
                            .disabled(app.runtime != .notRunning)
                    }
                }

                if entry != nil {
                    Divider()
                    HStack {
                        Button("Reveal Launcher") {
                            NSWorkspace.shared.activateFileViewerSelecting([seatbelts.launcherURL(for: app)])
                        }
                        Button("Reveal Profile") {
                            NSWorkspace.shared.activateFileViewerSelecting([seatbelts.profileURL(for: app)])
                        }
                    }
                    .controlSize(.small)
                    Text("The launcher is a second copy of the app's icon in ~/Applications/Managed Applications. Opening it does the same as Launch Protected.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .toggleStyle(.checkbox)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(4)
        }
        .sheet(isPresented: $showManage) {
            ManageSheet(app: app, initial: options) { saved in options = saved }
                .environmentObject(seatbelts)
        }
        .confirmationDialog("Replace \(app.name) with its protected launcher?", isPresented: $confirmReplace) {
            Button("Replace App") { attempt { try seatbelts.replace(app) } }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Artemis moves the real app to ~/Applications/Managed Applications/Originals and puts a launcher with the same name and icon in its place. macOS may ask for permission to change apps. Files and links that open in \(app.name) can still start it without its seatbelt, and its own updater may complain that it has moved. Restore Original App undoes this.")
        }
    }

    private func launchProtected() {
        problem = nil
        isStarting = true
        Task {
            do {
                try await seatbelts.launchAndWatch(app)
                store.scan()
            } catch {
                problem = error.localizedDescription
            }
            isStarting = false
        }
    }

    private func attempt(_ action: () throws -> Void) {
        do {
            try action()
            problem = nil
        } catch {
            problem = error.localizedDescription
        }
    }
}

/// One expandable group in the list of what a seatbelt blocks.
struct ProtectionRow: View {
    let group: SeatbeltProtection
    @State private var expanded = false

    var body: some View {
        Disclosure(isExpanded: $expanded) {
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                Image(systemName: group.symbol)
                    .foregroundStyle(group.isBlocked ? Color.blue : Color.orange)
                    .frame(width: 16)
                Text(group.title).font(.caption.weight(.medium))
                Spacer(minLength: 4)
                Text(group.short).font(.caption2).foregroundStyle(.secondary)
            }
        } content: {
            VStack(alignment: .leading, spacing: 2) {
                emphasized(group.rule).font(.caption2).foregroundStyle(.secondary)
                ForEach(group.items, id: \.self) { item in
                    Text(item)
                        .font(group.arePaths ? .system(.caption, design: .monospaced) : .caption)
                        .textSelection(.enabled)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.leading, 18)
            .padding(.top, 2)
        }
    }
}

/// A row that shows or hides what is under it. The whole row is the button, not just the arrow.
struct Disclosure<Label: View, Content: View>: View {
    @Binding var isExpanded: Bool
    private let label: Label
    private let content: Content

    init(isExpanded: Binding<Bool>, @ViewBuilder label: () -> Label, @ViewBuilder content: () -> Content) {
        _isExpanded = isExpanded
        self.label = label()
        self.content = content()
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Button {
                isExpanded.toggle()
            } label: {
                HStack(alignment: .firstTextBaseline, spacing: 6) {
                    Image(systemName: "chevron.right")
                        .font(.caption2.weight(.bold))
                        .foregroundStyle(.secondary)
                        .rotationEffect(.degrees(isExpanded ? 90 : 0))
                    label
                    Spacer(minLength: 0)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityValue(isExpanded ? "Expanded" : "Collapsed")

            if isExpanded { content }
        }
    }
}

/// The short statement at the top of the panel for a managed app.
struct ProtectionStanza: View {
    let name: String
    let options: SeatbeltOptions
    let runtime: RuntimeState
    @Environment(\.theme) private var theme
    private var themed: Bool { theme.isCustom }

    private var heading: (text: String, symbol: String, tint: Color) {
        switch runtime {
        case .sandboxed: return ("Protected now", "checkmark.shield.fill", .green)
        case .notRunning: return ("Protected when launched from Artemis", "shield.lefthalf.filled", .blue)
        case .unsandboxed: return ("RUNNING UNPROTECTED", "exclamationmark.triangle.fill", .red)
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Label(heading.text, systemImage: heading.symbol)
                .font(.headline)
                .foregroundStyle(heading.tint)

            if runtime == .unsandboxed {
                Text("\(name) was opened outside Artemis. Quit it and use Launch Protected.")
                    .font(.callout)
                    .fixedSize(horizontal: false, vertical: true)
            }

            ForEach(SeatbeltProfile.stanza(options: options), id: \.self) { line in
                (runtime == .unsandboxed ? Text(line).strikethrough().foregroundColor(.secondary) : emphasized(line))
                    .font(.callout)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(10)
        .background(RoundedRectangle(cornerRadius: 8, style: .continuous)
            .fill(heading.tint.opacity(0.10)).opacity(themed ? 0 : 1))
        .themedPanel(tint: heading.tint.opacity(0.14))
        .padding(.trailing, themed ? theme.gap : 0)
        .padding(.bottom, themed ? theme.gap : 0)
    }
}

/// Renders every "Can't" in a sentence bold and red, so the restriction is the first thing read.
func emphasized(_ line: String) -> Text {
    var result = Text("")
    var rest = Substring(line)
    while let range = rest.range(of: "can't", options: .caseInsensitive) {
        result = result + Text(rest[..<range.lowerBound])
            + Text(rest[range]).bold().foregroundColor(.red)
        rest = rest[range.upperBound...]
    }
    return result + Text(rest)
}

/// The confirmation shown when you choose Manage: what will be blocked, the three choices, and how it applies.
struct ManageSheet: View {
    let app: AppRecord
    var initial = SeatbeltOptions()
    let onManaged: (SeatbeltOptions) -> Void

    @EnvironmentObject private var seatbelts: SeatbeltStore
    @Environment(\.dismiss) private var dismiss
    @State private var options = SeatbeltOptions()
    @State private var problem: String?

    /// The lines that hold whatever the checkboxes say.
    private var alwaysBlocked: [String] {
        SeatbeltProfile.stanza(options: SeatbeltOptions(blockIncoming: false, blockNetwork: false, protectUserFolders: false))
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack(spacing: 12) {
                Image(nsImage: NSWorkspace.shared.icon(forFile: app.url.path))
                    .resizable()
                    .frame(width: 52, height: 52)
                VStack(alignment: .leading, spacing: 3) {
                    Text("Manage \(app.name)?").font(.title2.weight(.semibold))
                    Text("Artemis will give it a seatbelt. The app itself is not changed.")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }
            }

            VStack(alignment: .leading, spacing: 6) {
                Text("Always blocked").font(.headline)
                ForEach(alwaysBlocked, id: \.self) { line in
                    Label { emphasized(line) } icon: { Image(systemName: "lock.fill") }
                        .font(.callout)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }

            VStack(alignment: .leading, spacing: 6) {
                Text("Your choices").font(.headline)
                CheckRow(options.blockNetwork ? "Block incoming connections (included below)" : "Block incoming connections",
                         isOn: options.blockNetwork ? .constant(true) : $options.blockIncoming)
                    .disabled(options.blockNetwork)
                CheckRow("Block all network access", isOn: $options.blockNetwork)
                CheckRow("Block Documents, Desktop, Downloads and iCloud", isOn: $options.protectUserFolders)
                CheckRow("Block the Keychain (breaks browsers and saved passwords)", isOn: $options.blockKeychain)
                Text("You can change these later in the details sidebar.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .toggleStyle(.checkbox)

            if app.ownSandbox != nil {
                VStack(alignment: .leading, spacing: 6) {
                    Label {
                        Text("\(app.name) has its own sandbox, and macOS won't run one sandbox inside another. Managing it means turning its own sandbox off."
                             + (app.isBrowser
                                ? " For a web browser that is a bad trade: its own sandbox shields you from web pages far better than a seatbelt does. Not recommended."
                                : " Its own sandbox is usually the tighter of the two, so only do this if you want the seatbelt's file rules and logging more."))
                            .font(.callout)
                            .fixedSize(horizontal: false, vertical: true)
                    } icon: {
                        Image(systemName: "exclamationmark.octagon.fill").foregroundStyle(.red)
                    }
                    CheckRow("Turn off \(app.name)'s own sandbox", isOn: $options.disableOwnSandbox)
                }
            }

            Label {
                Text("The seatbelt only applies when you start \(app.name) from Artemis or from its launcher in ~/Applications/Managed Applications. Opened any other way, it runs unprotected.")
                    .font(.callout)
                    .fixedSize(horizontal: false, vertical: true)
            } icon: {
                Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange)
            }

            if let problem {
                Text(problem)
                    .font(.caption)
                    .foregroundStyle(.red)
                    .fixedSize(horizontal: false, vertical: true)
                    .textSelection(.enabled)
            }

            HStack {
                Spacer()
                Button("Cancel", role: .cancel) { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button("Manage") {
                    do {
                        try seatbelts.apply(app, options: options)
                        onManaged(options)
                        dismiss()
                    } catch {
                        problem = error.localizedDescription
                    }
                }
                .keyboardShortcut(.defaultAction)
                .disabled(app.ownSandbox != nil && !options.disableOwnSandbox)
            }
        }
        .padding(20)
        .frame(width: 480)
        .onAppear { options = initial }
    }
}

/// The activity log for one managed app: recent events, newest first, and export.
struct ActivitySection: View {
    let app: AppRecord
    @EnvironmentObject private var telemetry: TelemetryStore
    @State private var problem: String?

    private var recent: [TelemetryEvent] { Array(telemetry.events(for: app.id).suffix(40).reversed()) }

    var body: some View {
        Panel {
            VStack(alignment: .leading, spacing: 8) {
                Text("Activity").font(.headline)

                if let trouble = telemetry.streamProblem {
                    Label(trouble, systemImage: "exclamationmark.triangle.fill")
                        .font(.caption)
                        .foregroundStyle(.orange)
                        .fixedSize(horizontal: false, vertical: true)
                }

                if recent.isEmpty {
                    Text("Nothing recorded yet. Artemis records launches, exits, runs without the seatbelt and blocked attempts while it is open.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                } else {
                    ForEach(recent) { event in
                        HStack(alignment: .firstTextBaseline, spacing: 6) {
                            Image(systemName: event.symbol)
                                .foregroundStyle(event.kind == .unprotectedRun ? Color.orange
                                                 : event.kind == .blocked ? Color.red : Color.secondary)
                                .frame(width: 14)
                            VStack(alignment: .leading, spacing: 1) {
                                Text(event.detail)
                                    .font(.caption)
                                    .textSelection(.enabled)
                                    .fixedSize(horizontal: false, vertical: true)
                                Text(event.date.formatted(date: .abbreviated, time: .standard)
                                     + (event.category.isEmpty ? "" : " · " + event.category))
                                    .font(.caption2)
                                    .foregroundStyle(.secondary)
                            }
                        }
                    }
                }

                HStack {
                    Button("Export Log…") { export() }
                        .disabled(recent.isEmpty)
                    Button("Reveal Log File") {
                        NSWorkspace.shared.activateFileViewerSelecting([TelemetryStore.fileURL])
                    }
                }
                .controlSize(.small)

                if let problem {
                    Text(problem).font(.caption).foregroundStyle(.red)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(4)
        }
    }

    private func export() {
        let panel = NSSavePanel()
        panel.nameFieldStringValue = "artemis-\(app.name)-activity.jsonl"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            try telemetry.export(path: app.id, to: url)
            problem = nil
        } catch {
            problem = error.localizedDescription
        }
    }
}

/// A checkbox whose whole row is the click target. Used instead of the system checkbox, which
/// was not responding reliably inside the details sidebar.
struct CheckRow: View {
    let title: String
    @Binding var isOn: Bool
    @Environment(\.isEnabled) private var isEnabled

    init(_ title: String, isOn: Binding<Bool>) {
        self.title = title
        _isOn = isOn
    }

    var body: some View {
        Button {
            isOn.toggle()
        } label: {
            HStack(alignment: .firstTextBaseline, spacing: 7) {
                Image(systemName: isOn ? "checkmark.square.fill" : "square")
                    .font(.body)
                    .foregroundStyle(isOn ? Color.accentColor : Color.secondary)
                Text(title)
                    .fixedSize(horizontal: false, vertical: true)
                    .multilineTextAlignment(.leading)
                Spacer(minLength: 0)
            }
            .contentShape(Rectangle())
            .opacity(isEnabled ? 1 : 0.45)
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(isOn ? .isSelected : [])
    }
}
