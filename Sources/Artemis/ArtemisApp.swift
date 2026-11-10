import AppKit
import SwiftUI

final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        // Lets the app come forward even when launched unbundled via `swift run`.
        NSApp.setActivationPolicy(.regular)
        NSApp.activate(ignoringOtherApps: true)
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }
}

@main
struct ArtemisApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @StateObject private var store = AppStore()
    @StateObject private var seatbelts = SeatbeltStore()
    @StateObject private var telemetry = TelemetryStore()
    @AppStorage(AppTheme.storageKey) private var theme = AppTheme.standard

    var body: some Scene {
        Window("Artemis", id: "main") {
            ContentView()
                .environmentObject(store)
                .environmentObject(seatbelts)
                .environmentObject(telemetry)
                .frame(minWidth: 920, minHeight: 540)
        }
        .defaultSize(width: 1180, height: 720)
        .commands {
            CommandGroup(after: .toolbar) {
                Picker("Theme", selection: $theme) {
                    ForEach(AppTheme.allCases) { theme in
                        Text(theme.label).tag(theme)
                    }
                }
            }
            CommandGroup(replacing: .newItem) {
                Button("Rescan Applications") { store.scan() }
                    .keyboardShortcut("r", modifiers: .command)
                    .disabled(store.isScanning)
            }
        }
    }
}
