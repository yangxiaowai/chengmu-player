import AVFoundation
import AppKit
import Combine
import CinemaCore

struct MediaTrack: Identifiable {
    let id: Int
    let name: String
}

@MainActor
final class PlaybackController: NSObject, ObservableObject, AVPlayerItemLegibleOutputPushDelegate {
    let player = AVPlayer()
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
    @Published var enhancementMode: EnhancementMode = .upscale4K {
        didSet { preferences.setEnhancement(enhancementMode.rawValue); preferencesStore.save(preferences) }
    }
    @Published private(set) var sleepRemainingSeconds: Int?
    @Published var metrics: EnhancementMetrics?
    @Published var adCleanup = AdCleanupSettings()
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
    @Published private var wantsPlay = false { didSet { playbackIntentID = UUID() } }
    private var lastSave = 0.0
    private var probeTask: Task<Void, Never>?
    private var prepareTask: Task<Void, Never>?
    private var preparedItemID: UUID?
    private var loadingWatchdog: Task<Void, Never>?
    private var waitingID: UUID?
    private var failureResumeTarget: Double?
    private let preferencesStore: PlaybackPreferencesStore
    private var preferences: PlaybackPreferences
    private var sleepState = PlaybackSleepTimer()
    private var sleepTimer: Timer?

    override init() {
        let store = PlaybackPreferencesStore()
        let saved = store.load()
        preferencesStore = store; preferences = saved
        rate = Float(saved.rate); volume = Float(saved.volume)
        enhancementMode = EnhancementMode(rawValue: saved.enhancement) ?? .upscale4K
        super.init()
        player.volume = volume
        player.automaticallyWaitsToMinimizeStalling = true
        controlObservation = player.observe(\.timeControlStatus, options: [.new]) { [weak self] player, _ in
            Task { @MainActor in
                self?.refreshPlaybackState()
            }
        }
    }

    func open(url: URL, title: String, episode: String, resume: Double = 0) {
        saveProgress()
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
        let item = AVPlayerItem(url: url)
        item.preferredForwardBufferDuration = 12
        let output = AVPlayerItemLegibleOutput()
        output.suppressesPlayerRendering = true
        output.setDelegate(self, queue: .main)
        item.add(output); subtitleOutput = output
        player.replaceCurrentItem(with: item)
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
                self.failCurrentItem("媒体传输中断。可以重试当前集，或在右侧选择其他线路。")
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
            wantsPlay = false; player.pause(); saveProgress()
        } else {
            wantsPlay = true
            if duration > 0 && position >= duration - 0.5 { seek(to: 0) }
            player.playImmediately(atRate: rate)
        }
        refreshPlaybackState()
    }
    func pause() { wantsPlay = false; player.pause(); saveProgress(); refreshPlaybackState() }
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
        guard value.isFinite, let item = player.currentItem else { return }
        let safe = max(0, duration > 0 ? min(value, duration) : value)
        let request = UUID(), token = itemID
        seekRequestID = request; pendingSeekTarget = safe
        generation = UUID(); subtitleText = ""; position = safe
        // A user request made during preparation replaces the original resume
        // position; prepareReady will issue the seek when the item can accept it.
        guard item.status == .readyToPlay else { desiredResume = safe; refreshPlaybackState(); return }
        desiredResume = 0
        player.seek(to: CMTime(seconds: safe, preferredTimescale: 600), toleranceBefore: .zero, toleranceAfter: CMTime(seconds: 0.1, preferredTimescale: 600)) { [weak self] finished in
            Task { @MainActor in
                guard let self, self.itemID == token, self.seekRequestID == request else { return }
                self.pendingSeekTarget = nil
                // A canceled latest request reconciles with the actual player;
                // it must not commit its requested target or flush a newer frame.
                guard finished else { self.tick(); self.refreshPlaybackState(); return }
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
    func cancelPendingSeek() {
        seekRequestID = UUID(); pendingSeekTarget = nil; desiredResume = 0
        player.currentItem?.cancelPendingSeeks()
        let actual = player.currentTime().seconds
        if actual.isFinite, actual >= 0 { position = actual }
        refreshPlaybackState()
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
    private func describe(_ error: Error?) -> String {
        let code = (error as NSError?)?.code ?? 0
        return "当前资源无法播放（错误 \(code)）。请重试或更换线路；系统不支持的封装/编码也可能导致失败。"
    }
}
