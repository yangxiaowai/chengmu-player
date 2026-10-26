import SwiftUI
import CinemaCore

/// Shared visual language. Values are deliberately few and named by role, so every page uses the
/// same surfaces, strokes, radii, spacing and motion instead of ad-hoc numbers.
enum CinemaStyle {
    // Surfaces
    static let background = Color(red: 0.068, green: 0.073, blue: 0.084)
    static let backgroundRaised = Color(red: 0.112, green: 0.119, blue: 0.133)
    static let panel = Color(red: 0.102, green: 0.109, blue: 0.124)
    static let panelHover = Color.white.opacity(0.055)
    /// Video overlay surfaces stay dark enough to keep subtitles legible on any frame.
    static let overlay = Color.black.opacity(0.62)
    static let overlayStrong = Color.black.opacity(0.82)

    // Strokes
    static let border = Color.white.opacity(0.085)
    static let borderStrong = Color.white.opacity(0.16)
    static let accentSoft = accent.opacity(0.16)

    // Content
    static let accent = Color(red: 0, green: 0.682, blue: 0.925)
    static let bookmark = Color(red: 0.98, green: 0.47, blue: 0.59)
    static let secondary = Color(red: 0.61, green: 0.63, blue: 0.68)
    static let tertiary = Color(red: 0.40, green: 0.43, blue: 0.49)
    static let primary = Color.white.opacity(0.93)
    static let positive = Color(red: 0.42, green: 0.78, blue: 0.55)

    // Geometry
    static let radiusSmall: CGFloat = 8
    static let radius: CGFloat = 12
    static let radiusLarge: CGFloat = 18
    static let gutter: CGFloat = 32
    static let cardPadding: CGFloat = 16
    static let rowSpacing: CGFloat = 8

    // Motion
    static let quick = Animation.easeOut(duration: 0.14)
    static let standard = Animation.easeInOut(duration: 0.2)

    static let cardFill = LinearGradient(colors: [backgroundRaised, panel.opacity(0.75)], startPoint: .topLeading, endPoint: .bottomTrailing)
    static let headerScrim = LinearGradient(colors: [.black.opacity(0.78), .clear], startPoint: .top, endPoint: .bottom)
    static let controlsScrim = LinearGradient(colors: [.clear, .black.opacity(0.86)], startPoint: .top, endPoint: .bottom)
}

/// Section container: rounded surface, hairline stroke, optional leading icon and trailing content.
struct CinemaCard<Content: View>: View {
    var title: String?
    var icon: String?
    var trailing: AnyView?
    @ViewBuilder var content: () -> Content

    init(title: String? = nil, icon: String? = nil, trailing: AnyView? = nil, @ViewBuilder content: @escaping () -> Content) {
        self.title = title; self.icon = icon; self.trailing = trailing; self.content = content
    }
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            if title != nil || trailing != nil {
                HStack(spacing: 7) {
                    if let icon { Image(systemName: icon).font(.system(size: 11, weight: .semibold)).foregroundStyle(CinemaStyle.accent) }
                    if let title { Text(title).font(.system(size: 12, weight: .semibold)).tracking(0.4) }
                    Spacer(minLength: 0)
                    if let trailing { trailing }
                }
            }
            content()
        }
        .padding(CinemaStyle.cardPadding)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(CinemaStyle.cardFill, in: RoundedRectangle(cornerRadius: CinemaStyle.radius, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: CinemaStyle.radius, style: .continuous).strokeBorder(CinemaStyle.border, lineWidth: 1))
    }
}

/// Label/value row used by diagnostics and status panels.
struct CinemaKeyValue: View {
    let label: String
    let value: String
    var accent = false

    init(_ label: String, _ value: String, accent: Bool = false) {
        self.label = label; self.value = value; self.accent = accent
    }
    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Text(label).font(.system(size: 11)).foregroundStyle(CinemaStyle.secondary).frame(width: 96, alignment: .leading)
            Text(value).font(.system(size: 11, design: .monospaced))
                .foregroundStyle(accent ? CinemaStyle.accent : CinemaStyle.primary)
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}

/// Compact inline notice with an optional dismiss action.
struct CinemaNotice: View {
    let icon: String
    let text: String
    var tint: Color = CinemaStyle.accent
    var onDismiss: (() -> Void)?

    var body: some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: icon).font(.system(size: 11))
            Text(text).font(.system(size: 11)).frame(maxWidth: .infinity, alignment: .leading)
            if let onDismiss {
                Button { onDismiss() } label: { Image(systemName: "xmark").font(.system(size: 10)) }
                    .buttonStyle(.plain).help("关闭提示")
            }
        }
        .foregroundStyle(tint)
        .padding(.horizontal, 11).padding(.vertical, 8)
        .background(tint.opacity(0.1), in: RoundedRectangle(cornerRadius: CinemaStyle.radiusSmall, style: .continuous))
    }
}

/// Shared consumer actions avoid platform bevels and provide a visible pressed response.
struct CinemaActionStyle: ButtonStyle {
    var prominent = false
    var compact = false
    func makeBody(configuration: Configuration) -> some View {
        configuration.label.font(.system(size: compact ? 11 : 12, weight: .medium)).foregroundStyle(prominent ? .white : CinemaStyle.primary)
            .padding(.horizontal, compact ? 12 : 18).padding(.vertical, compact ? 8 : 11)
            .background(prominent ? CinemaStyle.accent.opacity(configuration.isPressed ? 0.7 : 1) : Color.white.opacity(configuration.isPressed ? 0.11 : 0.065), in: RoundedRectangle(cornerRadius: 8))
            .opacity(configuration.isPressed ? 0.84 : 1)
    }
}
struct CinemaEpisodeStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label.foregroundStyle(configuration.isPressed ? CinemaStyle.accent : CinemaStyle.primary)
            .background(configuration.isPressed ? CinemaStyle.accent.opacity(0.14) : CinemaStyle.panel, in: RoundedRectangle(cornerRadius: 7))
    }
}
