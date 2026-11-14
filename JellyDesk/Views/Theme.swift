import SwiftUI

/// Farben und Bausteine der nativen Oberfläche, abgeleitet aus den Variablen des Themes
/// (css/appletv.css: --tv-bg, --tv-text-2, --tv-hair, --tv-glass, --tv-blue …).
enum Theme {
    static let background = Color.black                               // --tv-bg
    static let surface = Color(red: 0.11, green: 0.11, blue: 0.118)   // --tv-bg-2 #1c1c1e
    static let text = Color.white
    static let text2 = Color.white.opacity(0.64)                      // --tv-text-2
    static let text3 = Color.white.opacity(0.5)                       // --tv-text-3
    static let hairline = Color.white.opacity(0.12)                   // --tv-hair
    static let hairlineStrong = Color.white.opacity(0.16)             // --tv-hair-strong
    static let glass = Color.white.opacity(0.14)                      // --tv-glass
    static let blue = Color(red: 0.039, green: 0.518, blue: 1.0)      // --tv-blue #0a84ff
    static let red = Color(red: 1.0, green: 0.271, blue: 0.227)       // --tv-red #ff453a
    static let green = Color(red: 0.204, green: 0.78, blue: 0.349)    // --tv-green #34c759

    static let gutter: CGFloat = 40
}

/// Glasfläche wie die Kapseln des Themes: heller Schleier über unscharfem Grund, feine Kante.
struct GlassBackground<S: InsettableShape>: ViewModifier {
    let shape: S
    var strong = false

    func body(content: Content) -> some View {
        content
            .background(.ultraThinMaterial, in: shape)
            .background(Theme.glass.opacity(strong ? 1 : 0.6), in: shape)
            .overlay(shape.strokeBorder(Theme.hairlineStrong, lineWidth: 1))
    }
}

extension View {
    func glass<S: InsettableShape>(_ shape: S, strong: Bool = false) -> some View {
        modifier(GlassBackground(shape: shape, strong: strong))
    }
}

/// Weißer Pillen-Knopf wie „Abspielen“/„Fortsetzen“ im Theme.
struct PillButtonStyle: ButtonStyle {
    @Environment(\.isEnabled) private var isEnabled

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 14, weight: .semibold))
            .labelStyle(.titleAndIcon)
            .foregroundStyle(Color.black)
            .padding(.horizontal, 18)
            .frame(height: 36)
            .background(Color.white.opacity(configuration.isPressed ? 0.78 : 1), in: Capsule())
            .opacity(isEnabled ? 1 : 0.4)
            .contentShape(Capsule())
    }
}

/// Zweitrangiger Pillen-Knopf aus Glas.
struct GlassPillButtonStyle: ButtonStyle {
    @Environment(\.isEnabled) private var isEnabled

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 14, weight: .semibold))
            .labelStyle(.titleAndIcon)
            .foregroundStyle(Theme.text)
            .padding(.horizontal, 18)
            .frame(height: 36)
            .glass(Capsule(), strong: configuration.isPressed)
            .opacity(isEnabled ? 1 : 0.4)
            .contentShape(Capsule())
    }
}

/// Runder Glas-Knopf mit Symbol wie „+“ und „i“ neben dem Abspielen-Knopf des Themes.
struct GlassCircleButtonStyle: ButtonStyle {
    var size: CGFloat = 36
    @Environment(\.isEnabled) private var isEnabled

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .labelStyle(.iconOnly)
            .font(.system(size: size * 0.4, weight: .semibold))
            .foregroundStyle(Theme.text)
            .frame(width: size, height: size)
            .glass(Circle(), strong: configuration.isPressed)
            .opacity(isEnabled ? 1 : 0.35)
            .contentShape(Circle())
    }
}

/// Kleine umrandete Marke wie „FSK 6“ im Theme.
struct OutlineBadge: View {
    let text: String
    var highlighted = false

    var body: some View {
        Text(text.uppercased())
            .font(.system(size: 10, weight: .bold))
            .kerning(0.4)
            .foregroundStyle(highlighted ? Theme.text : Theme.text2)
            .padding(.horizontal, 5)
            .padding(.vertical, 2)
            .overlay(
                RoundedRectangle(cornerRadius: 4)
                    .strokeBorder(highlighted ? Theme.text.opacity(0.8) : Theme.text3, lineWidth: 1)
            )
    }
}

/// Kapsel mit Abschnitten wie die Navigation des Themes (Start · Movies · Shows).
struct GlassSegmentedControl: View {
    let options: [(key: String, label: String)]
    @Binding var selection: String

    var body: some View {
        HStack(spacing: 2) {
            ForEach(options, id: \.key) { option in
                Button {
                    selection = option.key
                } label: {
                    Text(option.label)
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(selection == option.key ? Theme.text : Theme.text2)
                        .padding(.horizontal, 13)
                        .frame(height: 28)
                        .background(selection == option.key ? Color.white.opacity(0.22) : Color.clear, in: Capsule())
                        .contentShape(Capsule())
                }
                .buttonStyle(.plain)
            }
        }
        .padding(4)
        .glass(Capsule())
    }
}
