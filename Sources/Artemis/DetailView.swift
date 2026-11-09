import AppKit
import SwiftUI

struct DetailView: View {
    let app: AppRecord?

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
                            StatusBadge(app: app)
                        }
                    }

                    Text(explanation(for: app))
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)

                    GroupBox {
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
            Text(label).font(.caption).foregroundStyle(.secondary)
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
