import SwiftUI
import CinemaCore

/// Shared visual language. Values are deliberately few and named by role, so every page uses the
/// same surfaces, strokes, radii, spacing and motion instead of ad-hoc numbers.
enum CinemaStyle {
    // Surfaces
    static let background = Color(red: 0.055, green: 0.065, blue: 0.075)
    static let backgroundRaised = Color(red: 0.075, green: 0.086, blue: 0.098)
    static let panel = Color(red: 0.09, green: 0.10, blue: 0.115)
    static let panelHover = Color.white.opacity(0.055)
    /// Video overlay surfaces stay dark enough to keep subtitles legible on any frame.
    static let overlay = Color.black.opacity(0.62)
    static let overlayStrong = Color.black.opacity(0.82)

    // Strokes
    static let border = Color.white.opacity(0.085)
    static let borderStrong = Color.white.opacity(0.16)
    static let accentSoft = accent.opacity(0.16)

    // Content
    static let accent = Color(red: 0.94, green: 0.66, blue: 0.29)
    static let secondary = Color(red: 0.56, green: 0.59, blue: 0.62)
    static let tertiary = Color.white.opacity(0.42)
    static let primary = Color.white.opacity(0.93)
    static let positive = Color(red: 0.42, green: 0.78, blue: 0.55)

    // Geometry
    static let radiusSmall: CGFloat = 6
    static let radius: CGFloat = 10
    static let radiusLarge: CGFloat = 14
    static let gutter: CGFloat = 32
    static let cardPadding: CGFloat = 16
    static let rowSpacing: CGFloat = 8

    // Motion
    static let quick = Animation.easeOut(duration: 0.14)
    static let standard = Animation.easeInOut(duration: 0.2)

    static let cardFill = LinearGradient(colors: [Color.white.opacity(0.052), Color.white.opacity(0.028)], startPoint: .topLeading, endPoint: .bottomTrailing)
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
