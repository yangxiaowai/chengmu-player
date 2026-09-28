import SwiftUI
import AppKit
import CinemaCore

private struct PlaybackControlHeightKey: PreferenceKey {
    static let defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) { value = max(value, nextValue()) }
}

struct PlayerView: View {
    @ObservedObject var app: AppModel
    @ObservedObject var playback: PlaybackController
    @LegacyState private var showEpisodes = false
    @LegacyState private var dragging = false
    @LegacyState private var slider = 0.0
    @LegacyState private var showStats = false
    @LegacyState private var showExperience = false
    @LegacyState private var showJump = false
    @LegacyState private var showShortcuts = false
    @LegacyState private var controlHeight: CGFloat = 165
    @LegacyState private var editingAds = false
    @LegacyState private var adDraft = AdCleanupSettings()
    @LegacyState private var originalCleanup = AdCleanupSettings()
    @LegacyState private var adTool = AdSelectionTool.advertisement
    @LegacyState private var adNotice: String?
    @LegacyState private var adEditingItemID: UUID?
    @LegacyState private var adEditingIntentID: UUID?
    @LegacyState private var resumeAfterAdEditing = false
    @StateObject private var presentation = PlayerPresentationController()
    var body: some View {
        HStack(spacing: 0) {
                VStack(spacing: 0) {
                    ZStack {
                        Color.black
                        VideoSurface(player: playback.player, mode: playback.surfaceMode, generation: playback.generation, cleanup: playback.adCleanup,
                                     permission: playback.videoPermission, assessedItem: playback.player.currentItem,
                                     onScanFrame: { image, time in _ = playback.harvestScanFrame(image, time: time) }) { metrics in playback.metrics = metrics }
                        if !editingAds { PlaybackKeyboardSurface(playback: playback, presentation: presentation) }
                        if !playback.subtitleText.isEmpty {
                            VStack { Spacer(); Text(playback.subtitleText).font(.system(size: 22, weight: .medium)).multilineTextAlignment(.center).foregroundStyle(.white).shadow(color: .black, radius: 2, y: 1).padding(.horizontal, 14).padding(.vertical, 5).background(.black.opacity(0.5), in: RoundedRectangle(cornerRadius: 5)).padding(.bottom, subtitleBottomPadding).padding(.horizontal, 30) }
                                .allowsHitTesting(false)
                        }
                        if playback.isLoading {
                            VStack(spacing: 14) {
                                ProgressView(playback.loadingMessage ?? "正在缓冲…")
                                if playback.recoverySuggested {
                                    Text("等待时间较长，可以重试当前集或查找其他片源。")
                                        .font(.system(size: 12)).foregroundStyle(CinemaStyle.secondary)
                                    HStack {
                                        Button("重试当前集") { playback.retry() }
                                        Button("查找其他片源") { presentation.leaveFullscreen(); showEpisodes = true; app.findAlternativeSources() }.disabled(app.alternativesLoading)
                                    }
                                }
                            }.padding(20).background(.black.opacity(0.75), in: RoundedRectangle(cornerRadius: 10))
                                .allowsHitTesting(playback.recoverySuggested)
                        }
                        if let error = playback.error {
                            VStack(spacing: 17) {
                                Image(systemName: "exclamationmark.circle").font(.largeTitle)
                                Text(error).font(.system(size: 13)).multilineTextAlignment(.center).frame(maxWidth: 430)
                                HStack {
                                    Button("重试当前集") { playback.retry() }.buttonStyle(.borderedProminent)
                                    Button("查找其他片源") { presentation.leaveFullscreen(); showEpisodes = true; app.findAlternativeSources() }.disabled(app.alternativesLoading)
                                    Button("关闭提示") { playback.error = nil }
                                }
                            }.padding(30).background(CinemaStyle.panel, in: RoundedRectangle(cornerRadius: 14))
                        }
                        if showStats && presentation.controlsVisible {
                            VStack { HStack { statistics.padding(22); Spacer() }; Spacer() }
                                .padding(.top, 96).allowsHitTesting(false)
                        }
                        if !editingAds {
                            VStack(spacing: 0) {
                                header
                                notificationStack
                                Spacer(minLength: 0)
                                controls
                            }
                            .opacity(presentation.controlsVisible ? 1 : 0)
                            .allowsHitTesting(presentation.controlsVisible)
                            .accessibilityHidden(!presentation.controlsVisible)
                            .animation(.easeInOut(duration: 0.2), value: presentation.controlsVisible)
                        }
                        if editingAds {
                            AdCleanupCanvas(draft: $adDraft, tool: adTool, videoSize: videoDisplaySize, notice: $adNotice)
                        }
                    }.frame(maxWidth: .infinity, maxHeight: .infinity)
                    if editingAds {
                        AdCleanupControls(draft: $adDraft, tool: $adTool, videoSize: videoDisplaySize, notice: $adNotice, onCancel: { finishAdEditing(apply: false) }, onApply: { finishAdEditing(apply: true) })
                    }
                }
                if showEpisodes && !presentation.isFullscreen {
                    Divider().overlay(CinemaStyle.border)
                    PlayerEpisodePanel(app: app).frame(width: 300).disabled(editingAds)
                }
        }
        .background(CinemaStyle.background)
        .background(PlayerWindowAttachment(presentation: presentation).frame(width: 0, height: 0))
        .ignoresSafeArea(.container, edges: presentation.isFullscreen ? .all : [])
        .onAppear { updatePresentation() }
        .onDisappear { abandonAdEditing(); presentation.detach() }
        .onChange(of: playback.isPlaying) { _, _ in updatePresentation() }
        .onChange(of: playback.isLoading) { _, _ in updatePresentation() }
        .onChange(of: playback.error) { _, _ in updatePresentation() }
        .onChange(of: playback.adSkipNotice?.id) { _, value in
            if value != nil { presentation.activity() }
            else { presentation.interact("ad-notice", active: false) }
        }
        .onChange(of: playback.subtitleNotice) { _, value in
            if value == nil { presentation.interact("subtitle-notice", active: false) }
        }
        .focusedSceneValue(\.playerCommands, editingAds || showJump || showShortcuts || showExperience ? nil : commandContext)
        .sheet(isPresented: $showJump) {
            JumpToTimeDialog(current: playback.position, duration: playback.duration) { target in playback.seek(to: target) }
        }
        .sheet(isPresented: $showShortcuts) { PlaybackShortcutsDialog() }
        .sheet(isPresented: $showExperience) { MediaExperienceView(experience: playback.experience, playback: playback) }
        .onChange(of: showJump) { _, value in playback.setAdSkipInteraction("jump-dialog", active: value) }
        .onChange(of: showShortcuts) { _, value in playback.setAdSkipInteraction("shortcuts", active: value) }
        .onChange(of: showExperience) { _, value in playback.setAdSkipInteraction("experience", active: value) }
        .onExitCommand { if editingAds { finishAdEditing(apply: false) } else if presentation.isFullscreen { presentation.leaveFullscreen() } }
        .onChange(of: playback.itemID) { _, _ in abandonAdEditing(); showJump = false; showShortcuts = false; showExperience = false }
        .onChange(of: playback.position) { _, value in if !dragging { slider = value } }
        .onPreferenceChange(PlaybackControlHeightKey.self) { height in
            if height.isFinite && height > 0 { controlHeight = height }
        }
    }
    private var canSeek: Bool { playback.duration.isFinite && playback.duration > 0 && !playback.hasPlaybackFailure && playback.error == nil }
    private func performCommand(_ action: () -> Void) {
        guard !editingAds, !showJump, !showShortcuts, !showExperience, presentation.canPerformPlayerCommand else { return }
        presentation.activity(); action()
    }
    private var commandContext: PlayerCommandContext {
        PlayerCommandContext(playing: playback.playbackRequested, canSeek: canSeek,
            canPrevious: app.canPlayPrevious, canNext: app.canPlayNext,
            fullscreen: presentation.isFullscreen, episodesShown: showEpisodes && !presentation.isFullscreen,
            togglePlayback: { performCommand { playback.togglePlayback() } },
            skip: { amount in performCommand { if canSeek { playback.skip(amount) } } },
            jumpToTime: { performCommand { if canSeek { showJump = true } } },
            previous: { performCommand { app.previousEpisode() } }, next: { performCommand { app.nextEpisode() } },
            toggleFullscreen: { performCommand { presentation.toggleFullscreen() } },
            toggleEpisodes: { performCommand {
                if presentation.isFullscreen { presentation.leaveFullscreen(); showEpisodes = true }
                else { showEpisodes.toggle() }
            } },
            showShortcuts: { performCommand { showShortcuts = true } })
    }
    private func updatePresentation() {
        presentation.updatePlayback(isPlaying: playback.isPlaying, isBuffering: playback.isLoading, hasError: playback.error != nil)
    }
    private var videoDisplaySize: CGSize {
        // Match the geometry of the surface currently shown, not the encoded buffer.
        let size: CGSize
        if let metrics = playback.metrics, metrics.outputWidth > 0, metrics.outputHeight > 0 {
            size = CGSize(width: metrics.outputWidth, height: metrics.outputHeight)
        } else { size = playback.player.currentItem?.presentationSize ?? .zero }
        guard size.width.isFinite, size.height.isFinite, size.width > 0, size.height > 0 else { return .zero }
        return size
    }
    private func beginAdEditing() {
        guard videoDisplaySize.width > 0, videoDisplaySize.height > 0 else { return }
        adEditingItemID = playback.itemID; resumeAfterAdEditing = playback.playbackRequested
        originalCleanup = playback.adCleanup; adDraft = playback.adCleanup
        adTool = .advertisement; adNotice = "拖动框选广告，或切换到“保护字幕”添加保护区。"
        playback.pause()
        adEditingIntentID = playback.playbackIntentID
        playback.adCleanup.enabled = false
        presentation.interact("ad-editor", active: true); editingAds = true
    }
    private func finishAdEditing(apply: Bool) {
        guard editingAds, adEditingItemID == playback.itemID else { abandonAdEditing(); return }
        if apply {
            let size = videoDisplaySize
            guard !adDraft.regions.isEmpty, adDraft.regions.allSatisfy({ AdCleanupPolicy.rejectionReason(for: $0, protectedRegions: adDraft.protectedRegions, width: Int(size.width), height: Int(size.height)) == nil }) else {
                adNotice = "选区与字幕保护区冲突或尺寸尚未就绪，请检查后再应用。"; return
            }
            adDraft.enabled = true; playback.adCleanup = adDraft
        } else { playback.adCleanup = originalCleanup }
        let shouldResume = resumeAfterAdEditing
        let intent = adEditingIntentID
        editingAds = false; adEditingItemID = nil; resumeAfterAdEditing = false
        adEditingIntentID = nil
        presentation.interact("ad-editor", active: false)
        if shouldResume, let intent { playback.resumeAfterEditing(ifUnchanged: intent) }
    }
    private func abandonAdEditing() {
        guard editingAds else { return }
        // Leaving or switching episodes must never apply a draft or restart playback.
        if adEditingItemID == playback.itemID { playback.adCleanup = originalCleanup }
        editingAds = false; adEditingItemID = nil; resumeAfterAdEditing = false
        adEditingIntentID = nil
        presentation.interact("ad-editor", active: false)
    }
    private var subtitleBottomPadding: CGFloat {
        presentation.controlsVisible && !editingAds ? controlHeight + 18 : 32
    }
    private var header: some View {
        HStack(spacing: 13) {
            Button { presentation.leaveFullscreen(); app.closePlayer() } label: {
                PlayerChromeIcon(systemName: "chevron.left", symbolSize: 15)
            }
            .help("返回片库")
            .accessibilityLabel("返回片库")
            VStack(alignment: .leading, spacing: 3) {
                Text(playback.title)
                    .font(.system(size: 17, weight: .semibold))
                    .foregroundStyle(CinemaStyle.primary)
                    .lineLimit(1)
                if !playback.episodeName.isEmpty {
                    Text(playback.episodeName)
                        .font(.system(size: 11))
                        .foregroundStyle(.white.opacity(0.66))
                        .lineLimit(1)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            Button { showExperience = true } label: {
                PlayerChromeIcon(systemName: "waveform.path", selected: playback.experience.status.videoIsHDR || playback.experience.status.audioIsAtmos)
            }
            .help("视听适配：片源、轨道与设备能力")
            .accessibilityLabel("视听适配")
            if !presentation.isFullscreen {
                Button { showEpisodes.toggle() } label: {
                    HStack(spacing: 7) {
                        Image(systemName: "list.bullet.rectangle").font(.system(size: 15))
                        Text("选集").font(.system(size: 11, weight: .semibold))
                    }
                    .foregroundStyle(showEpisodes ? CinemaStyle.accent : CinemaStyle.primary)
                    .padding(.horizontal, 13)
                    .frame(height: 42)
                    .background(showEpisodes ? CinemaStyle.accentSoft : Color.white.opacity(0.055), in: RoundedRectangle(cornerRadius: 13, style: .continuous))
                    .contentShape(Rectangle())
                }
                .help(showEpisodes ? "收起选集" : "展开选集")
                .accessibilityLabel(showEpisodes ? "收起选集" : "展开选集")
            }
        }
        .buttonStyle(PlayerChromeButtonStyle())
        .padding(.horizontal, presentation.isFullscreen ? 34 : 22)
        .padding(.top, presentation.isFullscreen ? 19 : 26)
        .padding(.bottom, 30)
        .background(CinemaStyle.headerScrim.allowsHitTesting(false))
    }

    private var notificationStack: some View {
        VStack(alignment: .trailing, spacing: 8) {
            if let event = playback.adSkipNotice {
                HStack(spacing: 10) {
                    Image(systemName: "forward.end.fill").foregroundStyle(CinemaStyle.accent)
                    Text("已跳过插播 \(timeString(event.returnPosition))–\(timeString(event.segment.end))")
                        .lineLimit(1)
                    Button { playback.undoAdSkip() } label: {
                        Text("撤销")
                            .foregroundStyle(CinemaStyle.accent)
                            .frame(minWidth: 36, minHeight: 36)
                            .background(CinemaStyle.accentSoft, in: RoundedRectangle(cornerRadius: 9, style: .continuous))
                            .contentShape(Rectangle())
                    }
                    .accessibilityLabel("撤销跳过")
                    Button { playback.dismissAdSkipNotice() } label: {
                        Image(systemName: "xmark").frame(width: 36, height: 36).contentShape(Rectangle())
                    }
                        .help("关闭跳过提示").accessibilityLabel("关闭跳过提示")
                }
                .font(.system(size: 11, weight: .medium))
                .padding(.horizontal, 13).padding(.vertical, 10)
                .background(CinemaStyle.overlayStrong, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                .onHover { presentation.interact("ad-notice", active: $0) }
            }
            if let notice = playback.subtitleNotice {
                HStack(spacing: 9) {
                    Image(systemName: "captions.bubble.fill").foregroundStyle(CinemaStyle.accent)
                    Text(notice).lineLimit(2)
                    Button { playback.subtitleNotice = nil } label: {
                        Image(systemName: "xmark").frame(width: 36, height: 36).contentShape(Rectangle())
                    }
                        .help("关闭字幕提示").accessibilityLabel("关闭字幕提示")
                }
                .font(.system(size: 11))
                .padding(.horizontal, 13).padding(.vertical, 10)
                .background(CinemaStyle.overlayStrong, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                .onHover { presentation.interact("subtitle-notice", active: $0) }
            }
        }
        .buttonStyle(.plain)
        .frame(maxWidth: .infinity, alignment: .trailing)
        .padding(.horizontal, presentation.isFullscreen ? 36 : 24)
    }

    private var sleepMenu: some View {
        Menu {
            ForEach(PlaybackSleepTimer.minuteOptions, id: \.self) { minutes in
                Button("\(minutes) 分钟后暂停") { playback.scheduleSleepTimer(minutes: minutes) }
            }
            if playback.sleepRemainingSeconds != nil {
                Divider()
                Button("取消睡眠定时") { playback.cancelSleepTimer() }
            }
        } label: {
            Label(playback.sleepRemainingSeconds.map { "\(timeString(Double($0))) 后暂停" } ?? "睡眠定时", systemImage: "moon.zzz")
        }
    }

    private var speedMenu: some View {
        Menu {
            Picker("播放速度", selection: $playback.rate) {
                ForEach([Float(0.5), 0.75, 1, 1.25, 1.5, 2], id: \.self) { speed in
                    Text("\(speed, specifier: "%g")×").tag(speed)
                }
            }.pickerStyle(.inline)
        } label: { PlayerChromeText(text: String(format: "%g×", playback.rate), monospaced: true) }
            .accessibilityLabel(String(format: "播放速度，%g 倍", playback.rate))
            .menuStyle(.borderlessButton).fixedSize().help("播放速度")
    }

    private var subtitleMenu: some View {
        Menu {
            Button("导入 SRT / VTT / ASS…") { app.importSubtitle() }
            Toggle("关闭字幕", isOn: Binding(get: { playback.selectedSubtitle == -1 && playback.externalSubtitleName == nil }, set: { if $0 { playback.selectSubtitle(-1) } }))
            ForEach(playback.subtitleTracks) { track in
                Toggle(track.name, isOn: Binding(get: { playback.selectedSubtitle == track.id && playback.externalSubtitleName == nil }, set: { if $0 { playback.selectSubtitle(track.id) } }))
            }
            if let name = playback.externalSubtitleName {
                Divider()
                Label("外部字幕 · \(name)", systemImage: "checkmark")
                Text("字幕偏移：\(playback.subtitleOffset, specifier: "%+.1f") 秒")
                Button("字幕提前 0.5 秒") { playback.subtitleOffset -= 0.5 }
                Button("字幕延后 0.5 秒") { playback.subtitleOffset += 0.5 }
                Button("重置字幕偏移") { playback.subtitleOffset = 0 }
            }
            if !playback.audioTracks.isEmpty {
                Divider()
                ForEach(playback.audioTracks) { track in
                    Toggle("音轨 · \(track.name)", isOn: Binding(get: { playback.selectedAudio == track.id }, set: { if $0 { playback.selectAudio(track.id) } }))
                }
            }
        } label: { PlayerChromeIcon(systemName: "captions.bubble", symbolSize: 16) }
            .accessibilityLabel("字幕与音轨")
            .menuStyle(.borderlessButton).fixedSize().help("字幕与音轨")
    }

    private var qualityMenu: some View {
        Menu {
            Picker("画面模式", selection: Binding(get: { playback.selectedPictureMode }, set: { playback.selectEnhancementMode($0) })) {
                ForEach(EnhancementMode.allCases) { mode in
                    Text(mode.title).tag(mode)
                }
            }.pickerStyle(.inline)
            Divider()
            Text("所选：\(playback.selectedPictureMode.title)")
            Text("正在呈现：\(playback.pictureStatusTitle)")
            Text(playback.pictureStatusDetail)
            if let dimensions = pictureDimensions { Text(dimensions) }
            if playback.isComparingOriginal {
                Button("结束对照，恢复所选模式") { playback.toggleOriginalComparison() }
            } else {
                Button("临时查看原片") { playback.toggleOriginalComparison() }
                    .disabled(!playback.canCompareOriginal)
            }
            Divider()
            Text("杜比视界与 HDR 使用系统原生呈现")
            Text("4K 缩放改变输出尺寸，不等于恢复原生 4K 细节")
        } label: {
            PlayerChromeIcon(systemName: playback.pictureIsEnhanced ? "sparkles" : "film", selected: playback.pictureIsEnhanced)
        }
        .accessibilityLabel("画质设置，\(playback.pictureStatusTitle)")
        .menuStyle(.borderlessButton).fixedSize().help("画质增强与原片直通")
    }

    private var pictureDimensions: String? {
        guard let metrics = playback.metrics,
              metrics.sourceWidth > 0, metrics.sourceHeight > 0,
              metrics.outputWidth > 0, metrics.outputHeight > 0 else { return nil }
        return "片源 \(metrics.sourceWidth)×\(metrics.sourceHeight) → 输出 \(metrics.outputWidth)×\(metrics.outputHeight)"
    }

    private var originalComparisonButton: some View {
        Button { playback.toggleOriginalComparison() } label: {
            PlayerChromeIcon(systemName: "circle.lefthalf.filled", selected: playback.isComparingOriginal, symbolSize: 17)
        }
        .disabled(!playback.canCompareOriginal && !playback.isComparingOriginal)
        .opacity(playback.canCompareOriginal || playback.isComparingOriginal ? 1 : 0.35)
        .help(playback.isComparingOriginal ? "结束原片对照，恢复所选模式" : (playback.canCompareOriginal ? "临时查看原片，再次点击恢复增强" : "增强画面就绪后可与原片对照"))
        .accessibilityLabel(playback.isComparingOriginal ? "结束原片对照" : "查看原片对照")
    }

    private var moreMenu: some View {
        Menu {
            Toggle("自动识别并跳过插播（实验）", isOn: $playback.automaticAdSkipping)
            Text(playback.automaticAdSkipping ? playback.adSkip.status : "自动跳过已关闭")
            Text("已识别 \(playback.adSkip.segments.count) 段 · 已分析 \(playback.adSkip.analyzedFrames) 帧")
            Text("帧来源：\(playback.adSkip.frameSource)")
            Button("撤销上次跳过并暂停") { playback.undoAdSkip() }.disabled(playback.adSkipNotice == nil)
            Divider()
            Menu {
                Button("框选广告与字幕保护区…") { beginAdEditing() }.disabled(videoDisplaySize.width <= 0)
                if !playback.adCleanup.regions.isEmpty {
                    Button(playback.adCleanup.enabled ? "关闭柔化，显示原画面" : "启用已确认的选区") { playback.adCleanup.enabled.toggle() }
                    Button("清除当前影片的所有选区") { playback.adCleanup = AdCleanupSettings() }
                }
                if playback.adCleanup.isActive, let metrics = playback.metrics {
                    Text(metrics.cleanupReason ?? "已柔化 \(metrics.cleanupAppliedRegions) 个区域 · 字幕保护区保持原画面")
                }
            } label: { Label("广告文字柔化", systemImage: "rectangle.dashed") }
            sleepMenu
            Menu("音量") {
                Button("调高 10%") { playback.adjustVolume(0.1) }
                Button("调低 10%") { playback.adjustVolume(-0.1) }
                Button("静音 / 恢复") { playback.toggleMute() }
            }
            Divider()
            Button("视听适配…") { showExperience = true }
            Button("播放信息") { showStats.toggle() }
            Button("快捷键…") { showShortcuts = true }
        } label: { PlayerChromeIcon(systemName: "ellipsis", symbolSize: 20) }
            .accessibilityLabel("更多播放设置")
            .menuStyle(.borderlessButton).fixedSize().help("更多播放设置")
    }

    private var controls: some View {
        VStack(spacing: 7) {
            HStack(spacing: 8) {
                Image(systemName: playback.isComparingOriginal ? "circle.lefthalf.filled" : (playback.pictureIsEnhanced ? "sparkles" : "film"))
                    .foregroundStyle(playback.isComparingOriginal || playback.pictureIsEnhanced ? CinemaStyle.accent : CinemaStyle.secondary)
                Text(playback.pictureStatusTitle)
                    .foregroundStyle(CinemaStyle.primary)
                    .fixedSize()
                Text(playback.pictureStatusDetail)
                    .foregroundStyle(CinemaStyle.secondary)
                    .lineLimit(1)
                    .truncationMode(.tail)
                Spacer(minLength: 0)
            }
            .font(.system(size: 10))
            .help(playback.pictureStatusDetail)
            .allowsHitTesting(false)
            SeekBar(value: $slider, duration: playback.duration, asset: playback.player.currentItem?.asset, itemID: playback.itemID,
                    visible: presentation.controlsVisible,
                    onEditing: { editing in dragging = editing; presentation.interact("seek", active: editing); playback.setAdSkipInteraction("seek", active: editing) },
                    onSeek: { playback.seek(to: $0) },
                    onHover: { presentation.interact("seek-preview", active: $0); playback.setAdSkipInteraction("seek-preview", active: $0) })
            HStack(spacing: 5) {
                Button { playback.skip(-10) } label: { PlayerChromeIcon(systemName: "gobackward.10", symbolSize: 19) }
                    .help("快退 10 秒 · ←").accessibilityLabel("快退 10 秒")
                Button { playback.togglePlayback() } label: {
                    PlayerChromeIcon(systemName: playback.playbackRequested ? "pause.fill" : "play.fill", prominent: true, symbolSize: 18)
                }
                .help("播放/暂停 · 空格")
                .accessibilityLabel(playback.playbackRequested ? "暂停" : "播放")
                Button { playback.skip(10) } label: { PlayerChromeIcon(systemName: "goforward.10", symbolSize: 19) }
                    .help("快进 10 秒 · →").accessibilityLabel("快进 10 秒")
                if !showEpisodes || presentation.isFullscreen {
                    Button { app.nextEpisode() } label: { PlayerChromeIcon(systemName: "forward.end.fill", symbolSize: 15) }
                        .disabled(!app.canPlayNext).opacity(app.canPlayNext ? 1 : 0.35).help("下一集")
                        .accessibilityLabel("下一集")
                }
                Button { showJump = true } label: {
                    PlayerChromeText(text: showEpisodes && !presentation.isFullscreen ? timeString(playback.position) : "\(timeString(playback.position)) / \(timeString(playback.duration))", monospaced: true)
                }
                .disabled(!canSeek).help("\(timeString(playback.position)) / \(timeString(playback.duration)) · 跳转到时间 · ⌘J")
                .accessibilityLabel("跳转到时间").accessibilityValue("\(timeString(playback.position))，共 \(timeString(playback.duration))")
                Spacer(minLength: 3)
                speedMenu
                subtitleMenu
                originalComparisonButton
                qualityMenu
                HStack(spacing: 1) {
                    Button { playback.toggleMute() } label: {
                        PlayerChromeIcon(systemName: playback.volume == 0 ? "speaker.slash.fill" : "speaker.wave.2.fill", symbolSize: 15)
                    }.help("静音 / 恢复音量 · M").accessibilityLabel(playback.volume == 0 ? "恢复音量" : "静音")
                    if !showEpisodes || presentation.isFullscreen {
                        Slider(value: $playback.volume, in: 0...1,
                               onEditingChanged: { presentation.interact("volume", active: $0) })
                            .frame(width: 64).accessibilityLabel("播放音量")
                    }
                }
                moreMenu
                Button { presentation.toggleFullscreen() } label: {
                    PlayerChromeIcon(systemName: presentation.isFullscreen ? "arrow.down.right.and.arrow.up.left" : "arrow.up.left.and.arrow.down.right", symbolSize: 15)
                }.help(presentation.isFullscreen ? "退出全屏 · Esc / F" : "全屏 · F")
                    .accessibilityLabel(presentation.isFullscreen ? "退出全屏" : "进入全屏")
            }
            .buttonStyle(PlayerChromeButtonStyle())
        }
        .padding(.horizontal, presentation.isFullscreen ? 34 : 22)
        .padding(.top, 31)
        .padding(.bottom, presentation.isFullscreen ? 23 : 16)
        .background(CinemaStyle.controlsScrim.allowsHitTesting(false))
        .background(GeometryReader { geometry in
            Color.clear.preference(key: PlaybackControlHeightKey.self, value: geometry.size.height)
        })
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
        }.font(.system(size: 10, design: .monospaced)).padding(14)
            .background(CinemaStyle.overlayStrong, in: RoundedRectangle(cornerRadius: CinemaStyle.radius, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: CinemaStyle.radius, style: .continuous).strokeBorder(CinemaStyle.border, lineWidth: 1))
    }
}

/// Keyboard input belongs to the video canvas. Text fields, sliders and menus keep
/// their normal first-responder behavior instead of being intercepted globally.
private struct PlaybackKeyboardSurface: NSViewRepresentable {
    let playback: PlaybackController
    let presentation: PlayerPresentationController
    func makeNSView(context: Context) -> KeyboardView {
        let view = KeyboardView()
        view.bind(playback: playback, presentation: presentation)
        view.setAccessibilityElement(true)
        view.setAccessibilityRole(.group)
        view.setAccessibilityLabel("影片画面")
        view.setAccessibilityHelp("单击画面播放或暂停，双击切换全屏。可用“显示播放控制”操作呼出隐藏的按钮。空格播放暂停，左右快退快进，上下调节音量，F 全屏，M 静音，Esc 退出全屏。")
        view.setAccessibilityCustomActions([
            NSAccessibilityCustomAction(name: "显示播放控制", target: view, selector: #selector(KeyboardView.revealControls))
        ])
        return view
    }
    func updateNSView(_ view: KeyboardView, context: Context) { view.bind(playback: playback, presentation: presentation) }
    static func dismantleNSView(_ view: KeyboardView, coordinator: ()) { view.detachInput() }

    final class KeyboardView: NSView {
        weak var playback: PlaybackController?
        weak var presentation: PlayerPresentationController?
        private var generation: UUID?
        private var clicks = PlaybackCanvasClickPolicy()
        private var clickTimer: Timer?
        private var tracking: NSTrackingArea?
        private var observations: [NSObjectProtocol] = []
        private var inputMonitor: Any?

        override var acceptsFirstResponder: Bool { true }
        override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

        @objc func revealControls() -> Bool {
            presentation?.activity()
            return presentation != nil
        }

        func bind(playback: PlaybackController, presentation: PlayerPresentationController) {
            if self.playback !== playback || generation != playback.generation { cancelClick() }
            self.playback = playback; self.presentation = presentation; generation = playback.generation
        }

        override func viewWillMove(toWindow newWindow: NSWindow?) {
            if newWindow !== window { detachInput() }
            super.viewWillMove(toWindow: newWindow)
        }

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            detachInput()
            guard let window else { return }
            // Observe input without consuming it. A click on an overlaid control
            // or a shortcut must not be followed by an old delayed canvas click.
            inputMonitor = NSEvent.addLocalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown, .otherMouseDown, .keyDown]) { [weak self] event in
                guard let self, event.window === self.window else { return event }
                if event.type == .keyDown || !self.isCanvasPoint(event.locationInWindow) { self.cancelClick() }
                return event
            }
            for name in [NSWindow.didResignKeyNotification, NSWindow.willCloseNotification,
                         NSWindow.willBeginSheetNotification, NSWindow.willEnterFullScreenNotification,
                         NSWindow.willExitFullScreenNotification] {
                observations.append(NotificationCenter.default.addObserver(forName: name, object: window, queue: .main) { [weak self] _ in
                    MainActor.assumeIsolated { self?.cancelClick() }
                })
            }
            observations.append(NotificationCenter.default.addObserver(forName: NSApplication.didResignActiveNotification, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.cancelClick() }
            })
            DispatchQueue.main.async { [weak self, weak window] in
                guard let self, let window, self.window === window, window.attachedSheet == nil,
                      !(window.firstResponder is NSTextView), !(window.firstResponder is NSControl) else { return }
                window.makeFirstResponder(self)
            }
        }

        override func updateTrackingAreas() {
            super.updateTrackingAreas()
            if let tracking { removeTrackingArea(tracking) }
            let area = NSTrackingArea(rect: .zero, options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect], owner: self, userInfo: nil)
            addTrackingArea(area); tracking = area
        }

        override func mouseExited(with event: NSEvent) { cancelClick() }
        override func resignFirstResponder() -> Bool { cancelClick(); return super.resignFirstResponder() }

        override func mouseDown(with event: NSEvent) {
            guard event.modifierFlags.intersection([.command, .control, .option]).isEmpty else {
                cancelClick(); super.mouseDown(with: event); return
            }
            clickTimer?.invalidate(); clickTimer = nil
            if window?.firstResponder !== self { window?.makeFirstResponder(self) }
            presentation?.activity()
            clicks.pointerDown(button: event.buttonNumber, clickCount: event.clickCount, at: convert(event.locationInWindow, from: nil))
        }

        override func mouseDragged(with event: NSEvent) {
            clicks.pointerDragged(to: convert(event.locationInWindow, from: nil))
        }

        override func mouseUp(with event: NSEvent) {
            guard canAct else { cancelClick(); return }
            // Controls may become visible after mouseDown in fullscreen. Keep
            // the gesture owned by the canvas that received its first press.
            let point = convert(event.locationInWindow, from: nil)
            let action = clicks.pointerUp(button: event.buttonNumber, at: point,
                                          insideCanvas: bounds.contains(point),
                                          now: ProcessInfo.processInfo.systemUptime, doubleClickInterval: NSEvent.doubleClickInterval)
            perform(action)
            scheduleSingleClick()
        }

        override func rightMouseDown(with event: NSEvent) { cancelClick(); super.rightMouseDown(with: event) }
        override func otherMouseDown(with event: NSEvent) { cancelClick(); super.otherMouseDown(with: event) }

        private var canAct: Bool {
            guard let window else { return false }
            return NSApp.isActive && window.isKeyWindow && window.attachedSheet == nil
                && window.firstResponder === self && !isHiddenOrHasHiddenAncestor
        }

        private func isCanvasPoint(_ locationInWindow: NSPoint) -> Bool {
            guard let content = window?.contentView, !isHiddenOrHasHiddenAncestor else { return false }
            // NSView.hitTest expects the point in its superview's coordinates.
            let point = content.superview?.convert(locationInWindow, from: nil) ?? locationInWindow
            return content.hitTest(point) === self
        }

        private func scheduleSingleClick() {
            clickTimer?.invalidate(); clickTimer = nil
            guard let pending = clicks.pendingSingleClick else { return }
            let timer = Timer(timeInterval: max(0.001, pending.deadline - ProcessInfo.processInfo.systemUptime), repeats: false) { [weak self] _ in
                MainActor.assumeIsolated {
                    guard let self else { return }
                    guard self.canAct else { self.cancelClick(); return }
                    let action = self.clicks.fireSingleClick(pending.id, now: ProcessInfo.processInfo.systemUptime)
                    self.perform(action)
                    if self.clicks.pendingSingleClick != nil { self.scheduleSingleClick() }
                }
            }
            clickTimer = timer
            RunLoop.main.add(timer, forMode: .common)
        }

        private func perform(_ action: PlaybackCanvasClickPolicy.Action?) {
            switch action {
            case .togglePlayback: presentation?.activity(); playback?.togglePlayback()
            case .toggleFullscreen: presentation?.toggleFullscreen()
            case nil: break
            }
        }

        private func cancelClick() { clickTimer?.invalidate(); clickTimer = nil; clicks.cancel() }

        func detachInput() {
            cancelClick()
            if let inputMonitor { NSEvent.removeMonitor(inputMonitor) }
            inputMonitor = nil
            observations.forEach { NotificationCenter.default.removeObserver($0) }; observations = []
        }

        override func keyDown(with event: NSEvent) {
            cancelClick()
            guard let playback, event.modifierFlags.intersection([.command, .control, .option]).isEmpty else {
                super.keyDown(with: event); return
            }
            switch event.keyCode {
            case 49: if !event.isARepeat { playback.togglePlayback() }
            case 53: if presentation?.isFullscreen == true { presentation?.leaveFullscreen() } else { super.keyDown(with: event) }
            case 123: playback.skip(-10)
            case 124: playback.skip(10)
            case 125: playback.adjustVolume(-0.05)
            case 126: playback.adjustVolume(0.05)
            default:
                switch event.charactersIgnoringModifiers?.lowercased() {
                case "f": if !event.isARepeat { presentation?.toggleFullscreen() }
                case "m": if !event.isARepeat { playback.toggleMute() }
                default: super.keyDown(with: event)
                }
            }
        }
    }
}
