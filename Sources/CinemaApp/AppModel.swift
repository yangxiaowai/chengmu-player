import SwiftUI
import AppKit
import UniformTypeIdentifiers
import CinemaCore

enum AppSection: String, CaseIterable, Identifiable {
    case discover = "探索", history = "继续观看", quality = "画质工作室", sources = "媒体来源"
    var id: String { rawValue }
    var icon: String {
        switch self { case .discover: return "square.grid.2x2"; case .history: return "clock.arrow.circlepath"; case .quality: return "sparkles.tv"; case .sources: return "externaldrive.connected.to.line.below" }
    }
}

@MainActor
final class AppModel: ObservableObject {
    @Published var section: AppSection = .discover
    @Published var query = ""
    @Published var results: [MediaTitle] = []
    @Published var searching = false
    @Published var searchLabel = "为你找到的剧集"
    @Published var failures: [String] = []
    @Published var message: String?
    @Published var detail: MediaDetail?
    @Published var detailLoading = false
    @Published var selectedLineID = ""
    @Published var currentEpisodeID = ""
    @Published var showPlayer = false
    @Published var history: [WatchRecord] = []
    @Published var providers: [SourceProvider] = SourceProvider.defaults
    @Published var autoNext = true
    @Published var alternativeSources: [MediaTitle] = []
    @Published var alternativesLoading = false
    @Published var alternativeNotice: String?
    private var alternativeTask: Task<Void, Never>?
    private var alternativeID = UUID()
    let playback = PlaybackController()
    let store: LibraryStore
    let service = SourceService()
    private var searchTask: Task<Void, Never>?
    private var detailTask: Task<Void, Never>?
    private var searchID = UUID()
    private var detailID = UUID()
    private var currentRecord: WatchRecord?
    private var historyReadable = true

    init() {
        store = CommandLine.arguments.contains("--validate")
            ? LibraryStore(directory: FileManager.default.temporaryDirectory.appendingPathComponent("YingChuan-QA-\(ProcessInfo.processInfo.processIdentifier)"))
            : LibraryStore()
        do { history = try store.load().sorted { $0.updatedAt > $1.updatedAt } }
        catch { historyReadable = false; message = "历史记录文件无法读取，已保留原文件。可在继续观看页明确清除后重新记录。" }
        if let data = UserDefaults.standard.data(forKey: "sourceProviders"), let saved = try? JSONDecoder().decode([SourceProvider].self, from: data), !saved.isEmpty { providers = saved }
        playback.onProgress = { [weak self] position, duration in self?.saveProgress(position, duration: duration) }
        playback.onFinished = { [weak self] in if self?.autoNext == true { self?.nextEpisode() } }
    }
    var selectedLine: PlaybackLine? { detail?.lines.first { $0.id == selectedLineID } ?? detail?.lines.first }
    var enabledProviderCount: Int { providers.filter(\.enabled).count }

    func discover() {
        section = .discover; query = ""; searchLabel = "你的观影起点"
        runSearch(["怪奇物语", "绝命毒师", "火线第"])
    }
    func search() {
        let text = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { discover(); return }
        section = .discover; searchLabel = "“\(text)” 的搜索结果"
        // The bare title fills the first CMS page with unrelated films. The exact series
        // shortcut uses one verified season-prefix query, without adding search requests.
        runSearch([text == "火线" ? "火线第" : text])
    }
    private func runSearch(_ terms: [String]) {
        cancelAlternativeSources()
        searchTask?.cancel(); searchID = UUID()
        let token = searchID, sources = providers
        searching = true; failures = []; results = []
        searchTask = Task {
            var titles: [MediaTitle] = [], errors: [String] = []
            for term in terms {
                guard !Task.isCancelled else { return }
                let result = await service.search(query: term, providers: sources)
                guard !Task.isCancelled, token == searchID else { return }
                titles.append(contentsOf: result.titles); errors.append(contentsOf: result.failures)
                var seen = Set<String>()
                results = titles.filter { seen.insert($0.providerID + ":" + $0.id).inserted }
            }
            failures = Array(Set(errors)).sorted(); searching = false
        }
    }
    func select(_ title: MediaTitle) {
        cancelAlternativeSources()
        detailTask?.cancel(); detailID = UUID()
        let token = detailID
        detailLoading = true; detail = nil
        guard let provider = providers.first(where: {$0.id == title.providerID}) else { detailLoading = false; message = "此来源已移除，请重新搜索。"; return }
        detailTask = Task {
            do {
                let loaded = try await service.detail(title: title, provider: provider)
                guard !Task.isCancelled, detailID == token else { return }
                detail = loaded; selectedLineID = loaded.lines.first?.id ?? ""; detailLoading = false
            } catch {
                guard !Task.isCancelled, detailID == token else { return }
                detailLoading = false; message = "无法取得剧集详情：\(error.localizedDescription)"
            }
        }
    }
    func dismissDetail() { detailTask?.cancel(); detailID = UUID(); detail = nil; detailLoading = false }
    func play(_ episode: Episode) {
        cancelAlternativeSources()
        guard let detail, let line = selectedLine else { return }
        let id = "\(detail.title.providerID):\(detail.title.id):\(line.id):\(episode.id)"
        playback.saveProgress()
        let saved = history.first { $0.id == id && $0.canResume(episode: episode) }
        let resume = (saved?.progress ?? 0) > 0.98 ? 0 : (saved?.position ?? 0)
        currentRecord = WatchRecord(id: id, title: detail.title.title, episode: episode.name, url: episode.url, posterURL: detail.title.posterURL, position: resume, duration: saved?.duration ?? 0, mediaDetail: detail, lineID: line.id, episodeID: episode.id)
        currentEpisodeID = episode.id
        // The prior item must not write into the new record when opening it.
        playback.onProgress = nil
        playback.open(url: episode.url, title: detail.title.title, episode: episode.name, resume: resume)
        playback.onProgress = { [weak self] pos, dur in self?.saveProgress(pos, duration: dur) }
        showPlayer = true
    }
    func resume(_ record: WatchRecord) {
        cancelAlternativeSources()
        playback.saveProgress(); dismissDetail(); currentRecord = record
        if let context = record.playbackContext {
            detail = context.detail; selectedLineID = context.line.id; currentEpisodeID = context.episode.id
        } else {
            selectedLineID = ""; currentEpisodeID = ""
        }
        playback.onProgress = nil
        playback.open(url: record.url, title: record.title, episode: record.episode, resume: record.progress > 0.98 ? 0 : record.position)
        playback.onProgress = { [weak self] pos, dur in self?.saveProgress(pos, duration: dur) }
        showPlayer = true
    }
    func switchLine(_ id: String) {
        guard let detail, let destination = detail.lines.first(where: { $0.id == id }) else { return }
        guard id != selectedLineID else { return }
        // Browsing a different title has no active episode to switch; selecting its line cannot change playback.
        guard showPlayer, let context = currentRecord?.playbackContext,
              context.detail.title.id == detail.title.id,
              context.detail.title.providerID == detail.title.providerID else { selectedLineID = id; return }
        guard let match = PlaybackLinePolicy.matchEpisode(context.episode, in: destination) else {
            message = "这条线路没有匹配当前集，已保留当前线路与播放。"; return
        }
        let position = playback.position
        selectedLineID = id
        play(match); playback.resumeWhenReady(position)
    }
    func nextEpisode() {
        guard let context = currentRecord?.playbackContext, let detail,
              context.detail.title.id == detail.title.id, context.detail.title.providerID == detail.title.providerID,
              context.line.id == selectedLineID, context.episode.id == currentEpisodeID,
              let episodes = selectedLine?.episodes, let index = episodes.firstIndex(where: {$0.id == currentEpisodeID}), episodes.indices.contains(index + 1) else { return }
        let current = episodes[index], next = episodes[index + 1]
        if let a = current.number, let b = next.number, b != a + 1 { message = "下一集存在缺集，已停止自动续播。"; return }
        play(next)
    }
    func closePlayer() { cancelAlternativeSources(); playback.pause(); showPlayer = false }
    func cancelAlternativeSources() {
        alternativeTask?.cancel(); alternativeTask = nil; alternativeID = UUID()
        alternativesLoading = false; alternativeSources = []; alternativeNotice = nil
    }
    func findAlternativeSources() {
        cancelAlternativeSources()
        guard showPlayer, let record = currentRecord, let context = record.playbackContext else {
            alternativeNotice = "当前媒体没有可核对的季集目录，无法安全匹配其他来源。"; return
        }
        guard SourceMatching.hasExplicitSeason(context.detail.title) else {
            alternativeNotice = "当前目录标题未标明季数，无法确认其他来源属于同一季。请在片库选择明确标注季数的条目。"; return
        }
        let token = alternativeID, recordID = record.id
        let sources = providers.filter(\.enabled)
        alternativesLoading = true
        alternativeTask = Task {
            let found = await service.search(query: context.detail.title.title, providers: sources)
            guard !Task.isCancelled, alternativeID == token, showPlayer, currentRecord?.id == recordID else { return }
            alternativeSources = SourceMatching.candidates(current: context.detail.title, results: found.titles)
            alternativesLoading = false
            let errors = found.failures.joined(separator: "；")
            alternativeNotice = alternativeSources.isEmpty ? "未找到标题、季数匹配的其他版本。" : "候选画质未知，选择后检查当前集与媒体清单。"
            if !errors.isEmpty { alternativeNotice = (alternativeNotice ?? "") + " " + errors }
        }
    }
    func switchAlternativeSource(_ title: MediaTitle) {
        alternativeTask?.cancel(); alternativeID = UUID()
        guard showPlayer, let record = currentRecord, let context = record.playbackContext,
              SourceMatching.sameSeasonTitle(context.detail.title, title),
              let provider = providers.first(where: { $0.id == title.providerID && $0.enabled }) else {
            alternativesLoading = false; alternativeNotice = "季集或来源已变化，已保留当前播放。"; return
        }
        let token = alternativeID, recordID = record.id
        alternativesLoading = true; alternativeNotice = "正在核对同一集…"
        alternativeTask = Task {
            do {
                let loaded = try await service.detail(title: title, provider: provider)
                guard !Task.isCancelled, alternativeID == token, showPlayer, currentRecord?.id == recordID else { return }
                guard SourceMatching.sameSeasonTitle(context.detail.title, loaded.title) else {
                    alternativesLoading = false; alternativeNotice = "返回作品不属于当前季，已保留当前播放。"; return
                }
                var destination: (PlaybackLine, Episode)?
                for line in loaded.lines {
                    guard let episode = SourceMatching.matchEpisode(context.episode, in: line) else { continue }
                    do {
                        _ = try await HLSProbe().inspect(url: episode.url)
                        guard !Task.isCancelled, alternativeID == token, showPlayer, currentRecord?.id == recordID else { return }
                        destination = (line, episode); break
                    } catch {
                        guard !Task.isCancelled, alternativeID == token, currentRecord?.id == recordID else { return }
                    }
                }
                guard let (line, episode) = destination else {
                    alternativesLoading = false; alternativeNotice = "未找到名称、编号一致且清单可达的当前集，已保留当前播放。"; return
                }
                let position = playback.position
                detailTask?.cancel(); detailID = UUID(); detailLoading = false
                detail = loaded; selectedLineID = line.id
                play(episode); playback.resumeWhenReady(position)
                alternativeNotice = "已切换来源并恢复进度。版本时长或剪辑可能不同，进度按新时长限制，请核对画面并按需拖动。画质以实际播放信息为准。"
            } catch {
                guard !Task.isCancelled, alternativeID == token, showPlayer, currentRecord?.id == recordID else { return }
                alternativesLoading = false; alternativeNotice = "来源读取失败，已保留当前播放：\(error.localizedDescription)"
            }
        }
    }
    func importFile() {
        let panel = NSOpenPanel(); panel.allowsMultipleSelection = false; panel.canChooseDirectories = false
        panel.allowedContentTypes = [.movie, .video, .audiovisualContent]
        if panel.runModal() == .OK, let url = panel.url { openURL(url) }
    }
    func openURL(_ url: URL) {
        guard url.isFileURL || ["http", "https"].contains(url.scheme?.lowercased() ?? "") else { message = "请使用本地文件或HTTP(S)媒体链接。"; return }
        let title = url.isFileURL ? url.deletingPathExtension().lastPathComponent : "网络影片"
        let record = WatchRecord(id: url.absoluteString, title: title, episode: url.isFileURL ? "本地影片" : (url.host ?? "网络链接"), url: url, posterURL: nil, position: 0, duration: 0)
        resume(history.first(where: {$0.id == record.id}) ?? record)
    }
    func importSubtitle() {
        let panel = NSOpenPanel(); panel.allowedContentTypes = [UTType(filenameExtension: "srt"), UTType(filenameExtension: "ass"), UTType(filenameExtension: "vtt")].compactMap {$0}
        if panel.runModal() == .OK, let url = panel.url { playback.loadSubtitles(url) }
    }
    func updateProvider(_ id: String, enabled: Bool) {
        cancelAlternativeSources()
        guard let index = providers.firstIndex(where: {$0.id == id}) else { return }
        providers[index].enabled = enabled; saveProviders()
    }
    func addProvider(name: String, endpoint: String) {
        guard let url = URL(string: endpoint.trimmingCharacters(in: .whitespacesAndNewlines)), url.scheme == "https", url.host != nil, url.user == nil, url.password == nil else { message = "来源接口需要有效的HTTPS地址。"; return }
        guard !providers.contains(where: {$0.endpoint == url}) else { message = "这个接口已经添加。"; return }
        providers.append(SourceProvider(id: UUID().uuidString, name: name.isEmpty ? (url.host ?? "自定义来源") : name, endpoint: url, enabled: true)); saveProviders()
    }
    func removeProvider(_ id: String) { cancelAlternativeSources(); providers.removeAll {$0.id == id}; saveProviders() }
    func clearHistory() {
        do { try store.save([]); history = []; historyReadable = true; currentRecord = nil }
        catch { message = "清除历史失败：\(error.localizedDescription)" }
    }
    private func saveProviders() { if let data = try? JSONEncoder().encode(providers) { UserDefaults.standard.set(data, forKey: "sourceProviders") } }
    private func saveProgress(_ position: Double, duration: Double) {
        guard historyReadable, position > 0.5, duration.isFinite, var record = currentRecord else { return }
        record.position = position; record.duration = duration; record.updatedAt = Date(); currentRecord = record
        history.removeAll {$0.id == record.id}; history.insert(record, at: 0)
        if history.count > 200 { history = Array(history.prefix(200)) }
        do { try store.save(history) } catch { message = "观看进度保存失败：\(error.localizedDescription)" }
    }
}
