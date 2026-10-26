import SwiftUI

struct SidebarButton: View {
    let title: String
    let icon: String
    var selected = false
    var isNavigation = true
    let action: () -> Void
    @LegacyState private var hovering = false
    var body: some View {
        Button(action: action) {
            HStack(spacing: 11) {
                Image(systemName: icon).font(.system(size: isNavigation ? 16 : 14, weight: selected ? .semibold : .regular)).frame(width: 20)
                Text(title).font(.system(size: isNavigation ? 12 : 11, weight: selected ? .semibold : .regular))
                Spacer(minLength: 0)
            }.padding(.horizontal, 13).frame(maxWidth: .infinity, minHeight: isNavigation ? 43 : 36).contentShape(Rectangle())
        }.buttonStyle(SidebarRowStyle(selected: selected, hovering: hovering)).onHover { hovering = $0 }.accessibilityLabel(title).accessibilityAddTraits(selected ? .isSelected : [])
    }
}
private struct SidebarRowStyle: ButtonStyle {
    let selected: Bool
    let hovering: Bool
    func makeBody(configuration: Configuration) -> some View {
        configuration.label.foregroundStyle(selected ? CinemaStyle.accent : (hovering || configuration.isPressed ? CinemaStyle.primary : CinemaStyle.secondary))
            .background(selected ? CinemaStyle.accent.opacity(configuration.isPressed ? 0.19 : 0.10) : .white.opacity(configuration.isPressed ? 0.08 : (hovering ? 0.04 : 0)), in: RoundedRectangle(cornerRadius: 8))
            .overlay(alignment: .leading) { if selected { RoundedRectangle(cornerRadius: 2).fill(CinemaStyle.accent).frame(width: 3, height: 16).offset(x: -12) } }
    }
}
