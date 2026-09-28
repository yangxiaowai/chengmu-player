import SwiftUI
import CinemaCore

struct PlayerEpisodePanel: View {
    @ObservedObject private var app: AppModel
    @ObservedObject private var playback: PlaybackController

    init(app: AppModel) {
        self.app = app
        self.playback = app.playback
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            heading.padding(.bottom, 20)

            if let detail = app.detail {
                lineAndTransport(detail: detail)
                episodeList.padding(.top, 22)
                autoNextRow.padding(.top, 14)
            } else {
                Text("从探索页打开剧集后，可以在这里切换集数和线路。")
                    .font(.system(size: 12))
                    .foregroundStyle(CinemaStyle.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                Spacer(minLength: 20)
            }

            Rectangle().fill(CinemaStyle.border).frame(height: 1)
                .padding(.top, 18).padding(.bottom, 16)
            alternativeSourcePanel
        }
        .padding(.horizontal, 18)
        .padding(.top, 22)
        .padding(.bottom, 18)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(CinemaStyle.backgroundRaised)
    }

    private var heading: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 7) {
                RoundedRectangle(cornerRadius: 2).fill(CinemaStyle.accent).frame(width: 3, height: 14)
                Text("播放列表")
                    .font(.system(size: 11, weight: .semibold))
                    .tracking(1.2)
                    .foregroundStyle(CinemaStyle.accent)
            }
            Text(playback.title)
                .font(.system(size: 21, weight: .medium, design: .serif))
                .foregroundStyle(CinemaStyle.primary)
                .lineLimit(2)
                .frame(maxWidth: .infinity, alignment: .leading)
            if !playback.episodeName.isEmpty {
                Text("正在播放 · \(playback.episodeName)")
                    .font(.system(size: 11))
                    .foregroundStyle(CinemaStyle.secondary)
                    .lineLimit(1)
            }
        }
    }

    private func lineAndTransport(detail: MediaDetail) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("播放线路")
                .font(.system(size: 10, weight: .semibold))
                .foregroundStyle(CinemaStyle.secondary)
            Picker("播放线路", selection: Binding(get: { app.selectedLineID }, set: { app.switchLine($0) })) {
                ForEach(detail.lines) { Text($0.name).tag($0.id) }
            }
            .labelsHidden()
            .pickerStyle(.menu)
            .controlSize(.regular)
            .frame(maxWidth: .infinity, alignment: .leading)

            HStack(spacing: 8) {
                PanelActionButton(title: "上一集", symbol: "backward.end.fill", action: app.previousEpisode)
                    .disabled(!app.canPlayPrevious)
                PanelActionButton(title: "下一集", symbol: "forward.end.fill", action: app.nextEpisode)
                    .disabled(!app.canPlayNext)
            }
        }
        .padding(12)
        .background(CinemaStyle.panel, in: RoundedRectangle(cornerRadius: CinemaStyle.radius, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: CinemaStyle.radius, style: .continuous)
            .strokeBorder(CinemaStyle.border, lineWidth: 1))
    }

    private var episodeList: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .firstTextBaseline) {
                Text("选集")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(CinemaStyle.primary)
                Spacer()
                Text("\(app.selectedLine?.episodes.count ?? 0) 集")
                    .font(.system(size: 10, design: .monospaced))
                    .foregroundStyle(CinemaStyle.tertiary)
            }
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVGrid(columns: [GridItem(.flexible(), spacing: 8), GridItem(.flexible(), spacing: 8)], spacing: 8) {
                        ForEach(app.selectedLine?.episodes ?? []) { episode in
                            PanelEpisodeButton(title: episode.name, selected: episode.id == app.currentEpisodeID) {
                                app.play(episode)
                            }
                            .id(episode.id)
                        }
                    }
                    .padding(.vertical, 1)
                }
                .onAppear { proxy.scrollTo(app.currentEpisodeID, anchor: .center) }
                .onChange(of: app.currentEpisodeID) { _, id in proxy.scrollTo(id, anchor: .center) }
            }
        }
        .frame(maxHeight: .infinity, alignment: .top)
    }

    private var autoNextRow: some View {
        Toggle("自动播放下一集", isOn: $app.autoNext)
            .font(.system(size: 11))
            .toggleStyle(.switch)
            .controlSize(.small)
            .padding(.horizontal, 3)
            .frame(minHeight: 36)
    }

    private var alternativeSourcePanel: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 7) {
                Image(systemName: "arrow.triangle.2.circlepath")
                    .font(.system(size: 11))
                    .foregroundStyle(CinemaStyle.accent)
                Text("其他片源")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(CinemaStyle.primary)
            }
            if app.alternativesLoading {
                HStack(alignment: .center, spacing: 8) {
                    ProgressView().controlSize(.small)
                    Text(app.alternativeStage?.label ?? "正在核对片源…")
                        .font(.system(size: 11))
                        .foregroundStyle(CinemaStyle.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                    Spacer(minLength: 0)
                    Button("取消") { app.cancelAlternativeSelection() }
                        .buttonStyle(.bordered)
                        .controlSize(.small)
                }
                .frame(minHeight: 42)
            } else {
                Button { app.findAlternativeSources() } label: {
                    HStack(spacing: 8) {
                        Text("查找其他片源")
                            .font(.system(size: 11, weight: .medium))
                        Spacer()
                        Image(systemName: "arrow.up.right")
                            .font(.system(size: 10, weight: .semibold))
                    }
                    .foregroundStyle(CinemaStyle.accent)
                    .padding(.horizontal, 12)
                    .frame(minHeight: 42)
                    .background(CinemaStyle.accentSoft, in: RoundedRectangle(cornerRadius: CinemaStyle.radiusSmall, style: .continuous))
                    .overlay(RoundedRectangle(cornerRadius: CinemaStyle.radiusSmall, style: .continuous)
                        .strokeBorder(CinemaStyle.accent.opacity(0.32), lineWidth: 1))
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel("查找其他片源")
            }
            if !app.alternativeSources.isEmpty {
                ScrollView {
                    VStack(alignment: .leading, spacing: 7) {
                        ForEach(app.alternativeSources, id: \.self) { title in
                            Button { app.switchAlternativeSource(title) } label: {
                                VStack(alignment: .leading, spacing: 4) {
                                    Text(title.providerName)
                                        .font(.system(size: 10, weight: .semibold))
                                        .foregroundStyle(CinemaStyle.accent)
                                    Text(title.title)
                                        .font(.system(size: 11))
                                        .foregroundStyle(CinemaStyle.primary)
                                        .lineLimit(2)
                                    Text("画质待核对 · 切换前确认季集")
                                        .font(.system(size: 9))
                                        .foregroundStyle(CinemaStyle.secondary)
                                }
                                .frame(maxWidth: .infinity, minHeight: 54, alignment: .leading)
                                .padding(.horizontal, 11)
                                .padding(.vertical, 7)
                                .background(CinemaStyle.panel, in: RoundedRectangle(cornerRadius: CinemaStyle.radiusSmall, style: .continuous))
                                .overlay(RoundedRectangle(cornerRadius: CinemaStyle.radiusSmall, style: .continuous)
                                    .strokeBorder(CinemaStyle.border, lineWidth: 1))
                                .contentShape(Rectangle())
                            }
                            .buttonStyle(.plain)
                            .disabled(app.alternativesLoading)
                            .accessibilityLabel("\(title.providerName)，\(title.title)，切换片源")
                        }
                    }
                }
                .frame(maxHeight: 136)
            }
            if let notice = app.alternativeNotice {
                Text(notice)
                    .font(.system(size: 10))
                    .foregroundStyle(CinemaStyle.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }
}

private struct PanelActionButton: View {
    let title: String
    let symbol: String
    let action: () -> Void
    @Environment(\.isEnabled) private var isEnabled
    @LegacyState private var hovering = false

    var body: some View {
        Button(action: action) {
            Label(title, systemImage: symbol)
                .font(.system(size: 11, weight: .medium))
                .frame(maxWidth: .infinity, minHeight: 42)
                .foregroundStyle(isEnabled ? CinemaStyle.primary : CinemaStyle.tertiary)
                .background(hovering && isEnabled ? CinemaStyle.panelHover : CinemaStyle.backgroundRaised,
                            in: RoundedRectangle(cornerRadius: CinemaStyle.radiusSmall, style: .continuous))
                .overlay(RoundedRectangle(cornerRadius: CinemaStyle.radiusSmall, style: .continuous)
                    .strokeBorder(CinemaStyle.border, lineWidth: 1))
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
    }
}

private struct PanelEpisodeButton: View {
    let title: String
    let selected: Bool
    let action: () -> Void
    @LegacyState private var hovering = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 5) {
                if selected { Image(systemName: "waveform").font(.system(size: 10, weight: .semibold)) }
                Text(title)
                    .font(.system(size: 11, weight: selected ? .semibold : .regular))
                    .lineLimit(2)
            }
            .foregroundStyle(selected ? CinemaStyle.accent : CinemaStyle.primary)
            .frame(maxWidth: .infinity, minHeight: 44)
            .padding(.horizontal, 6)
            .background(selected ? CinemaStyle.accentSoft : (hovering ? CinemaStyle.panelHover : CinemaStyle.panel),
                        in: RoundedRectangle(cornerRadius: CinemaStyle.radiusSmall, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: CinemaStyle.radiusSmall, style: .continuous)
                .strokeBorder(selected ? CinemaStyle.accent.opacity(0.65) : CinemaStyle.border, lineWidth: 1))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .help(title)
        .accessibilityLabel(title)
        .accessibilityAddTraits(selected ? .isSelected : [])
        .animation(CinemaStyle.quick, value: selected)
    }
}
