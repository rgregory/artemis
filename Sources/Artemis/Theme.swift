import SwiftUI

/// The looks Artemis can wear, chosen under View > Theme.
enum AppTheme: String, CaseIterable, Identifiable {
    case standard, retro, os9, copland, things

    static let storageKey = "theme"
    var id: String { rawValue }

    var label: String {
        switch self {
        case .standard: return "Standard"
        case .retro: return "Retro"
        case .os9: return "OS 9"
        case .copland: return "Copland"
        case .things: return "Things 3"
        }
    }

    var isCustom: Bool { self != .standard }

    /// Window background. Nil leaves the system's.
    var paper: Color? {
        switch self {
        case .standard: return nil
        case .retro: return Color(white: 0.95)
        case .os9: return Color(white: 0.867)                               // Platinum grey
        case .copland: return Color(red: 0.78, green: 0.80, blue: 0.84)     // cooler, bluer grey
        case .things: return Color(red: 0.965, green: 0.968, blue: 0.975)
        }
    }

    var accent: Color? {
        switch self {
        case .standard, .retro: return nil
        case .os9: return Color(red: 0.40, green: 0.40, blue: 0.80)         // classic lavender highlight
        case .copland: return Color(red: 0.20, green: 0.45, blue: 0.55)     // teal
        case .things: return Color(red: 0.11, green: 0.49, blue: 0.98)
        }
    }

    var panel: PanelLook {
        switch self {
        case .standard:
            return PanelLook(fill: .clear, corner: 0, border: .clear, borderWidth: 0)
        case .retro:
            let ink = Color(white: 0.30)
            return PanelLook(fill: .white, corner: 8, border: ink, borderWidth: 2,
                             hardShadow: 4, hardShadowColor: ink.opacity(0.45))
        case .os9:
            return PanelLook(fill: Color(white: 0.93), corner: 0, border: Color(white: 0.33),
                             borderWidth: 1, bevel: true,
                             selection: Color(red: 0.80, green: 0.80, blue: 1.0))   // classic highlight
        case .copland:
            return PanelLook(fill: Color(red: 0.88, green: 0.89, blue: 0.92), corner: 9,
                             border: Color(white: 0.15), borderWidth: 1, bevel: true, bevelWidth: 2,
                             selection: Color(red: 0.74, green: 0.86, blue: 0.89))
        case .things:
            return PanelLook(fill: .white, corner: 10, border: Color(white: 0.90),
                             borderWidth: 1, softShadow: 5)
        }
    }

    /// Extra room to leave right of and below a panel so its shadow isn't clipped.
    var gap: CGFloat {
        switch self {
        case .retro: return 4
        case .things: return 2
        default: return 0
        }
    }

    var uppercaseLabels: Bool { self == .retro }
    var showsHeadings: Bool { self == .retro || self == .os9 || self == .copland }
}

struct PanelLook {
    var fill: Color
    var corner: CGFloat
    var border: Color
    var borderWidth: CGFloat
    var hardShadow: CGFloat = 0
    var hardShadowColor: Color = .clear
    var softShadow: CGFloat = 0
    var bevel = false
    var bevelWidth: CGFloat = 1
    /// Fill for a selected panel. Nil means use the caller's own colour.
    var selection: Color?
}

private struct ThemeKey: EnvironmentKey {
    static let defaultValue = AppTheme.standard
}

extension EnvironmentValues {
    var theme: AppTheme {
        get { self[ThemeKey.self] }
        set { self[ThemeKey.self] = newValue }
    }
}

/// Applies the theme to everything inside. Uses values, not branches, so switching keeps view state.
struct ThemeRoot: ViewModifier {
    let theme: AppTheme

    func body(content: Content) -> some View {
        content
            .environment(\.theme, theme)
            .tint(theme.accent)
            .background(theme.paper ?? Color.clear)
            .preferredColorScheme(theme.isCustom ? .light : nil)
    }
}

/// Draws the current theme's panel behind a view. Does nothing in the standard theme.
/// `tint` colours the panel. With `isSelection`, themes that have their own highlight use that instead.
struct ThemedPanel: ViewModifier {
    var tint: Color?
    var isSelection = false
    @Environment(\.theme) private var theme

    func body(content: Content) -> some View {
        let look = theme.panel
        let shape = RoundedRectangle(cornerRadius: look.corner, style: .continuous)
        let wash: Color? = tint == nil ? nil : (isSelection ? (look.selection ?? tint) : tint)
        let solid = isSelection && look.selection != nil && tint != nil
        return content
            // A translucent tint goes over white, not over the panel's grey, so it stays clean.
            .background(shape.fill(wash ?? Color.clear).opacity(theme.isCustom ? 1 : 0))
            .background(shape.fill(Color.white).opacity(theme.isCustom && wash != nil && !solid ? 1 : 0))
            .background(
                shape.fill(look.fill)
                    .shadow(color: .black.opacity(look.softShadow > 0 ? 0.10 : 0),
                            radius: look.softShadow, y: look.softShadow > 0 ? 2 : 0)
            )
            .overlay(Bevel(width: look.bevelWidth, corner: look.corner).opacity(look.bevel ? 1 : 0))
            .overlay(shape.strokeBorder(look.border, lineWidth: look.borderWidth).allowsHitTesting(false))
            .background(
                shape
                    .fill(look.hardShadowColor)
                    .offset(x: look.hardShadow, y: look.hardShadow)
            )
    }
}

extension View {
    func themedPanel(tint: Color? = nil, isSelection: Bool = false) -> some View {
        modifier(ThemedPanel(tint: tint, isSelection: isSelection))
    }
}

/// The raised edge of a classic Mac OS panel: light along the top and left, dark along the bottom and right.
private struct Bevel: View {
    var width: CGFloat = 1
    var corner: CGFloat = 0

    private func ring(_ color: Color) -> some View {
        RoundedRectangle(cornerRadius: max(0, corner - 1), style: .continuous)
            .inset(by: 1)
            .strokeBorder(color, lineWidth: width)
    }

    var body: some View {
        // A grey ring all the way round, with a white ring on top that is cut to the top and
        // left edges. The cut runs at 45 degrees out of the bottom-left and top-right corners,
        // so each edge is one colour along its whole length whatever the panel's proportions.
        GeometryReader { geo in
            let w = geo.size.width
            let h = geo.size.height
            let m = min(w, h) / 2
            ring(Color(white: 0.55))
            ring(.white)
                .mask(
                    Path { path in
                        path.move(to: CGPoint(x: 0, y: 0))
                        path.addLine(to: CGPoint(x: w, y: 0))
                        path.addLine(to: CGPoint(x: w - m, y: m))
                        path.addLine(to: CGPoint(x: m, y: h - m))
                        path.addLine(to: CGPoint(x: 0, y: h))
                        path.closeSubpath()
                    }
                )
        }
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }
}

/// A grouped box: the system GroupBox normally, a themed panel otherwise.
struct Panel<Content: View>: View {
    @Environment(\.theme) private var theme
    private let content: Content

    init(@ViewBuilder content: () -> Content) {
        self.content = content()
    }

    var body: some View {
        if theme.isCustom {
            content
                .padding(10)
                .themedPanel()
                .padding(.trailing, theme.gap)
                .padding(.bottom, theme.gap)
        } else {
            GroupBox { content }
        }
    }
}

/// A bold heading with a rule under it and an optional count at the right.
struct SectionHeading: View {
    let title: String
    var trailing: String = ""

    var body: some View {
        VStack(spacing: 6) {
            HStack(alignment: .firstTextBaseline) {
                Text(title).font(.title3.weight(.bold))
                Spacer()
                Text(trailing).font(.callout).foregroundStyle(.secondary)
            }
            Rectangle().fill(Color.secondary).frame(height: 1.5)
        }
    }
}
