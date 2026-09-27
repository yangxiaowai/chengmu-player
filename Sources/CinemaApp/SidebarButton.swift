import SwiftUI

/// The label owns its full hit region, including the space after the title.
struct SidebarButton: View {
    let title: String
    let icon: String
    var selected = false
    var isNavigation = true
    let action: () -> Void
    @LegacyState private var hovering = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 13) {
                Image(systemName: icon).frame(width: 18)
                Text(title).font(.system(size: isNavigation ? 13 : 12, weight: selected ? .semibold : .regular))
                Spacer(minLength: 4)
                RoundedRectangle(cornerRadius: 1)
                    .fill(selected ? CinemaStyle.accent : .clear)
                    .frame(width: 3, height: 16)
            }
            .padding(.horizontal, 14)
            .frame(maxWidth: .infinity, minHeight: 44)
            .contentShape(Rectangle())
        }
        .buttonStyle(SidebarRowStyle(selected: selected, hovering: hovering))
        .onHover { hovering = $0 }
        .accessibilityLabel(title)
        .accessibilityAddTraits(selected ? .isSelected : [])
    }
}

private struct SidebarRowStyle: ButtonStyle {
    let selected: Bool
    let hovering: Bool

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .foregroundStyle(selected || hovering || configuration.isPressed ? .white : CinemaStyle.secondary)
            .background(
                Color.white.opacity(configuration.isPressed ? 0.14 : (selected ? 0.08 : (hovering ? 0.045 : 0))),
                in: RoundedRectangle(cornerRadius: 8)
            )
    }
}
