import SwiftUI
import AppKit
import CinemaCore

struct PlayerView: View {
    @ObservedObject var app: AppModel
    @ObservedObject var playback: PlaybackController
    @LegacyState private var showEpisodes = true
    @LegacyState private var dragging = false
    @LegacyState private var slider = 0.0
    @LegacyState private var showStats = false
    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 17) {
                Button { app.closePlayer() } label: { Image(systemName: "chevron.left").frame(width: 30, height: 30) }.buttonStyle(.plain).help("返回片库")
                VStack(alignment: .leading, spacing: 4) { Text(playback.title).font(.system(size: 14, weight: .medium)); Text(playback.episodeName).font(.system(size: 10)).foregroundStyle(CinemaStyle.secondary) }
                Spacer()
                Button { showStats.toggle() } label: { Label("播放信息", systemImage: "waveform.path") }.buttonStyle(.plain).font(.system(size: 11)).foregroundStyle(CinemaStyle.secondary)
                Button { showEpisodes.toggle() } label: { Label("选集", systemImage: "list.bullet.rectangle") }.buttonStyle(.plain).font(.system(size: 11)).foregroundStyle(CinemaStyle.accent)
            }.padding(.horizontal, 20).padding(.vertical, 15)
            HStack(spacing: 0) {
                VStack(spacing: 0) {
                    ZStack {
                        Color.black
                        VideoSurface(player: playback.player, mode: playback.enhancementMode, generation: playback.generation) { metrics in playback.metrics = metrics }
                        if !playback.subtitleText.isEmpty {
                            VStack { Spacer(); Text(playback.subtitleText).font(.system(size: 22, weight: .medium)).multilineTextAlignment(.center).foregroundStyle(.white).shadow(color: .black, radius: 2, y: 1).padding(.horizontal, 14).padding(.vertical, 5).background(.black.opacity(0.5), in: RoundedRectangle(cornerRadius: 5)).padding(.bottom, 32).padding(.horizontal, 30) }
                        }
                        if playback.isLoading { ProgressView("正在缓冲…").padding(20).background(.black.opacity(0.65), in: RoundedRectangle(cornerRadius: 10)) }
                        if let error = playback.error {
                            VStack(spacing: 17) { Image(systemName: "exclamationmark.circle").font(.largeTitle); Text(error).font(.system(size: 13)).multilineTextAlignment(.center).frame(maxWidth: 430); HStack { Button("重试当前集") { playback.retry() }.buttonStyle(.borderedProminent); Button("关闭提示") { playback.error = nil } } }.padding(30).background(CinemaStyle.panel, in: RoundedRectangle(cornerRadius: 14))
                        }
                        if showStats { VStack { HStack { statistics.padding(14); Spacer() }; Spacer() } }
                    }.frame(maxWidth: .infinity, maxHeight: .infinity).onTapGesture(count: 2) { NSApp.keyWindow?.toggleFullScreen(nil) }
                    controls
                }
                if showEpisodes {
                    Divider().overlay(CinemaStyle.border)
                    episodePanel.frame(width: 258)
                }
            }
        }
        .background(CinemaStyle.background)
        .onKeyPress(.space) { playback.togglePlayback(); return .handled }
        .onKeyPress(.leftArrow) { playback.skip(-10); return .handled }
        .onKeyPress(.rightArrow) { playback.skip(10); return .handled }
        .onKeyPress("f") { NSApp.keyWindow?.toggleFullScreen(nil); return .handled }
        .onKeyPress("m") { playback.volume = playback.volume > 0 ? 0 : 0.8; return .handled }
        .focusable().focusEffectDisabled()
        .onChange(of: playback.position) { _, value in if !dragging { slider = value } }
    }
    private var controls: some View {
        VStack(spacing: 15) {
            Slider(value: $slider, in: 0...max(1, playback.duration), onEditingChanged: { editing in dragging = editing; if !editing { playback.seek(to: slider) } }).tint(CinemaStyle.accent).disabled(playback.duration <= 0).accessibilityLabel("播放进度")
            HStack(spacing: 19) {
                Button { playback.togglePlayback() } label: { Image(systemName: playback.isPlaying ? "pause.fill" : "play.fill").font(.system(size: 19)).frame(width: 24) }.help("播放/暂停 · 空格")
                Button { playback.skip(-10) } label: { Image(systemName: "gobackward.10").font(.system(size: 19)) }
                Button { playback.skip(10) } label: { Image(systemName: "goforward.10").font(.system(size: 19)) }
                Button { app.nextEpisode() } label: { Image(systemName: "forward.end").font(.system(size: 17)) }.disabled(app.selectedLine == nil)
                Text("\(timeString(playback.position)) / \(timeString(playback.duration))").font(.system(size: 10, design: .monospaced)).foregroundStyle(CinemaStyle.secondary)
                Spacer(minLength: 5)
                Menu { ForEach([0.5, 1, 1.25, 1.5, 2], id: \.self) { speed in Button("\(speed, specifier: "%g")×") { playback.setRate(Float(speed)) } } } label: { Text("\(playback.rate, specifier: "%g")×").font(.system(size: 12)) }.menuStyle(.borderlessButton).fixedSize()
                Menu {
                    Button("导入 SRT / VTT / ASS…") { app.importSubtitle() }
                    Button("关闭字幕") { playback.selectSubtitle(-1) }
                    ForEach(playback.subtitleTracks) { track in Button(track.name) { playback.selectSubtitle(track.id) } }
                    if playback.externalSubtitleName != nil { Divider(); Button("字幕提前 0.5 秒") { playback.subtitleOffset -= 0.5 }; Button("字幕延后 0.5 秒") { playback.subtitleOffset += 0.5 } }
                    if !playback.audioTracks.isEmpty { Divider(); ForEach(playback.audioTracks) { track in Button("音轨 · \(track.name)") { playback.selectAudio(track.id) } } }
                } label: { Image(systemName: "captions.bubble").font(.system(size: 16)) }.menuStyle(.borderlessButton).fixedSize().help("字幕与音轨")
                HStack(spacing: 6) { Image(systemName: playback.volume == 0 ? "speaker.slash" : "speaker.wave.2").font(.system(size: 12)); Slider(value: $playback.volume, in: 0...1).frame(width: 68) }
                Button { NSApp.keyWindow?.toggleFullScreen(nil) } label: { Image(systemName: "arrow.up.left.and.arrow.down.right").font(.system(size: 14)) }.help("全屏 · F")
            }.buttonStyle(.plain)
            HStack(spacing: 8) {
                Circle().fill((playback.metrics?.fallbackReason == nil) ? CinemaStyle.accent : .gray).frame(width: 5, height: 5)
                Text(playback.metrics.map { "\($0.sourceWidth)×\($0.sourceHeight) → \($0.outputWidth)×\($0.outputHeight) · \($0.mode)" } ?? "正在读取实际画面信息…").font(.system(size: 10)).foregroundStyle(CinemaStyle.secondary).lineLimit(1)
                Spacer()
                Menu { ForEach(EnhancementMode.allCases) { mode in Button(mode.title) { playback.enhancementMode = mode } } } label: { HStack(spacing: 5) { Image(systemName: "sparkles"); Text("画质增强") }.font(.system(size: 10)).foregroundStyle(CinemaStyle.accent) }.menuStyle(.borderlessButton).fixedSize()
            }
            if let reason = playback.metrics?.fallbackReason { Text(reason).font(.system(size: 10)).foregroundStyle(CinemaStyle.accent).frame(maxWidth: .infinity, alignment: .leading) }
        }.padding(.horizontal, 22).padding(.vertical, 17).background(CinemaStyle.panel)
    }
    private var episodePanel: some View {
        VStack(alignment: .leading, spacing: 21) {
            Text("正在放映").font(.system(size: 11, weight: .semibold)).tracking(1).foregroundStyle(CinemaStyle.accent)
            Text(playback.title).font(.system(size: 21, weight: .medium, design: .serif)).lineLimit(3)
            if let detail = app.detail {
                Picker("线路", selection: Binding(get: {app.selectedLineID}, set: {app.switchLine($0)})) { ForEach(detail.lines) { Text($0.name).tag($0.id) } }.labelsHidden()
                ScrollView { LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())], spacing: 8) {
                    ForEach(app.selectedLine?.episodes ?? []) { episode in
                        Button { app.play(episode) } label: { Text(episode.name).font(.system(size: 11)).lineLimit(1).frame(maxWidth: .infinity).padding(.vertical, 11).foregroundStyle(episode.id == app.currentEpisodeID ? CinemaStyle.accent : .white.opacity(0.75)).background(episode.id == app.currentEpisodeID ? CinemaStyle.accent.opacity(0.1) : Color.white.opacity(0.04), in: RoundedRectangle(cornerRadius: 6)) }.buttonStyle(.plain)
                    }
                } }
                Toggle("自动播放下一集", isOn: $app.autoNext).font(.system(size: 11)).toggleStyle(.switch)
            } else { Text("通过搜索打开剧集，可以在这里选择其他集数与线路。").font(.system(size: 12)).foregroundStyle(CinemaStyle.secondary); Spacer() }
            alternativeSourcePanel
        }.padding(22)
    }
    private var alternativeSourcePanel: some View {
        VStack(alignment: .leading, spacing: 10) {
            Divider().overlay(CinemaStyle.border)
            Button { app.findAlternativeSources() } label: {
                HStack(spacing: 7) {
                    if app.alternativesLoading { ProgressView().controlSize(.small) }
                    else { Image(systemName: "arrow.triangle.swap") }
                    Text(app.alternativesLoading ? "正在查找与核对…" : "查找其他片源")
                }.font(.system(size: 11)).foregroundStyle(CinemaStyle.accent)
            }.buttonStyle(.plain).disabled(app.alternativesLoading)
            if !app.alternativeSources.isEmpty {
                ScrollView {
                    VStack(alignment: .leading, spacing: 7) {
                        ForEach(app.alternativeSources, id: \.self) { title in
                            Button { app.switchAlternativeSource(title) } label: {
                                VStack(alignment: .leading, spacing: 4) {
                                    Text(title.providerName).font(.system(size: 10, weight: .semibold)).foregroundStyle(CinemaStyle.accent)
                                    Text(title.title).font(.system(size: 11)).foregroundStyle(.white.opacity(0.85)).lineLimit(2)
                                    Text("画质未知 · 核对同季同集后切换").font(.system(size: 9)).foregroundStyle(CinemaStyle.secondary)
                                }.frame(maxWidth: .infinity, alignment: .leading).padding(9).background(Color.white.opacity(0.04), in: RoundedRectangle(cornerRadius: 6))
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
    private var statistics: some View {
        VStack(alignment: .leading, spacing: 7) {
            Text("播放诊断").font(.system(size: 11, weight: .bold))
            if let m = playback.metrics {
                Text("源 \(m.sourceWidth)×\(m.sourceHeight) / 输出 \(m.outputWidth)×\(m.outputHeight)")
                Text("处理 \(m.processingMS, specifier: "%.2f") ms / 帧")
                Text("处理 \(m.processedFrames) · 呈现 \(m.renderedFrames) · 忙碌跳过 \(m.droppedFrames)")
                Text(m.mode)
            }
            if let info = playback.sourceInfo { Text("HLS \(info.segmentCount) 分片 · \(timeString(info.duration))") }
        }.font(.system(size: 10, design: .monospaced)).padding(14).background(.black.opacity(0.75), in: RoundedRectangle(cornerRadius: 8))
    }
}
