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
    @Published var error: String?
    @Published var position = 0.0
    @Published var duration = 0.0
    @Published var rate: Float = 1
    @Published var volume: Float = 0.8 { didSet { player.volume = volume } }
    @Published var generation = UUID()
    @Published var enhancementMode: EnhancementMode = .upscale4K
    @Published var metrics: EnhancementMetrics?
    @Published var subtitleText = ""
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
    private var itemID = UUID()
    private var url: URL?
    private var desiredResume = 0.0
    private var wantsPlay = false
    private var lastSave = 0.0
    private var probeTask: Task<Void, Never>?
    private var prepareTask: Task<Void, Never>?

    override init() {
        super.init()
        player.volume = volume
        player.automaticallyWaitsToMinimizeStalling = true
        observer = player.addPeriodicTimeObserver(forInterval: CMTime(seconds: 0.2, preferredTimescale: 600), queue: .main) { [weak self] time in
            Task { @MainActor in self?.tick(time) }
        }
        controlObservation = player.observe(\.timeControlStatus, options: [.new]) { [weak self] player, _ in
            Task { @MainActor in
                self?.isPlaying = player.timeControlStatus == .playing
                self?.isLoading = player.timeControlStatus == .waitingToPlayAtSpecifiedRate
            }
        }
    }

    func open(url: URL, title: String, episode: String, resume: Double = 0) {
        saveProgress()
        probeTask?.cancel(); prepareTask?.cancel()
        clearItemObservers()
        player.pause()
        self.url = url; self.title = title; episodeName = episode
        itemID = UUID(); generation = UUID()
        let token = itemID
        desiredResume = max(0, resume); wantsPlay = true
        position = 0; duration = 0; error = nil; isLoading = true
        cues = []; subtitleText = ""; externalSubtitleName = nil; subtitleOffset = 0
        audioTracks = []; subtitleTracks = []; audioGroup = nil; subtitleGroup = nil
        selectedAudio = -1; selectedSubtitle = -1; sourceInfo = nil; metrics = nil
        let item = AVPlayerItem(url: url)
        item.preferredForwardBufferDuration = 12
        let output = AVPlayerItemLegibleOutput()
        output.suppressesPlayerRendering = true
        output.setDelegate(self, queue: .main)
        item.add(output); subtitleOutput = output
        player.replaceCurrentItem(with: item)
        statusObservation = item.observe(\.status, options: [.initial, .new]) { [weak self, weak item] _, _ in
            Task { @MainActor in
                guard let self, let item, self.itemID == token else { return }
                switch item.status {
                case .readyToPlay:
                    self.prepareReady(item, token: token)
                case .failed:
                    self.isLoading = false; self.wantsPlay = false
                    self.error = self.describe(item.error)
                default: break
                }
            }
        }
        finishedObserver = NotificationCenter.default.addObserver(forName: .AVPlayerItemDidPlayToEndTime, object: item, queue: .main) { [weak self] _ in
            Task { @MainActor in
                guard let self, self.itemID == token else { return }
                self.saveProgress(); self.wantsPlay = false; self.isPlaying = false; self.onFinished?()
            }
        }
        failedObserver = NotificationCenter.default.addObserver(forName: .AVPlayerItemFailedToPlayToEndTime, object: item, queue: .main) { [weak self] _ in
            Task { @MainActor in
                guard let self, self.itemID == token else { return }
                self.error = "媒体传输中断。可以重试当前集，或在右侧选择其他线路。"; self.isLoading = false
            }
        }
        stalledObserver = NotificationCenter.default.addObserver(forName: .AVPlayerItemPlaybackStalled, object: item, queue: .main) { [weak self] _ in
            Task { @MainActor in if self?.itemID == token { self?.isLoading = true } }
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
    }

    private func prepareReady(_ item: AVPlayerItem, token: UUID) {
        isLoading = false
        let value = item.duration.seconds
        if value.isFinite && value > 0 { duration = value }
        if desiredResume > 0 {
            let target = desiredResume; desiredResume = 0
            seek(to: duration > 0 ? min(target, max(0, duration - 1)) : target)
        }
        if wantsPlay { player.playImmediately(atRate: rate) }
        prepareTask = Task { [weak self, weak item] in
            guard let self, let item else { return }
            do {
                let audio = try await item.asset.loadMediaSelectionGroup(for: .audible)
                let subtitles = try await item.asset.loadMediaSelectionGroup(for: .legible)
                guard !Task.isCancelled, self.itemID == token else { return }
                self.audioGroup = audio; self.subtitleGroup = subtitles
                self.audioTracks = (audio?.options ?? []).enumerated().map { MediaTrack(id: $0.offset, name: $0.element.displayName) }
                self.subtitleTracks = (subtitles?.options ?? []).enumerated().map { MediaTrack(id: $0.offset, name: $0.element.displayName) }
                if let audio, let selected = item.currentMediaSelection.selectedMediaOption(in: audio) {
                    self.selectedAudio = audio.options.firstIndex(of: selected) ?? -1
                }
                if let subtitles, let selected = item.currentMediaSelection.selectedMediaOption(in: subtitles) {
                    self.selectedSubtitle = subtitles.options.firstIndex(of: selected) ?? -1
                }
            } catch { /* Some sources expose no track groups. */ }
        }
    }

    func togglePlayback() {
        if isPlaying || wantsPlay {
            wantsPlay = false; player.pause(); saveProgress()
        } else {
            wantsPlay = true
            if duration > 0 && position >= duration - 0.5 { seek(to: 0) }
            player.playImmediately(atRate: rate)
        }
    }
    func pause() { wantsPlay = false; player.pause(); saveProgress() }
    func retry() {
        guard let url else { return }
        open(url: url, title: title, episode: episodeName, resume: position)
    }
    func seek(to value: Double) {
        guard value.isFinite, player.currentItem != nil else { return }
        let safe = max(0, duration > 0 ? min(value, duration) : value)
        generation = UUID(); subtitleText = ""; position = safe
        let token = itemID
        player.seek(to: CMTime(seconds: safe, preferredTimescale: 600), toleranceBefore: .zero, toleranceAfter: CMTime(seconds: 0.1, preferredTimescale: 600)) { [weak self] _ in
            Task { @MainActor in
                guard let self, self.itemID == token else { return }
                self.generation = UUID()
                self.saveProgress()
            }
        }
    }
    func resumeWhenReady(_ position: Double) {
        if player.currentItem?.status == .readyToPlay { seek(to: position) }
        else { desiredResume = max(0, position) }
    }
    func skip(_ amount: Double) { seek(to: position + amount) }
    func setRate(_ rate: Float) { self.rate = rate; if wantsPlay { player.rate = rate } }
    func selectAudio(_ index: Int) {
        guard let group = audioGroup, group.options.indices.contains(index) else { return }
        player.currentItem?.select(group.options[index], in: group); selectedAudio = index
    }
    func selectSubtitle(_ index: Int) {
        cues = []; externalSubtitleName = nil; subtitleText = ""
        guard let group = subtitleGroup else { selectedSubtitle = -1; return }
        player.currentItem?.select(group.options.indices.contains(index) ? group.options[index] : nil, in: group)
        selectedSubtitle = index
    }
    func loadSubtitles(_ file: URL) {
        do {
            let text = try String(contentsOf: file, encoding: .utf8)
            let parsed = SubtitleParser.parse(text)
            guard !parsed.isEmpty else { error = "没有识别到有效字幕。支持UTF-8编码的SRT、VTT和ASS文本字幕。"; return }
            if let group = subtitleGroup { player.currentItem?.select(nil, in: group) }
            selectedSubtitle = -1; cues = parsed; externalSubtitleName = file.lastPathComponent
        } catch { self.error = "无法读取字幕，请使用UTF-8编码的字幕文件。" }
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
    private func tick(_ time: CMTime) {
        guard time.seconds.isFinite else { return }
        position = time.seconds
        if let current = player.currentItem?.duration.seconds, current.isFinite, current > 0 { duration = current }
        if !cues.isEmpty { subtitleText = SubtitleParser.text(at: position - subtitleOffset, in: cues) }
        let now = Date.timeIntervalSinceReferenceDate
        if now - lastSave >= 5 { saveProgress(); lastSave = now }
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
