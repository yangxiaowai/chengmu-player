import AVFoundation
import AppKit
import Combine
import CinemaCore

struct MediaTrack: Identifiable {
    let id: Int
    let name: String
}

struct AdSkipEvent: Identifiable {
    let id = UUID()
    let segment: AdSkipSegment
    let returnPosition: Double
}

@MainActor
final class PlaybackController: NSObject, ObservableObject, AVPlayerItemLegibleOutputPushDelegate {
    let player = AVPlayer()
    let adSkip = AdSkipController()
    let experience = MediaExperienceInspector()
    /// What the enhancement pipeline may do for the current item; the inspector lowers it when the
    /// source is Dolby Vision or HDR.
    @Published private(set) var videoPermission = VideoProcessingPermission.inspectSDRFrames
    /// 原片直通开关. It only decides whether the realtime pipeline may replace the picture; it never
    /// changes what the source is, and Dolby/HDR sources stay on the system layer either way.
    @Published var pipelineProcessesFrames = false {
        didSet {
            guard oldValue != pipelineProcessesFrames else { return }
            isComparingOriginal = false
            if pipelineProcessesFrames && enhancementMode == .original { enhancementMode = .clarity }
            metrics = nil
            preferences.setPipeline(pipelineProcessesFrames ? PlaybackPreferences.pipelineEnhanced : PlaybackPreferences.pipelineOriginal)
            preferencesStore.save(preferences)
            // Dropping or restoring the conversion output must not rebuild the item or the clock.
            generation = UUID()
        }
    }
    /// The picture mode actually handed to the surface: 原片 when the user switched the pipeline off.
    var surfaceMode: EnhancementMode { isComparingOriginal ? .original : selectedPictureMode }
    var selectedPictureMode: EnhancementMode { pipelineProcessesFrames ? enhancementMode : .original }
    @Published private(set) var isComparingOriginal = false
    var canCompareOriginal: Bool { isComparingOriginal || pictureIsEnhanced }
    var pictureIsEnhanced: Bool {
        !isComparingOriginal && selectedPictureMode != .original && videoPermission == .inspectSDRFrames &&
        metrics?.isEnhancedOutput == true && metrics?.fallbackReason == nil
    }
    var pictureStatusTitle: String {
        if isComparingOriginal { return "原片对照" }
        if selectedPictureMode == .original { return "原片" }
        if case .nativeOnly = videoPermission { return "原生直通" }
        if pictureIsEnhanced { return metrics?.mode ?? selectedPictureMode.title }
        if metrics?.fallbackReason != nil { return "当前呈现原片" }
        return "等待画面处理"
    }
    var pictureStatusDetail: String {
        if isComparingOriginal { return "临时查看原片，点对照按钮恢复\(selectedPictureMode.title)；设置未改变" }
        if selectedPictureMode == .original { return "系统呈现原片，未叠加降噪或缩放处理" }
        if case .nativeOnly(let reason) = videoPermission { return reason }
        if let reason = metrics?.fallbackReason { return reason }
        if pictureIsEnhanced, let metrics {
            return "源 \(metrics.sourceWidth)×\(metrics.sourceHeight) → 输出 \(metrics.outputWidth)×\(metrics.outputHeight) · \(selectedPictureMode.detail)"
        }
        return "已选择\(selectedPictureMode.title)，等待增强画面就绪"
    }
    /// Both quality entry points use this action; a mode selection can never be swallowed by the
    /// separate output switch. Original comparison is deliberately excluded from saved settings.
    func selectEnhancementMode(_ mode: EnhancementMode) {
        guard isComparingOriginal || selectedPictureMode != mode else { return }
        isComparingOriginal = false
        metrics = nil
        enhancementMode = mode
        pipelineProcessesFrames = mode != .original
    }
    func toggleOriginalComparison() {
        guard canCompareOriginal else { return }
        isComparingOriginal.toggle()
        metrics = nil
        updateAdSkipping()
    }
    @Published var keepsOriginalAudioLayout = false {
        didSet {
            preferences.setKeepsOriginalAudioLayout(keepsOriginalAudioLayout)
            preferencesStore.save(preferences)
            experience.updateAudioLayoutPreference(keepsOriginalAudioLayout, item: player.currentItem)
        }
    }
    @Published var automaticAdSkipping = true {
        didSet {
            preferences.setAutomaticAdSkipping(automaticAdSkipping)
            preferencesStore.save(preferences)
            if !automaticAdSkipping { cancelAutomaticAdSeek() }
            updateAdSkipping()
        }
    }
    @Published private(set) var adSkipNotice: AdSkipEvent?
    @Published var title = ""
    @Published var episodeName = ""
    @Published var isPlaying = false
    @Published var isLoading = false
    @Published private(set) var loadingMessage: String?
    @Published private(set) var recoverySuggested = false
    @Published var error: String?
    @Published private(set) var hasPlaybackFailure = false
    @Published var position = 0.0
    @Published var duration = 0.0
    @Published var rate: Float = 1 {
        didSet {
            preferences.setRate(Double(rate))
            let validated = Float(preferences.rate)
            if rate != validated { rate = validated }
            if wantsPlay { player.rate = rate }
            preferencesStore.save(preferences)
        }
    }
    @Published var volume: Float = 0.8 {
        didSet {
            preferences.setVolume(Double(volume))
            let validated = Float(preferences.volume)
            if volume != validated { volume = validated }
            player.volume = volume; preferencesStore.save(preferences)
        }
    }
    @Published var generation = UUID()
    @Published private(set) var enhancementMode: EnhancementMode = .clarity {
        didSet { preferences.setEnhancement(enhancementMode.rawValue); preferencesStore.save(preferences) }
    }
    @Published private(set) var sleepRemainingSeconds: Int?
    @Published var metrics: EnhancementMetrics?
    @Published var adCleanup = AdCleanupSettings() {
        didSet {
            if oldValue.protectedRegions != adCleanup.protectedRegions {
                adSkip.configure(url: url, itemID: itemID, protectedRegions: adCleanup.protectedRegions)
                adSkipNotice = nil
            }
        }
    }
    @Published var subtitleText = ""
    @Published var subtitleNotice: String?
    @Published var subtitleOffset = 0.0
    @Published var audioTracks: [MediaTrack] = []
    @Published var subtitleTracks: [MediaTrack] = []
    @Published var selectedAudio = -1
    @Published var selectedSubtitle = -1
    @Published var externalSubtitleName: String?
    @Published var sourceInfo: HLSInfo?
    var onProgress: ((Double, Double) -> Void)?
    var onFinished: (() -> Void)?
    private var observer: Any?
    private var statusObservation: NSKeyValueObservation?
    private var controlObservation: NSKeyValueObservation?
    private var finishedObserver: NSObjectProtocol?
    private var stalledObserver: NSObjectProtocol?
    private var failedObserver: NSObjectProtocol?
    private var subtitleOutput: AVPlayerItemLegibleOutput?
    private var audioGroup: AVMediaSelectionGroup?
    private var subtitleGroup: AVMediaSelectionGroup?
    private var cues: [SubtitleCue] = []
    @Published private(set) var itemID = UUID()
    var playbackRequested: Bool { wantsPlay }
    private(set) var playbackIntentID = UUID()
    private var url: URL?
    private var desiredResume = 0.0
    private var seekRequestID = UUID()
    private var pendingSeekTarget: Double?
    private var automaticSeekRequestID: UUID?
    @Published private var wantsPlay = false { didSet { playbackIntentID = UUID() } }
    private var lastSave = 0.0
    private var probeTask: Task<Void, Never>?
    private var prepareTask: Task<Void, Never>?
    private var preparedItemID: UUID?
    private var loadingWatchdog: Task<Void, Never>?
    private var waitingID: UUID?
    private var failureResumeTarget: Double?
    /// One automatic recovery per item: `AVPlayerItemFailedToPlayToEndTime` is often a transient
    /// transfer interruption rather than an unusable source.
    private var automaticRecoveryAttempted = false
    private let preferencesStore: PlaybackPreferencesStore
    private var preferences: PlaybackPreferences
    private var sleepState = PlaybackSleepTimer()
    private var sleepTimer: Timer?
    private var adSkipSubscription: AnyCancellable?
    private var cancellables = Set<AnyCancellable>()
    private var ignoredAdSegments: [AdSkipSegment] = []
    private var adSkipInteractions = Set<String>()

    override convenience init() { self.init(preferencesStore: PlaybackPreferencesStore()) }
    init(preferencesStore store: PlaybackPreferencesStore) {
        let saved = store.load()
        preferencesStore = store; preferences = saved
        rate = Float(saved.rate); volume = Float(saved.volume)
        enhancementMode = EnhancementMode(rawValue: saved.enhancement) ?? .clarity
        automaticAdSkipping = saved.automaticAdSkipping
        keepsOriginalAudioLayout = saved.keepsOriginalAudioLayout
        pipelineProcessesFrames = saved.pipelineProcessesFrames
        super.init()
        experience.$videoPermission.sink { [weak self] permission in
            guard let self, self.videoPermission != permission else { return }
            self.videoPermission = permission
        }.store(in: &cancellables)
        experience.$status.map { $0.audioIsAtmos }.removeDuplicates().sink { [weak self] _ in self?.objectWillChange.send() }.store(in: &cancellables)
        adSkipSubscription = adSkip.objectWillChange.sink { [weak self] _ in self?.objectWillChange.send() }
        player.volume = volume
        player.automaticallyWaitsToMinimizeStalling = true
        controlObservation = player.observe(\.timeControlStatus, options: [.new]) { [weak self] player, _ in
            Task { @MainActor in
                self?.refreshPlaybackState()
            }
        }
    }

    func open(url: URL, title: String, episode: String, resume: Double = 0, isAutomaticRecovery: Bool = false) {
        saveProgress()
        isComparingOriginal = false
        // A user-selected item starts a new recovery budget; only the internal replacement made
        // by the first transport retry inherits the spent budget from its original item.
        if !isAutomaticRecovery { automaticRecoveryAttempted = false }
        wantsPlay = false; player.pause(); adSkip.stop()
        cancelPendingSeek()
        probeTask?.cancel(); prepareTask?.cancel()
        clearItemObservers()
        clearWaitingState()
        player.pause()
        self.url = url; self.title = title; episodeName = episode
        itemID = UUID(); generation = UUID(); preparedItemID = nil
        hasPlaybackFailure = false; failureResumeTarget = nil
        let token = itemID
        desiredResume = max(0, resume); wantsPlay = true
        position = 0; duration = 0; error = nil; isPlaying = false; isLoading = true; loadingMessage = "正在准备媒体"
        cues = []; subtitleText = ""; subtitleNotice = nil; externalSubtitleName = nil; subtitleOffset = 0
        audioTracks = []; subtitleTracks = []; audioGroup = nil; subtitleGroup = nil
        selectedAudio = -1; selectedSubtitle = -1; sourceInfo = nil; metrics = nil
        adCleanup = AdCleanupSettings()
        ignoredAdSegments = []; adSkipNotice = nil; adSkipInteractions = []
        adSkip.configure(url: url, itemID: token, protectedRegions: adCleanup.protectedRegions)
        let item = AVPlayerItem(url: url)
        item.preferredForwardBufferDuration = 12
        let output = AVPlayerItemLegibleOutput()
        output.suppressesPlayerRendering = true
        output.setDelegate(self, queue: .main)
        item.add(output); subtitleOutput = output
        player.replaceCurrentItem(with: item)
        experience.begin(item: item, declarations: nil, keepsOriginalAudioLayout: keepsOriginalAudioLayout, spatializationEnabled: true)
        if let observer { player.removeTimeObserver(observer) }
        observer = player.addPeriodicTimeObserver(forInterval: CMTime(seconds: 0.2, preferredTimescale: 600), queue: .main) { [weak self] _ in
            Task { @MainActor in
                guard let self, self.itemID == token else { return }
                self.tick()
            }
        }
        statusObservation = item.observe(\.status, options: [.initial, .new]) { [weak self, weak item] _, _ in
            Task { @MainActor in
                guard let self, let item, self.itemID == token else { return }
                switch item.status {
                case .readyToPlay:
                    self.prepareReady(item, token: token)
                case .failed:
                    self.failCurrentItem(self.describe(item.error))
                default: break
                }
            }
        }
        finishedObserver = NotificationCenter.default.addObserver(forName: .AVPlayerItemDidPlayToEndTime, object: item, queue: .main) { [weak self] _ in
            // Capture the seek generation at event delivery before the asynchronous actor hop.
            let deliveredSeek = MainActor.assumeIsolated { self?.seekRequestID }
            Task { @MainActor in
                guard let self, self.itemID == token, self.player.currentItem === item else { return }
                let actual = self.player.currentTime().seconds
                let itemDuration = item.duration.seconds
                let terminalDuration = itemDuration.isFinite && itemDuration > 0 ? itemDuration : self.duration
                guard PlaybackStabilityPolicy.acceptsEnd(actualTime: actual, duration: terminalDuration, seeking: self.pendingSeekTarget != nil, seekMatches: deliveredSeek == self.seekRequestID) else {
                    self.refreshPlaybackState(); return
                }
                let shouldAdvance = self.wantsPlay
                self.tick(); self.saveProgress(); self.wantsPlay = false; self.player.pause()
                self.refreshPlaybackState()
                if self.sleepState.consumeExpiration() { self.cancelSleepTimer(); return }
                if shouldAdvance { self.onFinished?() }
            }
        }
        failedObserver = NotificationCenter.default.addObserver(forName: .AVPlayerItemFailedToPlayToEndTime, object: item, queue: .main) { [weak self] _ in
            Task { @MainActor in
                guard let self, self.itemID == token, self.player.currentItem === item else { return }
                // A dropped connection mid-transfer is worth one silent retry at the same position;
                // the source, the line and the user's play intent are all unchanged.
                guard !self.automaticRecoveryAttempted else {
                    self.failCurrentItem(self.describe(item.error))
                    return
                }
                self.automaticRecoveryAttempted = true
                guard let url = self.url else { self.failCurrentItem(self.describe(item.error)); return }
                // Before an item becomes ready, position is still zero even when the user asked
                // to resume later. Preserve that pending target across an early transport retry.
                let resume = self.pendingSeekTarget ?? (self.desiredResume > 0 ? self.desiredResume : (self.position.isFinite ? self.position : 0))
                let rewind = item.status == .readyToPlay && self.pendingSeekTarget == nil ? 0.5 : 0
                self.loadingMessage = "传输中断，正在自动续播…"
                self.isLoading = true
                self.open(url: url, title: self.title, episode: self.episodeName,
                          resume: max(0, resume - rewind), isAutomaticRecovery: true)
            }
        }
        stalledObserver = NotificationCenter.default.addObserver(forName: .AVPlayerItemPlaybackStalled, object: item, queue: .main) { [weak self] _ in
            Task { @MainActor in
                guard let self, self.itemID == token else { return }
                self.refreshPlaybackState()
            }
        }
        if !url.isFileURL {
            probeTask = Task { [weak self] in
                do {
                    let result = try await HLSProbe().inspect(url: url)
                    guard !Task.isCancelled, self?.itemID == token else { return }
                    self?.sourceInfo = result
                    self?.experience.updateDeclarations(result.declarations)
                } catch { /* Playback owns media errors; non-HLS is a valid input. */ }
            }
        }
        player.playImmediately(atRate: rate)
        refreshPlaybackState()
    }

    private func prepareReady(_ item: AVPlayerItem, token: UUID) {
        guard itemID == token, player.currentItem === item, preparedItemID != token else { return }
        preparedItemID = token
        let value = item.duration.seconds
        if value.isFinite && value > 0 { duration = value }
        if desiredResume > 0 || pendingSeekTarget != nil {
            let target = pendingSeekTarget ?? desiredResume; desiredResume = 0
            seek(to: duration > 0 ? min(target, max(0, duration - 1)) : target)
        }
        if wantsPlay { player.playImmediately(atRate: rate) }
        refreshPlaybackState()
        prepareTask = Task { [weak self, weak item] in
            guard let self, let item else { return }
            do {
                let audio = try await item.asset.loadMediaSelectionGroup(for: .audible)
                guard !Task.isCancelled, self.itemID == token, self.player.currentItem === item else { return }
                let subtitles = try await item.asset.loadMediaSelectionGroup(for: .legible)
                guard !Task.isCancelled, self.itemID == token, self.player.currentItem === item else { return }
                self.audioGroup = audio; self.subtitleGroup = subtitles
                // The inspector reuses this already-loaded group instead of asking the source again.
                let selectedAudio = audio.flatMap { item.currentMediaSelection.selectedMediaOption(in: $0) }
                self.experience.attach(item: item, selected: selectedAudio)
                self.audioTracks = (audio?.options ?? []).enumerated().map { MediaTrack(id: $0.offset, name: $0.element.displayName) }
                self.subtitleTracks = (subtitles?.options ?? []).enumerated().map { MediaTrack(id: $0.offset, name: $0.element.displayName) }
                if let audio, let selected = item.currentMediaSelection.selectedMediaOption(in: audio) {
                    self.selectedAudio = audio.options.firstIndex(of: selected) ?? -1
                }
                if let subtitles {
                    if !self.cues.isEmpty {
                        item.select(nil, in: subtitles); self.selectedSubtitle = -1
                    } else if let selected = item.currentMediaSelection.selectedMediaOption(in: subtitles) {
                        self.selectedSubtitle = subtitles.options.firstIndex(of: selected) ?? -1
                    }
                }
            } catch { /* Some sources expose no track groups. */ }
        }
    }

    func togglePlayback() {
        // Pressing Play on a failed item is an explicit user retry, not a false play intent.
        if hasPlaybackFailure || error != nil { retry(); return }
        if wantsPlay {
            wantsPlay = false; player.pause(); cancelAutomaticAdSeek(); saveProgress()
        } else {
            wantsPlay = true
            if duration > 0 && position >= duration - 0.5 { seek(to: 0) }
            player.playImmediately(atRate: rate)
        }
        refreshPlaybackState()
    }
    func pause() { wantsPlay = false; player.pause(); cancelAutomaticAdSeek(); saveProgress(); refreshPlaybackState() }
    func resumeAfterEditing(ifUnchanged intent: UUID) {
        guard playbackIntentID == intent, !wantsPlay, !hasPlaybackFailure, error == nil else { return }
        // KVO isPlaying can still describe the frame before pause(). This is
        // an explicit resume, not a toggle based on a delayed observation.
        wantsPlay = true
        if duration > 0 && position >= duration - 0.5 { seek(to: 0) }
        player.playImmediately(atRate: rate)
        refreshPlaybackState()
    }
    func retry() {
        guard let url else { return }
        let savedCues = cues, savedName = externalSubtitleName, savedOffset = subtitleOffset
        let savedCleanup = adCleanup
        // A failed item clears wantsPlay; retrying that failure still requests play.
        // Normal paused retries retain their pause, including during preparation.
        let shouldPlay = wantsPlay || hasPlaybackFailure || error != nil
        let resumePosition = failureResumeTarget ?? (desiredResume > 0 ? desiredResume : position)
        open(url: url, title: title, episode: episodeName, resume: resumePosition)
        cues = savedCues; externalSubtitleName = savedName; subtitleOffset = savedOffset
        adCleanup = savedCleanup
        wantsPlay = shouldPlay
        if !shouldPlay { player.pause() }
        refreshPlaybackState()
    }
    func seek(to value: Double) {
        guard value.isFinite else { return }
        // Scrubbing into an identified segment is an explicit request to watch it.
        for segment in adSkip.segments where value >= segment.start && value < segment.end { ignoreAdSegment(segment) }
        adSkipNotice = nil
        performSeek(to: value)
    }
    private func performSeek(to value: Double, automaticEvent: AdSkipEvent? = nil) {
        guard value.isFinite, let item = player.currentItem else { return }
        let safe = max(0, duration > 0 ? min(value, duration) : value)
        let request = UUID(), token = itemID
        seekRequestID = request; pendingSeekTarget = safe
        automaticSeekRequestID = automaticEvent == nil ? nil : request
        generation = UUID(); subtitleText = ""; position = safe
        // A user request made during preparation replaces the original resume
        // position; prepareReady will issue the seek when the item can accept it.
        guard item.status == .readyToPlay else { desiredResume = safe; refreshPlaybackState(); return }
        desiredResume = 0
        player.seek(to: CMTime(seconds: safe, preferredTimescale: 600), toleranceBefore: .zero, toleranceAfter: CMTime(seconds: 0.1, preferredTimescale: 600)) { [weak self] finished in
            Task { @MainActor in
                guard let self, self.itemID == token, self.seekRequestID == request else { return }
                self.automaticSeekRequestID = nil
                self.pendingSeekTarget = nil
                // A canceled latest request reconciles with the actual player;
                // it must not commit its requested target or flush a newer frame.
                guard finished else { self.tick(); self.refreshPlaybackState(); return }
                if let automaticEvent { self.adSkipNotice = automaticEvent }
                self.generation = UUID()
                if self.wantsPlay, !self.hasPlaybackFailure, self.error == nil, self.player.timeControlStatus != .playing {
                    self.player.playImmediately(atRate: self.rate)
                }
                self.tick()
                self.saveProgress()
                self.refreshPlaybackState()
            }
        }
        refreshPlaybackState()
    }

    /// Feeds one already decoded playback frame into local ad recognition. The enhancement surface
    /// calls this; when it returns false the scanner keeps using its own bounded decoder.
    func harvestScanFrame(_ image: CGImage, time: Double) -> Bool {
        guard automaticAdSkipping, wantsPlay, isPlaying, !isLoading, error == nil, pendingSeekTarget == nil, adSkipInteractions.isEmpty else { return false }
        return adSkip.harvest(image: image, time: time)
    }
    func setAdSkipInteraction(_ reason: String, active: Bool) {
        let changed = active ? adSkipInteractions.insert(reason).inserted : adSkipInteractions.remove(reason) != nil
        if changed { updateAdSkipping() }
    }
    func undoAdSkip() {
        guard let event = adSkipNotice else { return }
        ignoreAdSegment(event.segment)
        pause()
        adSkipNotice = nil
        performSeek(to: event.returnPosition)
    }
    func dismissAdSkipNotice() { adSkipNotice = nil }
    private func ignoreAdSegment(_ segment: AdSkipSegment) {
        if !ignoredAdSegments.contains(segment) { ignoredAdSegments.append(segment) }
        if ignoredAdSegments.count > 128 { ignoredAdSegments.removeFirst(ignoredAdSegments.count - 128) }
    }
    private func updateAdSkipping() {
        // The scanner opens its own decoder, so it must not compete with a source that has not
        // produced a decodable first frame yet. Several parallel connections to one slow HLS
        // source can break the playback transport itself.
        let ready = player.currentItem?.status == .readyToPlay && position > 0.05
        let available = automaticAdSkipping && wantsPlay && isPlaying && ready && !isLoading && !hasPlaybackFailure && error == nil && pendingSeekTarget == nil && adSkipInteractions.isEmpty
        let sharesPlaybackFrames = surfaceMode != .original && videoPermission == .inspectSDRFrames && metrics?.fallbackReason == nil
        adSkip.update(position: position, duration: duration, shouldScan: available, prefersSharedFrames: sharesPlaybackFrames)
    }
    private func automaticallySkipAdIfNeeded() -> Bool {
        guard automaticAdSkipping, duration.isFinite, duration > 0,
              let segment = AdSegmentPolicy.target(at: position, in: adSkip.segments, ignored: ignoredAdSegments,
                  isPlaying: wantsPlay && isPlaying,
                  isBusy: isLoading || hasPlaybackFailure || error != nil || pendingSeekTarget != nil || !adSkipInteractions.isEmpty),
              segment.end < duration - 0.5 else { return false }
        let event = AdSkipEvent(segment: segment, returnPosition: position)
        // Consume before the asynchronous seek to avoid loops on seek failure or repeated ticks.
        ignoreAdSegment(segment)
        performSeek(to: min(segment.end, duration), automaticEvent: event)
        return true
    }
    func cancelPendingSeek() {
        seekRequestID = UUID(); pendingSeekTarget = nil; automaticSeekRequestID = nil; desiredResume = 0
        player.currentItem?.cancelPendingSeeks()
        let actual = player.currentTime().seconds
        if actual.isFinite, actual >= 0 { position = actual }
        refreshPlaybackState()
    }
    private func cancelAutomaticAdSeek() {
        guard automaticSeekRequestID == seekRequestID else { return }
        cancelPendingSeek()
    }
    func resumeWhenReady(_ position: Double) {
        if player.currentItem?.status == .readyToPlay { seek(to: position) }
        else { desiredResume = max(0, position) }
    }
    func skip(_ amount: Double) {
        let base = pendingSeekTarget ?? (desiredResume > 0 ? desiredResume : position)
        seek(to: base + amount)
    }
    func setRate(_ rate: Float) { self.rate = rate }
    func toggleMute() { preferences.toggleMute(); volume = Float(preferences.volume) }
    func adjustVolume(_ amount: Float) { volume += amount }
    func scheduleSleepTimer(minutes: Int) {
        guard sleepState.schedule(minutes: minutes) else { return }
        sleepTimer?.invalidate()
        sleepRemainingSeconds = sleepState.remainingSeconds()
        let timer = Timer(timeInterval: 0.5, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.updateSleepTimer() }
        }
        sleepTimer = timer
        RunLoop.main.add(timer, forMode: .common)
    }
    func cancelSleepTimer() {
        sleepTimer?.invalidate(); sleepTimer = nil
        sleepState.cancel(); sleepRemainingSeconds = nil
    }
    private func updateSleepTimer() {
        if sleepState.consumeExpiration() {
            pause(); cancelSleepTimer()
        } else { sleepRemainingSeconds = sleepState.remainingSeconds() }
    }
    func selectAudio(_ index: Int) {
        guard let group = audioGroup, group.options.indices.contains(index) else { return }
        player.currentItem?.select(group.options[index], in: group); selectedAudio = index
    }
    func selectSubtitle(_ index: Int) {
        cues = []; externalSubtitleName = nil; subtitleText = ""; subtitleNotice = nil
        guard let group = subtitleGroup else { selectedSubtitle = -1; return }
        player.currentItem?.select(group.options.indices.contains(index) ? group.options[index] : nil, in: group)
        selectedSubtitle = index
    }
    func loadSubtitles(_ file: URL) {
        do {
            let text = try String(contentsOf: file, encoding: .utf8)
            let parsed = SubtitleParser.parse(text)
            guard !parsed.isEmpty else { subtitleNotice = "没有识别到有效字幕。支持 UTF-8 编码的 SRT、VTT 和 ASS 文本字幕，当前影片会继续播放。"; return }
            if let group = subtitleGroup { player.currentItem?.select(nil, in: group) }
            selectedSubtitle = -1; cues = parsed; externalSubtitleName = file.lastPathComponent; subtitleNotice = nil
        } catch { subtitleNotice = "无法读取字幕，请使用 UTF-8 编码的字幕文件，当前影片会继续播放。" }
    }
    nonisolated func legibleOutput(_ output: AVPlayerItemLegibleOutput, didOutputAttributedStrings strings: [NSAttributedString], nativeSampleBuffers: [Any], forItemTime itemTime: CMTime) {
        Task { @MainActor [weak self] in
            guard let self, output === self.subtitleOutput, self.cues.isEmpty else { return }
            self.subtitleText = strings.map(\.string).joined(separator: "\n")
        }
    }
    func saveProgress() {
        if position.isFinite, position >= 0, duration.isFinite { onProgress?(position, duration) }
    }
    private func tick() {
        // Periodic callbacks are delivered through an asynchronous MainActor
        // hop. Their captured times can predate the latest seek completion.
        // Sample the live player here, and keep a requested target while seeking.
        guard pendingSeekTarget == nil else { return }
        let actual = player.currentTime().seconds
        guard actual.isFinite else { return }
        position = actual
        if let current = player.currentItem?.duration.seconds, current.isFinite, current > 0 { duration = current }
        if !cues.isEmpty { subtitleText = SubtitleParser.text(at: position - subtitleOffset, in: cues) }
        updateAdSkipping()
        if automaticallySkipAdIfNeeded() { return }
        let now = Date.timeIntervalSinceReferenceDate
        if now - lastSave >= 5 { saveProgress(); lastSave = now }
    }
    private func failCurrentItem(_ message: String) {
        // Cancel the operation, but retain its intended position for explicit retry.
        let retryTarget = failureResumeTarget ?? pendingSeekTarget ?? (desiredResume > 0 ? desiredResume : position)
        cancelPendingSeek()
        failureResumeTarget = retryTarget.isFinite ? max(0, retryTarget) : nil
        hasPlaybackFailure = true
        wantsPlay = false; player.pause(); error = message
        refreshPlaybackState(); saveProgress()
    }
    private func refreshPlaybackState() {
        let preparation: PlaybackPreparationState
        if let item = player.currentItem {
            switch item.status { case .readyToPlay: preparation = .ready; case .failed: preparation = .failed; default: preparation = .preparing }
        } else { preparation = .absent }
        let transport: PlaybackTransportState
        switch player.timeControlStatus { case .playing: transport = .playing; case .waitingToPlayAtSpecifiedRate: transport = .waiting; default: transport = .paused }
        let loading = PlaybackStabilityPolicy.loadingState(item: preparation, transport: transport, playbackRequested: wantsPlay, seeking: pendingSeekTarget != nil, hasError: hasPlaybackFailure || error != nil)
        isPlaying = !hasPlaybackFailure && error == nil && transport == .playing
        isLoading = loading.isLoading; loadingMessage = loading.message
        updateAdSkipping()
        if !loading.isLoading { clearWaitingState(); return }
        guard waitingID == nil else { return }
        let wait = UUID(), token = itemID
        waitingID = wait; recoverySuggested = false
        loadingWatchdog = Task { @MainActor [weak self] in
            do { try await Task.sleep(nanoseconds: 15_000_000_000) } catch { return }
            guard let self, self.itemID == token, self.waitingID == wait else { return }
            self.refreshPlaybackState()
            self.recoverySuggested = PlaybackStabilityPolicy.shouldSuggestRecovery(isLoading: self.isLoading, elapsed: 15)
        }
    }
    private func clearWaitingState() {
        loadingWatchdog?.cancel(); loadingWatchdog = nil; waitingID = nil; recoverySuggested = false
    }
    private func clearItemObservers() {
        statusObservation = nil
        for value in [finishedObserver, stalledObserver, failedObserver].compactMap({$0}) { NotificationCenter.default.removeObserver(value) }
        finishedObserver = nil; stalledObserver = nil; failedObserver = nil
    }
    /// Describes the failure from the actual error, and names transport failures as transport
    /// failures instead of blaming the container or codec.
    private func describe(_ error: Error?) -> String {
        let value = error as NSError?
        let code = value?.code ?? 0
        let reason: String
        switch code {
        case -1008: reason = "来源暂时无法提供媒体数据（网络或来源侧限制）"
        case -1009: reason = "网络连接已断开"
        case -11800: reason = "系统无法完成本次媒体加载"
        case -11828: reason = "系统不支持该媒体的封装或编码"
        case -12889: reason = "系统媒体服务被重置，通常是播放期间音频或显示设备发生变化"
        case -12881, -12884: reason = "该媒体需要系统不支持的编码或加密"
        default: reason = "系统不支持的封装、编码或来源限制都可能导致失败"
        }
        let domain = value?.domain == NSURLErrorDomain ? "网络" : "媒体"
        return "当前资源无法播放（\(domain)错误 \(code)）：\(reason)。可以重试当前集，或更换线路。"
    }
}
