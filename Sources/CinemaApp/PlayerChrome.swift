import SwiftUI

/// The same hit target and hover treatment is used for player controls in a window and full screen.
struct PlayerChromeIcon: View {
    let systemName: String
    var prominent = false
    var selected = false
    var symbolSize: CGFloat = 17
    @LegacyState private var hovered = false

    var body: some View {
        Image(systemName: systemName)
            .font(.system(size: symbolSize, weight: .semibold))
            .foregroundStyle(prominent ? Color.black : CinemaStyle.primary)
            .frame(width: prominent ? 48 : 42, height: prominent ? 48 : 42)
            .background(fill, in: RoundedRectangle(cornerRadius: prominent ? 16 : 13, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: prominent ? 16 : 13, style: .continuous)
                    .strokeBorder(prominent ? CinemaStyle.accent.opacity(0.6) : Color.white.opacity(hovered ? 0.15 : 0), lineWidth: 1)
            }
            .contentShape(Rectangle())
            .onHover { hovered = $0 }
            .animation(CinemaStyle.quick, value: hovered)
    }

    private var fill: Color {
        if prominent { return CinemaStyle.accent }
        if selected { return CinemaStyle.accent.opacity(0.20) }
        return Color.white.opacity(hovered ? 0.15 : 0.045)
    }
}

struct PlayerChromeText: View {
    let text: String
    var monospaced = false
    @LegacyState private var hovered = false

    var body: some View {
        Text(text)
            .font(.system(size: 11, weight: .medium, design: monospaced ? .monospaced : .default))
            .foregroundStyle(CinemaStyle.primary)
            .lineLimit(1)
            .padding(.horizontal, 10)
            .frame(minHeight: 42)
            .background(Color.white.opacity(hovered ? 0.15 : 0.045), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
            .contentShape(Rectangle())
            .onHover { hovered = $0 }
            .animation(CinemaStyle.quick, value: hovered)
    }
}

struct PlayerChromeButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(configuration.isPressed ? 0.94 : 1)
            .animation(CinemaStyle.quick, value: configuration.isPressed)
    }
}
