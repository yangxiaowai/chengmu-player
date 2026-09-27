import SwiftUI
import AppKit
import UniformTypeIdentifiers
import CinemaCore

enum AppSection: String, CaseIterable, Identifiable {
    case discover = "探索", watchlist = "我的待看", history = "继续观看", quality = "画质工作室", sources = "媒体来源"
    var id: String { rawValue }
    var icon: String {
        switch self { case .discover: return "square.grid.2x2"; case .watchlist: return "bookmark"; case .history: return "clock.arrow.circlepath"; case .quality: return "sparkles.tv"; case .sources: return "externaldrive.connected.to.line.below" }
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
    @Published var detailPresented = false
    @Published var detailSources: [MediaTitle] = []
    @Published var selectedLineID = ""
    @Published var currentEpisodeID = ""
    @Published var showPlayer = false
    @Published var history: [WatchRecord] = []
    @Published var providers: [SourceProvider] = SourceProvider.defaults
    @Published var autoNext = true { didSet { if !isDiagnostic { UserDefaults.standard.set(autoNext, forKey: "autoNext") } } }
    @Published var watchlist: [SavedTitle] = []
    @Published var recentSearches: [String] = []
    @Published var filterProviderID = ""
    @Published var filterYear = ""
    @Published var catalogSort = CatalogSort.relevance
    @Published var loadingMore = false
    @Published var moreProviderIDs: Set<String> = []
    @Published var sourceHealth: [String: String] = [:]
    @Published var checkingProviders: Set<String> = []
    @Published var preferredProviderID = "mdzy" {
        didSet { if !isDiagnostic { UserDefaults.standard.set(preferredProviderID, forKey: "preferredProviderID") } }
    }
    let sourceAccess = SourceAccessController()
    @Published var browseProviderID = ""
    @Published var browseCategoryID = ""
    @Published var browseCategories: [SourceCategory] = []
    @Published var browsing = false
    private var searchTerms: [String] = []
    private var loadedPages: [String: Int] = [:]
    private var browsePage = 0
    private var watchlistReadable = true
    private var providerErrors: [String: String] = [:]
    var isDiagnostic: Bool { CommandLine.arguments.contains("--validate") || CommandLine.arguments.contains("--benchmark") }
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
        if let profile = ProcessInfo.processInfo.environment["YINGCHUAN_PROFILE_DIRECTORY"], profile.hasPrefix("/") {
            store = LibraryStore(directory: URL(fileURLWithPath: profile, isDirectory: true))
        } else {
            store = CommandLine.arguments.contains("--validate")
                ? LibraryStore(directory: FileManager.default.temporaryDirectory.appendingPathComponent("YingChuan-QA-\(ProcessInfo.processInfo.processIdentifier)"))
                : LibraryStore()
        }
        do { history = try store.load().sorted { $0.updatedAt > $1.updatedAt } }
        catch { historyReadable = false; message = "历史记录文件无法读取，已保留原文件。可在继续观看页明确清除后重新记录。" }
        do { watchlist = try WatchlistStore(directory: store.directory).load().filter { !$0.sources.isEmpty } }
        catch { watchlistReadable = false; message = "待看文件无法读取，已保留原文件。请在待看页明确重建后再收藏。" }
        let saved = UserDefaults.standard.data(forKey: "sourceProviders").flatMap { try? JSONDecoder().decode([SourceProvider].self, from: $0) }
        let known = UserDefaults.standard.stringArray(forKey: "knownBuiltinProviderIDs") ?? ["dytt", "ffzy"]
        providers = ProviderCatalog.merge(saved: saved, knownBuiltinIDs: known, defaults: SourceProvider.defaults)
        if !isDiagnostic {
            preferredProviderID = UserDefaults.standard.string(forKey: "preferredProviderID") ?? "mdzy"
            if !providers.contains(where: { $0.id == preferredProviderID }) { preferredProviderID = "" }
            recentSearches = UserDefaults.standard.stringArray(forKey: "recentSearches") ?? []
            if UserDefaults.standard.object(forKey: "autoNext") != nil { autoNext = UserDefaults.standard.bool(forKey: "autoNext") }
            UserDefaults.standard.set(SourceProvider.defaults.map(\.id), forKey: "knownBuiltinProviderIDs")
            saveProviders()
        }
        playback.onProgress = { [weak self] position, duration in self?.saveProgress(position, duration: duration) }
        playback.onFinished = { [weak self] in if self?.autoNext == true { self?.nextEpisode() } }
    }
    var selectedLine: PlaybackLine? { detail?.lines.first { $0.id == selectedLineID } ?? detail?.lines.first }
    var enabledProviderCount: Int { providers.filter(\.enabled).count }

    func discover() {
        section = .discover; query = ""; searchLabel = "从好故事开始"
        browsing = false
        runSearch(["星际穿越", "庆余年", "怪奇物语", "绝命毒师", "火线第"])
    }
    func explore(_ term: String) { query = term; search() }
    func search() {
        let text = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { discover(); return }
        section = .discover; browsing = false; searchLabel = "“\(text)” 的搜索结果"
        recentSearches.removeAll { $0 == text }; recentSearches.insert(text, at: 0)
        recentSearches = Array(recentSearches.prefix(8))
        if !isDiagnostic { UserDefaults.standard.set(recentSearches, forKey: "recentSearches") }
        runSearch([text == "火线" ? "火线第" : text])
    }
    private func runSearch(_ terms: [String]) {
        cancelAlternativeSources(); searchTask?.cancel(); searchID = UUID()
        let token = searchID, sources = providers
        searchTerms = terms; loadedPages = [:]; moreProviderIDs = []; loadingMore = false
        filterProviderID = ""; filterYear = ""; searching = true; failures = []; providerErrors = [:]; results = []
        searchTask = Task {
            for term in terms {
                let pages = await service.searchPages(query: term, providers: sources)
                guard !Task.isCancelled, token == searchID else { return }
                acceptPages(pages, paginated: terms.count == 1)
            }
            searching = false
        }
    }
    private func acceptPages(_ pages: [ProviderPageResult], paginated: Bool) {
        for response in pages {
            if let page = response.page {
                results.append(contentsOf: page.titles)
                sourceHealth[response.providerID] = "目录可达 · 本页 \(page.titles.count) 项"
                providerErrors.removeValue(forKey: response.providerID)
                if paginated {
                    loadedPages[response.providerID] = page.page
                    if page.page < page.pageCount { moreProviderIDs.insert(response.providerID) }
                    else { moreProviderIDs.remove(response.providerID) }
                }
            } else if let error = response.error {
                providerErrors[response.providerID] = error
                sourceHealth[response.providerID] = error
                if paginated { moreProviderIDs.insert(response.providerID) }
            }
        }
        var seen = Set<String>()
        results = results.filter { seen.insert($0.providerID + ":" + $0.id).inserted }
        failures = providerErrors.keys.sorted().compactMap { providerErrors[$0] }
    }
    func loadMore() {
        guard !searching, !loadingMore else { return }
        if browsing { browseCatalog(reset: false); return }
        guard let term = searchTerms.first, searchTerms.count == 1, !moreProviderIDs.isEmpty else { return }
        let sources = providers.filter { $0.enabled && moreProviderIDs.contains($0.id) }
        guard !sources.isEmpty else { return }
        loadingMore = true
        let token = searchID, pages = Dictionary(uniqueKeysWithValues: sources.map { ($0.id, (loadedPages[$0.id] ?? 0) + 1) })
        searchTask = Task {
            let result = await service.searchPages(query: term, providers: sources, pages: pages)
            guard !Task.isCancelled, searchID == token else { return }
            acceptPages(result, paginated: true); loadingMore = false
        }
    }
    func openBrowse() {
        browsing = true; section = .discover; query = ""; browseCategoryID = ""; browseCategories = []
        if !providers.contains(where: { $0.id == browseProviderID && $0.enabled }) { browseProviderID = providers.first(where: \.enabled)?.id ?? "" }
        browseCatalog(reset: true)
    }
    func browseCatalog(reset: Bool = true) {
        guard let provider = providers.first(where: { $0.id == browseProviderID && $0.enabled }) else { return }
        if reset { searchTask?.cancel(); searchID = UUID(); results = []; browsePage = 0; loadedPages = [:]; providerErrors = [:]; filterYear = ""; filterProviderID = "" }
        cancelAlternativeSources(); browsing = true; searchTerms = []; moreProviderIDs = []
        searching = reset; loadingMore = !reset; failures = []
        let token = searchID, page = browsePage + 1, category = browseCategoryID.isEmpty ? nil : browseCategoryID
        searchLabel = provider.name + " · 目录浏览"
        searchTask = Task {
            do {
                let result = try await service.browse(provider: provider, categoryID: category, page: page)
                guard !Task.isCancelled, searchID == token else { return }
                if !result.categories.isEmpty { browseCategories = result.categories }
                acceptPages([ProviderPageResult(providerID: provider.id, page: result, error: nil)], paginated: true)
                browsePage = result.page
            } catch {
                guard !Task.isCancelled, searchID == token else { return }
                failures = ["\(provider.name)：\(error.localizedDescription)"]; moreProviderIDs.insert(provider.id)
            }
            searching = false; loadingMore = false
        }
    }
    func selectGroup(_ group: MediaGroup) {
        detailSources = group.sources
        guard let title = ProviderCatalog.preferredTitle(in: group.sources, providers: providers, explicitID: filterProviderID, preferredID: preferredProviderID) else {
            message = "这部作品的来源均已停用或移除，请在媒体来源启用后重试。"; return
        }
        select(title)
    }
    func select(_ title: MediaTitle) {
        cancelAlternativeSources()
        detailTask?.cancel(); detailID = UUID()
        let token = detailID
        if !detailSources.contains(where: { $0.providerID == title.providerID && $0.id == title.id }) { detailSources = [title] }
        detailPresented = true; detailLoading = true; detail = nil
        guard let provider = providers.first(where: {$0.id == title.providerID && $0.enabled}) else { detailLoading = false; detailPresented = false; message = "此来源已停用或移除，请先在媒体来源启用。"; return }
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
    func dismissDetail() { detailTask?.cancel(); detailID = UUID(); detail = nil; detailLoading = false; detailPresented = false; detailSources = [] }
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
        detailPresented = false; showPlayer = true
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
        detailPresented = false; showPlayer = true
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
    func closePlayer() { cancelAlternativeSources(); playback.pause(); playback.cancelSleepTimer(); detailPresented = false; showPlayer = false }
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
        providers[index].enabled = enabled; invalidateCatalogRequests(); saveProviders()
    }
    func addProvider(name: String, endpoint: String) {
        guard let url = URL(string: endpoint.trimmingCharacters(in: .whitespacesAndNewlines)), url.scheme == "https", url.host != nil, url.user == nil, url.password == nil else { message = "来源接口需要有效的HTTPS地址。"; return }
        guard !providers.contains(where: {$0.endpoint == url}) else { message = "这个接口已经添加。"; return }
        providers.append(SourceProvider(id: UUID().uuidString, name: name.isEmpty ? (url.host ?? "自定义来源") : name, endpoint: url, enabled: true)); saveProviders()
    }
    func removeProvider(_ id: String) {
        cancelAlternativeSources(); sourceAccess.remove(id)
        providers.removeAll {$0.id == id}
        if preferredProviderID == id { preferredProviderID = "" }
        invalidateCatalogRequests(); saveProviders()
    }
    func clearHistory() {
        do { try store.save([]); history = []; historyReadable = true; currentRecord = nil }
        catch { message = "清除历史失败：\(error.localizedDescription)" }
    }
    private func saveProviders() { guard !isDiagnostic else { return }; if let data = try? JSONEncoder().encode(providers) { UserDefaults.standard.set(data, forKey: "sourceProviders") } }
    private func invalidateCatalogRequests() {
        searchTask?.cancel(); searchID = UUID(); searching = false; loadingMore = false; moreProviderIDs = []
        let active = Set(providers.filter(\.enabled).map(\.id))
        results.removeAll { !active.contains($0.providerID) }
        if !active.contains(filterProviderID) { filterProviderID = "" }
    }
    var canPlayNext: Bool {
        guard let context = currentRecord?.playbackContext, let detail,
              context.detail.title.id == detail.title.id, context.detail.title.providerID == detail.title.providerID,
              context.line.id == selectedLineID, context.episode.id == currentEpisodeID,
              let episodes = selectedLine?.episodes, let index = episodes.firstIndex(where: { $0.id == currentEpisodeID }), episodes.indices.contains(index + 1) else { return false }
        if let a = episodes[index].number, let b = episodes[index + 1].number { return b == a + 1 }
        return true
    }
    var groups: [MediaGroup] { CatalogGrouping.groups(results) }
    var filteredGroups: [MediaGroup] {
        var values = groups.filter { group in
            (filterProviderID.isEmpty || group.sources.contains { $0.providerID == filterProviderID }) &&
            (filterYear.isEmpty || group.representative.year == filterYear)
        }
        switch catalogSort {
        case .relevance: break
        case .title: values.sort { $0.representative.title.localizedStandardCompare($1.representative.title) == .orderedAscending }
        case .year: values.sort { $0.representative.year > $1.representative.year }
        case .sources: values.sort { $0.sources.count > $1.sources.count }
        }
        return values
    }
    var availableYears: [String] { Array(Set(groups.map { $0.representative.year }.filter { !$0.isEmpty })).sorted(by: >) }
    var canLoadMore: Bool { !moreProviderIDs.isEmpty }
    var canResetWatchlist: Bool { !watchlistReadable }
    var latestHistory: [WatchRecord] {
        var seen = Set<String>()
        return history.filter { record in
            let context = record.mediaDetail?.title
            let key = context.map { CatalogGrouping.normalizedTitle($0.title) + "|" + $0.year } ?? record.id
            return seen.insert(key).inserted
        }
    }
    func isSaved(_ group: MediaGroup) -> Bool { watchlist.contains { $0.matches(group) } }
    func toggleSaved(_ group: MediaGroup) {
        guard watchlistReadable else { message = "原待看文件损坏，已保留，请在待看页明确重建后重试。"; return }
        var updated = watchlist
        if updated.contains(where: {$0.matches(group)}) { updated.removeAll { $0.matches(group) } }
        else { guard updated.count < 1000 else { message = "待看已达1000项，请先移除不需要的条目。"; return }; updated.insert(SavedTitle(group: group), at: 0) }
        saveWatchlist(updated)
    }
    func removeSaved(_ id: String) { saveWatchlist(watchlist.filter { $0.id != id }) }
    func resetWatchlist() {
        do { try WatchlistStore(directory: store.directory).save([]); watchlist = []; watchlistReadable = true }
        catch { message = "重建待看失败：\(error.localizedDescription)" }
    }
    private func saveWatchlist(_ values: [SavedTitle]) {
        do { try WatchlistStore(directory: store.directory).save(values); watchlist = values }
        catch { message = "保存待看失败：\(error.localizedDescription)" }
    }
    func removeHistory(_ id: String) {
        let values = history.filter { $0.id != id }
        do { try store.save(values); history = values; if currentRecord?.id == id { currentRecord = nil } } catch { message = "移除历史失败：\(error.localizedDescription)" }
    }
    func continueDetail() {
        guard let detail else { return }
        playback.saveProgress()
        guard let record = history.first(where: { $0.mediaDetail?.title.providerID == detail.title.providerID && $0.mediaDetail?.title.id == detail.title.id }) else {
            if let first = selectedLine?.episodes.first { play(first) }
            return
        }
        let candidates = detail.lines.flatMap { line in
            line.episodes.filter { record.canResume(episode: $0) }.map { (line: line, episode: $0) }
        }
        let sameLine = candidates.filter { $0.line.id == record.lineID }
        let match: (line: PlaybackLine, episode: Episode)
        if let exact = candidates.first(where: { $0.line.id == record.lineID && $0.episode.id == record.episodeID }) {
            match = exact
        } else if sameLine.count == 1 {
            match = sameLine[0]
        } else if candidates.count == 1 {
            match = candidates[0]
        } else {
            message = candidates.isEmpty ? "历史中的影片资源已变化，请手动选择集数。" : "多条线路匹配历史影片，请手动选择线路与集数。"
            return
        }
        let resumePosition = record.progress > 0.98 || !record.position.isFinite ? 0 : max(0, record.position)
        selectedLineID = match.line.id
        play(match.episode)
        // Regenerated line/episode IDs produce a new history key, but the verified
        // media URL and episode name still permit resuming the original position.
        currentRecord?.position = resumePosition
        currentRecord?.duration = record.duration.isFinite ? max(0, record.duration) : 0
        playback.resumeWhenReady(resumePosition)
    }
    var detailHasHistory: Bool { guard let detail else { return false }; return history.contains { $0.mediaDetail?.title.providerID == detail.title.providerID && $0.mediaDetail?.title.id == detail.title.id } }
    func checkProvider(_ provider: SourceProvider) {
        guard !checkingProviders.contains(provider.id), checkingProviders.count < 3 else { return }
        checkingProviders.insert(provider.id)
        Task {
            let started = Date()
            do {
                let result = try await service.browse(provider: provider, page: 1)
                guard providers.contains(where: {$0.id == provider.id}) else { checkingProviders.remove(provider.id); return }
                sourceHealth[provider.id] = "目录可达 · \(result.total) 项 · \(Int(Date().timeIntervalSince(started) * 1000)) ms（未验证全部影片）"
            } catch { sourceHealth[provider.id] = "检测失败：\(error.localizedDescription)" }
            checkingProviders.remove(provider.id)
        }
    }
    func checkAllProviders() {
        // Keep provider health checks bounded just like searches.
        Task {
            for provider in providers {
                guard !checkingProviders.contains(provider.id) else { continue }
                checkingProviders.insert(provider.id)
                do {
                    let result = try await service.browse(provider: provider, page: 1)
                    if providers.contains(where: {$0.id == provider.id}) { sourceHealth[provider.id] = "目录可达 · \(result.total) 项（未验证全部影片）" }
                } catch { sourceHealth[provider.id] = "检测失败：\(error.localizedDescription)" }
                checkingProviders.remove(provider.id)
            }
        }
    }
    func restoreBuiltinProviders() {
        for builtin in SourceProvider.defaults where !providers.contains(where: { $0.id == builtin.id || $0.endpoint == builtin.endpoint }) { providers.append(builtin) }
        saveProviders()
    }
    private func saveProgress(_ position: Double, duration: Double) {
        guard historyReadable, position > 0.5, duration.isFinite, var record = currentRecord else { return }
        record.position = position; record.duration = duration; record.updatedAt = Date(); currentRecord = record
        history.removeAll {$0.id == record.id}; history.insert(record, at: 0)
        if history.count > 200 { history = Array(history.prefix(200)) }
        do { try store.save(history) } catch { message = "观看进度保存失败：\(error.localizedDescription)" }
    }
}

 enum CatalogSort: String, CaseIterable, Identifiable {
    case relevance = "默认顺序", title = "按片名", year = "年份优先", sources = "来源数量"
    var id: String { rawValue }
}
