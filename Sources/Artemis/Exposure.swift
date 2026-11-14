import Foundation

/// How much an app deals with things it does not control. Two directions matter:
/// it pulls content in from the outside world, or it is pushed instructions by an
/// agent, a model or other automation and acts on them. Either makes an unsandboxed
/// app a bigger risk, and both together the biggest.
struct Exposure: Hashable, Sendable {
    /// Reasons it takes in outside content (web pages, messages, downloads, links).
    var pull: [String] = []
    /// Reasons it acts on instructions from agents, models or automation.
    var push: [String] = []

    var score: Int {
        (push.isEmpty ? 0 : 3) + (pull.isEmpty ? 0 : 2) + min(2, max(0, pull.count + push.count - 1))
    }

    var label: String {
        switch (pull.isEmpty, push.isEmpty) {
        case (false, false): return "Pulls + agent"
        case (true, false): return "Agent"
        case (false, true): return "Pulls"
        case (true, true): return "None found"
        }
    }

    var reasons: [String] { push + pull }

    /// One or two words per reason, for the second line of the Exposure column.
    var tags: [String] {
        reasons.map { reason in
            let table: [(String, String)] = [
                ("AI assistant", "AI agent"), ("Terminal", "Terminal"), ("Developer tool", "Runs code"),
                ("Automation", "Automation"), ("Can control", "Controls apps"), ("Web browser", "Browser"),
                ("Receives messages", "Messages"), ("Downloads", "Syncs files"), ("Opens web", "Web links"),
                ("Opens email", "Mail links"), ("Web pages and other apps", "URL scheme"),
                ("Built on a web", "Web engine"), ("Declares that it accepts", "Listens"),
            ]
            return table.first { reason.hasPrefix($0.0) }?.1 ?? reason
        }
    }
}

/// Works out an app's exposure from its Info.plist, its bundle contents and a list of
/// well-known apps. These are signals, not proof: an app can do either thing without
/// tripping any of them.
enum ExposureScanner {
    static func assess(bundle: URL, plist: [String: Any], bundleID: String, name: String,
                       entitlements: [EntitlementItem]) -> Exposure {
        var exposure = Exposure()
        let id = bundleID.lowercased()
        let lowerName = name.lowercased()
        func idMatches(_ prefixes: [String]) -> Bool { prefixes.contains { id.hasPrefix($0) } }
        func nameMatches(_ words: [String]) -> Bool { words.contains { lowerName.contains($0) } }
        let category = (plist["LSApplicationCategoryType"] as? String ?? "").lowercased()
        let entitlementKeys = Set(entitlements.map(\.key))

        // ---- Push: agents, models and automation tell it what to do

        if idMatches(aiApps) || nameMatches(aiWords) {
            exposure.push.append("AI assistant or agent: acts on what a model tells it")
        }
        if idMatches(terminals) {
            exposure.push.append("Terminal: runs whatever commands it is given")
        }
        if idMatches(codeEditors) || category.contains("developer-tools") {
            exposure.push.append("Developer tool: runs code and extensions")
        }
        if idMatches(launchers) {
            exposure.push.append("Automation tool: runs scripts and workflows")
        }
        if plist["NSAppleEventsUsageDescription"] != nil
            || entitlementKeys.contains("com.apple.security.automation.apple-events") {
            exposure.push.append("Can control other apps")
        }

        // ---- Pull: content from the outside world comes in

        if idMatches(browsers) {
            exposure.pull.append("Web browser: loads pages from anywhere")
        }
        if idMatches(messaging) || category.contains("social-networking") {
            exposure.pull.append("Receives messages and files from other people")
        }
        if idMatches(syncAndDownload) {
            exposure.pull.append("Downloads or syncs files from elsewhere")
        }

        let schemes = urlSchemes(in: plist)
        if schemes.contains("http") || schemes.contains("https") {
            if !idMatches(browsers) { exposure.pull.append("Opens web links") }
        } else if schemes.contains("mailto") {
            exposure.pull.append("Opens email links")
        }
        let custom = schemes.subtracting(["http", "https", "mailto", "file"])
        if let example = custom.sorted().first {
            exposure.pull.append("Web pages and other apps can trigger it through \(example):// links")
        }

        let frameworks = bundle.appendingPathComponent("Contents/Frameworks")
        let fm = FileManager.default
        if fm.fileExists(atPath: frameworks.appendingPathComponent("Electron Framework.framework").path)
            || fm.fileExists(atPath: frameworks.appendingPathComponent("Chromium Embedded Framework.framework").path) {
            exposure.pull.append("Built on a web browser engine, so it renders web content")
        }
        if entitlementKeys.contains("com.apple.security.network.server") {
            exposure.pull.append("Declares that it accepts network connections")
        }

        return exposure
    }

    private static func urlSchemes(in plist: [String: Any]) -> Set<String> {
        guard let types = plist["CFBundleURLTypes"] as? [[String: Any]] else { return [] }
        var schemes = Set<String>()
        for type in types {
            for scheme in type["CFBundleURLSchemes"] as? [String] ?? [] {
                schemes.insert(scheme.lowercased())
            }
        }
        return schemes
    }

    // Bundle ID prefixes, lowercased. Not exhaustive.

    private static let aiApps = [
        "com.anthropic.", "com.openai.", "ai.perplexity.", "com.google.gemini", "com.microsoft.copilot",
        "com.electron.ollama", "com.ollama.", "ai.elementlabs.lmstudio", "com.github.copilot",
        "com.todesktop.230313mzl4w4u92",    // Cursor
        "com.exafunction.windsurf", "com.tddworks.claudebar",
    ]
    private static let aiWords = [
        "claude", "chatgpt", "copilot", "ollama", "lm studio", "perplexity", "codex", "agent", "mcp",
    ]
    private static let terminals = [
        "com.apple.terminal", "com.googlecode.iterm2", "dev.warp.", "com.mitchellh.ghostty",
        "net.kovidgoyal.kitty", "co.zeit.hyper", "org.alacritty", "com.github.wez.wezterm",
    ]
    private static let codeEditors = [
        "com.microsoft.vscode", "dev.zed.", "com.jetbrains.", "com.sublimetext.", "com.apple.dt.xcode",
    ]
    private static let launchers = [
        "com.runningwithcrayons.alfred", "com.raycast.", "org.hammerspoon.", "com.stairways.keyboardmaestro",
    ]
    private static let browsers = [
        "com.google.chrome", "org.mozilla.firefox", "com.microsoft.edgemac", "com.brave.browser",
        "company.thebrowser.", "com.operasoftware.", "com.vivaldi.", "org.chromium.", "com.apple.safari",
        "com.kagi.", "app.zen-browser.",
    ]
    private static let messaging = [
        "com.tinyspeck.slackmacgap", "com.hnc.discord", "us.zoom.", "com.microsoft.teams", "com.microsoft.outlook",
        "org.whispersystems.signal", "ru.keepcoder.telegram", "net.whatsapp.", "com.readdle.smartemail",
        "com.apple.mail", "org.mozilla.thunderbird", "com.facebook.archon",
    ]
    private static let syncAndDownload = [
        "com.getdropbox.", "com.google.drivefs", "com.microsoft.onedrive", "org.m0k.transmission",
        "com.box.desktop",
    ]
}
