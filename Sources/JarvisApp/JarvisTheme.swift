import SwiftUI

/// Semantic colors follow the system appearance, including increased contrast.
///
/// Every value that can carry text was checked against the darkest background it
/// actually paints on (`sidebar` for chrome, `canvas` for content) and clears
/// WCAG AA at 4.5:1. Tokens marked "tint only" fall below that deliberately and
/// must never be used for text or an icon that carries meaning alone.
enum JarvisTheme {
    // Surfaces, lightest-on-top in dark and in light. `base` sits beneath the
    // canvas in both appearances; `elevated` sits above `surface` in both.
    static let base = color(0x141313, light: 0xEDE9E2)
    static let canvas = color(0x171717, light: 0xF1EEE8)
    static let sidebar = color(0x211F1D, light: 0xECE9E3)
    static let surface = color(0x24211F, light: 0xFCFAF7)
    static let elevated = color(0x2C2825, light: 0xFFFFFF)
    static let pressed = color(0x36312D, light: 0xE6E1DA)
    static let border = color(0x3A3531, light: 0xDED7CE)
    static let strongBorder = color(0x514A43, light: 0xC9C0B5)

    // Ink.
    static let text = color(0xF3EEE6, light: 0x22201E)
    static let secondary = color(0xB8AEA2, light: 0x625B54)
    /// Timestamps, token counts, shortcut hints - quieter than `secondary`, still AA.
    static let tertiary = color(0x968E85, light: 0x706861)
    /// Tint only: dimmed controls whose state is also carried by the control itself.
    static let disabled = color(0x5E5852, light: 0xAAA29A)

    // Identity. Champagne is reserved for the mark, active listening, selected
    // navigation, the composer's focus edge and primary approval controls.
    static let accent = color(0xD7C8B6, light: 0x7C654E)
    /// Tint only: washes and gradient stops, never text.
    static let highlight = color(0xEFE4D4, light: 0xA98E72)
    static let selection = color(0xA88D6A, light: 0x806447)
    /// Fill behind `buttonInk` on a filled primary control. Darker than `selection`
    /// in light mode so the label on top of it clears AA.
    static let primaryFill = color(0xA88D6A, light: 0x7C5E40)
    static let deepBronze = color(0x80694F, light: 0x71563D)
    static let lilac = color(0xAAA2B3, light: 0x6F6677)
    /// Tint only: the cool edge on the mark at display sizes.
    static let lilacMist = color(0xC7C0CE, light: 0xD9D3DC)

    // Status.
    static let healthy = color(0x78A889, light: 0x447353)
    static let warning = color(0xC89A55, light: 0x905F20)
    static let error = color(0xCB7773, light: 0xAF4844)
    static let information = color(0x9CA9B8, light: 0x5E6A7D)
    static let recording = color(0xD5847D, light: 0xAA4C47)
    static let buttonInk = color(0x22201E, light: 0xF3EEE6)

    private static func color(_ dark: UInt32, light: UInt32) -> Color {
        Color(nsColor: NSColor(name: nil) { appearance in
            let hex = appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua ? dark : light
            return NSColor(srgbRed: Double((hex >> 16) & 255) / 255,
                           green: Double((hex >> 8) & 255) / 255,
                           blue: Double(hex & 255) / 255, alpha: 1)
        })
    }
}

private struct JarvisAppearance: ViewModifier {
    func body(content: Content) -> some View {
        content
            .foregroundStyle(JarvisTheme.text)
            .tint(JarvisTheme.selection)
            .background(JarvisTheme.canvas)
    }
}

private struct JarvisComposerGlass: ViewModifier {
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.colorSchemeContrast) private var contrast

    let focused: Bool
    let listening: Bool
    @Environment(\.colorScheme) private var colorScheme

    private let shape = RoundedRectangle(cornerRadius: 24, style: .continuous)

    private var rim: Color {
        if contrast == .increased { return JarvisTheme.secondary }
        if listening { return JarvisTheme.accent.opacity(0.85) }
        return focused ? JarvisTheme.accent.opacity(0.75) : JarvisTheme.strongBorder
    }

    func body(content: Content) -> some View {
        surface(content)
            .overlay {
                shape.strokeBorder(rim, lineWidth: contrast == .increased ? 2 : 1)
                    .allowsHitTesting(false)
                    .accessibilityHidden(true)
            }
            // A listening composer carries a second, wider halo so the state is
            // legible from across the room without moving anything.
            .overlay {
                shape.strokeBorder(JarvisTheme.recording.opacity(listening ? 0.22 : 0), lineWidth: 4)
                    .blur(radius: 3)
                    .allowsHitTesting(false)
                    .accessibilityHidden(true)
            }
            .shadow(color: .black.opacity(colorScheme == .dark ? (listening ? 0.28 : 0.20) : 0.08),
                    radius: listening ? 24 : 20, x: 0, y: 9)
            .animation(JarvisMotion.nudging(reduceMotion), value: focused)
            .animation(JarvisMotion.settling(reduceMotion), value: listening)
    }

    @ViewBuilder
    private func surface(_ content: Content) -> some View {
        if reduceTransparency {
            content.background(JarvisTheme.elevated, in: shape)
        } else {
            // Native glass supplies the optical treatment. Its parent is a
            // container, so only the actual buttons receive press interactions.
            content.background(JarvisTheme.elevated.opacity(0.82), in: shape)
                .background(.regularMaterial, in: shape)
        }
    }
}

extension View {
    /// Apply once at the window root so native controls share the semantic palette.
    func jarvisAppearance() -> some View {
        modifier(JarvisAppearance())
    }

    /// Apply after the composer's padding and size modifiers.
    func jarvisComposerGlass(focused: Bool = false, listening: Bool = false) -> some View {
        modifier(JarvisComposerGlass(focused: focused, listening: listening))
    }
}
