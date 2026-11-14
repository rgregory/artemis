import SwiftUI

/// Exposure as a heat meter: five segments that fill and warm from amber to red, with
/// arrows for the two directions (pulls content in, takes orders from an agent).
struct ExposureMeter: View {
    let exposure: Exposure

    private var filled: Int { Int((Double(exposure.score) * 5.0 / 7.0).rounded()) }

    private func color(_ index: Int) -> Color {
        guard index < filled else { return Color.secondary.opacity(0.18) }
        let t = Double(index) / 4.0
        return t < 0.4 ? Palette.yellow : (t < 0.8 ? Palette.orange : Palette.red)
    }

    var body: some View {
        let none = exposure.reasons.isEmpty
        HStack(spacing: 8) {
            HStack(spacing: 2.5) {
                ForEach(0..<5, id: \.self) { index in
                    Capsule()
                        .fill(color(index))
                        .frame(width: 7, height: 4 + CGFloat(index) * 2.5)
                }
            }
            .frame(height: 14, alignment: .bottom)
            HStack(spacing: 3) {
                Image(systemName: "arrow.down")
                    .foregroundStyle(exposure.pull.isEmpty ? Color.secondary.opacity(0.3) : Palette.orange)
                Image(systemName: "arrow.up")
                    .foregroundStyle(exposure.push.isEmpty ? Color.secondary.opacity(0.3) : Palette.red)
            }
            .font(.caption.weight(.bold))
            VStack(alignment: .leading, spacing: 1) {
                Text(none ? "Quiet" : exposure.label)
                    .font(.caption.weight(.medium))
                    .foregroundStyle(none ? Color.secondary : .primary)
                if !none {
                    Text(exposure.tags.prefix(3).joined(separator: " · ")
                         + (exposure.tags.count > 3 ? " +\(exposure.tags.count - 3)" : ""))
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            }
        }
        .animation(.smooth, value: filled)
        .help(none ? "No signs that it pulls in outside content or acts for an agent"
              : exposure.reasons.joined(separator: "\n"))
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Exposure: \(exposure.label)")
    }
}

/// The sandbox state drawn rather than written: a shield for App Sandbox, an open lock for
/// none, and a fanned stack of cards, one per sandbox, for Chromium and Firefox apps.
struct SandboxGlyph: View {
    let app: AppRecord
    var isManaged = false

    var body: some View {
        HStack(spacing: 8) {
            mark.frame(width: 26, height: 18)
            VStack(alignment: .leading, spacing: 1) {
                Text(label)
                    .font(.caption.weight(.medium))
                    .foregroundStyle(isPlain ? Color.secondary : .primary)
                Text(detail)
                    .font(.caption2)
                    .foregroundStyle(isPlain && app.runtime == .unsandboxed ? Palette.orange : Color.secondary)
                    .lineLimit(1)
            }
        }
        .help(help)
    }

    /// Second line: what the state means for this app.
    private var detail: String {
        if isManaged {
            return app.runtime == .unsandboxed ? "Running without its seatbelt" : "Seatbelt by Artemis"
        }
        if app.isSandboxed {
            if app.isIOSApp { return "iOS container" }
            let extra = app.entitlements.filter { $0.key.hasPrefix("com.apple.security.") && $0.key != SandboxInspector.sandboxKey }.count
            return extra == 0 ? "Container only" : "Container + \(extra) permission\(extra == 1 ? "" : "s")"
        }
        if app.isLayered {
            return app.sandboxLayerNames.prefix(4).joined(separator: " · ") + " · main open"
        }
        if app.sandboxLayers > 0 {
            return "\(app.sandboxLayers) sandboxed helper\(app.sandboxLayers == 1 ? "" : "s")"
        }
        return app.runtime == .unsandboxed ? "Running with full access" : "Full user access"
    }

    private var isPlain: Bool { !isManaged && !app.isSandboxed && !app.isLayered }

    private var label: String {
        if isManaged { return "Managed" }
        if app.isSandboxed { return "Sandboxed" }
        if app.isLayered { return app.sandboxLayers > 1 ? "\(app.sandboxLayers) sandboxes" : "Own sandbox" }
        return "None"
    }

    private var help: String {
        if app.isLayered && !isManaged {
            return "The main process has no App Sandbox, but \(app.sandboxLayers) kinds of helper process (web pages, GPU, network…) each run in a sandbox of their own."
        }
        return app.statusLabel
    }

    @ViewBuilder private var mark: some View {
        if isManaged {
            Image(systemName: "shield.lefthalf.filled").font(.body).foregroundStyle(Palette.blue)
        } else if app.isSandboxed {
            Image(systemName: "checkmark.shield.fill").font(.body).foregroundStyle(Palette.green)
        } else if app.isLayered {
            let count = max(2, min(app.sandboxLayers, 6))
            ZStack(alignment: .leading) {
                ForEach(0..<count, id: \.self) { index in
                    RoundedRectangle(cornerRadius: 2.5, style: .continuous)
                        .fill(Palette.indigo.opacity(0.35 + 0.65 * Double(index + 1) / Double(count)))
                        .overlay(RoundedRectangle(cornerRadius: 2.5).strokeBorder(.background, lineWidth: 1))
                        .frame(width: 11, height: 14)
                        .offset(x: CGFloat(index) * 3, y: CGFloat(count - 1 - index) * -0.8)
                }
            }
        } else {
            Image(systemName: "lock.open.fill").font(.callout)
                .foregroundStyle(app.signing == .unsigned ? Palette.red : Palette.orange)
        }
    }
}

/// Signature as a seal: filled and green when signed and hardened, outlined when signed
/// without the hardened runtime, amber for ad hoc, red for unsigned.
struct SignatureSeal: View {
    let app: AppRecord

    var body: some View {
        let (symbol, tint, text): (String, Color, String) = {
            switch app.signing {
            case .signed:
                return app.hardenedRuntime ? ("checkmark.seal.fill", Palette.green, app.sourceLabel)
                    : ("checkmark.seal", .secondary, app.sourceLabel)
            case .adHoc: return ("seal", Palette.orange, "Ad hoc")
            case .unsigned: return ("xmark.seal.fill", Palette.red, "Unsigned")
            }
        }()
        Label {
            Text(text).font(.caption).foregroundStyle(.secondary)
        } icon: {
            Image(systemName: symbol).foregroundStyle(tint)
        }
        .help(app.signingLabel)
    }
}

/// A soft breathing dot for an app that is running right now.
struct LiveDot: View {
    let color: Color
    @State private var pulse = false

    var body: some View {
        ZStack {
            Circle().fill(color.opacity(0.35)).frame(width: 12, height: 12)
                .scaleEffect(pulse ? 1 : 0.5)
                .opacity(pulse ? 0 : 1)
            Circle().fill(color).frame(width: 6, height: 6)
        }
        .frame(width: 12, height: 12)
        .onAppear {
            withAnimation(.easeOut(duration: 1.6).repeatForever(autoreverses: false)) { pulse = true }
        }
    }
}
