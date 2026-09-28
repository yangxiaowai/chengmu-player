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
        VStack(alignment: .leading, spacing: 18) {
            Text("正在放映").font(.system(size: 11, weight: .semibold)).tracking(1.1).foregroundStyle(CinemaStyle.accent)
            Text(playback.title).font(.system(size: 21, weight: .medium, design: .serif)).lineLimit(3)
            if let detail = app.detail {
                Picker("线路", selection: Binding(get: { app.selectedLineID }, set: { app.switchLine($0) })) {
                    ForEach(detail.lines) { Text($0.name).tag($0.id) }
                }.labelsHidden().controlSize(.small)
                HStack(spacing: 8) {
                    Button { app.previousEpisode() } label: { Label("上一集", systemImage: "backward.end") }
                        .disabled(!app.canPlayPrevious)
                    Spacer(minLength: 0)
                    Button { app.nextEpisode() } label: { Label("下一集", systemImage: "forward.end") }
                        .disabled(!app.canPlayNext)
                }.font(.system(size: 11)).buttonStyle(.bordered).controlSize(.small)
                ScrollViewReader { proxy in
                    ScrollView {
                        LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())], spacing: 8) {
                            ForEach(app.selectedLine?.episodes ?? []) { episode in
                                Button { app.play(episode) } label: {
                                    Text(episode.name).font(.system(size: 11, weight: episode.id == app.currentEpisodeID ? .medium : .regular)).lineLimit(1)
                                        .frame(maxWidth: .infinity, minHeight: 36)
                                        .foregroundStyle(episode.id == app.currentEpisodeID ? CinemaStyle.accent : CinemaStyle.primary)
                                        .background(episode.id == app.currentEpisodeID ? CinemaStyle.accentSoft : CinemaStyle.backgroundRaised, in: RoundedRectangle(cornerRadius: CinemaStyle.radiusSmall, style: .continuous))
                                        .overlay(RoundedRectangle(cornerRadius: CinemaStyle.radiusSmall, style: .continuous)
                                            .strokeBorder(episode.id == app.currentEpisodeID ? CinemaStyle.accent.opacity(0.55) : CinemaStyle.border, lineWidth: 1))
                                        .contentShape(Rectangle())
                                }.buttonStyle(.plain).id(episode.id)
                                    .help(episode.name)
                                    .accessibilityAddTraits(episode.id == app.currentEpisodeID ? .isSelected : [])
                                    .animation(CinemaStyle.quick, value: app.currentEpisodeID)
                            }
                        }
                    }
                    .onAppear { proxy.scrollTo(app.currentEpisodeID, anchor: .center) }
                    .onChange(of: app.currentEpisodeID) { _, id in proxy.scrollTo(id, anchor: .center) }
                }
                Toggle("自动播放下一集", isOn: $app.autoNext).font(.system(size: 11)).toggleStyle(.switch)
            } else {
                Text("通过搜索打开剧集，可以在这里选择其他集数与线路。").font(.system(size: 12)).foregroundStyle(CinemaStyle.secondary)
                Spacer()
            }
            alternativeSourcePanel
        }.padding(22)
    }

    private var alternativeSourcePanel: some View {
        VStack(alignment: .leading, spacing: 10) {
            Divider().overlay(CinemaStyle.border)
            if app.alternativesLoading {
                HStack(alignment: .top, spacing: 8) {
                    ProgressView().controlSize(.small)
                    Text(app.alternativeStage?.label ?? "正在核对片源…")
                        .font(.system(size: 11)).foregroundStyle(CinemaStyle.accent)
                        .fixedSize(horizontal: false, vertical: true)
                    Spacer(minLength: 0)
                    Button("取消") { app.cancelAlternativeSelection() }.buttonStyle(.bordered).font(.system(size: 11))
                }
            } else {
                Button { app.findAlternativeSources() } label: {
                    Label("查找其他片源", systemImage: "arrow.triangle.swap")
                        .font(.system(size: 11)).foregroundStyle(CinemaStyle.accent)
                        .frame(maxWidth: .infinity, minHeight: 30, alignment: .leading).contentShape(Rectangle())
                }.buttonStyle(.plain)
            }
            if !app.alternativeSources.isEmpty {
                ScrollView {
                    VStack(alignment: .leading, spacing: 7) {
                        ForEach(app.alternativeSources, id: \.self) { title in
                            Button { app.switchAlternativeSource(title) } label: {
                                VStack(alignment: .leading, spacing: 4) {
                                    Text(title.providerName).font(.system(size: 10, weight: .semibold)).foregroundStyle(CinemaStyle.accent)
                                    Text(title.title).font(.system(size: 11)).foregroundStyle(CinemaStyle.primary).lineLimit(2)
                                    Text("画质未知 · 核对同季同集后切换").font(.system(size: 9)).foregroundStyle(CinemaStyle.secondary)
                                }.frame(maxWidth: .infinity, alignment: .leading).padding(CinemaStyle.rowSpacing)
                                    .background(CinemaStyle.backgroundRaised, in: RoundedRectangle(cornerRadius: CinemaStyle.radiusSmall, style: .continuous))
                                    .overlay(RoundedRectangle(cornerRadius: CinemaStyle.radiusSmall, style: .continuous).strokeBorder(CinemaStyle.border, lineWidth: 1))
                                    .contentShape(Rectangle())
                            }.buttonStyle(.plain).disabled(app.alternativesLoading)
                        }
                    }
                }.frame(maxHeight: 150)
            }
            if let notice = app.alternativeNotice {
                Text(notice).font(.system(size: 10)).foregroundStyle(CinemaStyle.secondary).fixedSize(horizontal: false, vertical: true)
            }
        }
    }
}
