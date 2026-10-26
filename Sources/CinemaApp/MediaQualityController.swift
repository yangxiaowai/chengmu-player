import Foundation
import Combine
import CinemaCore

struct MediaQualityObservation: Equatable {
    let sample: MediaQualitySample
    let mediaURL: URL
    let sampleLabel: String
    let providerName: String
    let checkedAt: Date
}

enum MediaQualityState: Equatable {
    case queued, reading
    case ready(MediaQualityObservation)
    case unavailable(String, Date)
}

/// Session-only sample metadata. At most two jobs; playback cancels the whole queue.
@MainActor final class MediaQualityController: ObservableObject {
    struct Key: Hashable {
        let provider: SourceProvider?
        let titleID: String?
        let mediaURL: URL?
    }
    private struct Request {
        let key: Key
        let title: MediaTitle?
        let provider: SourceProvider?
        let episode: Episode?
        let lineName: String?
        var bypassCache = false
    }
    private struct Candidate {
        let title: MediaTitle
        let provider: SourceProvider
    }
    private struct FallbackChain {
        let candidates: [Candidate]
        let force: Bool
    }
    @Published private(set) var states: [Key: MediaQualityState] = [:]
    private var queue: [Request] = []
    private var fallbacks: [Key: FallbackChain] = [:]
    private var tasks: [Key: Task<Void, Never>] = [:]
    private var tokens: [Key: UUID] = [:]
    private var inspections: [URL: Task<MediaQualitySample, Error>] = [:]
    private var inspectionIDs: [URL: UUID] = [:]
    // Pending UI states must not erase the cooldown for a failed media URL.
    private var urlFailures: [URL: (reason: String, checkedAt: Date)] = [:]
    private var suspended = false
    private var catalogBusy = false
    private var enabled = true
    private let successLifetime: TimeInterval = 15 * 60
    private let failureLifetime: TimeInterval = 60
    var now: () -> Date = Date.init
    var loadDetail: (MediaTitle, SourceProvider) async throws -> MediaDetail = {
        try await SourceService().detail(title: $0, provider: $1)
    }
    var inspect: (URL) async throws -> MediaQualitySample = { try await MediaQualityProbe().inspect(url: $0) }

    var readingCount: Int { tasks.count }
    var queuedCount: Int { queue.count }
    var completedCount: Int {
        Set(states.values.compactMap { state -> URL? in
            if case .ready(let value) = state, now().timeIntervalSince(value.checkedAt) < successLifetime { return value.mediaURL }; return nil
        }).count
    }

    func state(for title: MediaTitle, providers: [SourceProvider]) -> MediaQualityState? {
        guard let provider = providers.first(where: { $0.id == title.providerID && $0.enabled }) else { return nil }
        return freshState(Key(provider: provider, titleID: title.id, mediaURL: nil))
    }
    func state(for url: URL) -> MediaQualityState? { freshState(Key(provider: nil, titleID: nil, mediaURL: url)) }
    func best(in titles: [MediaTitle], providers: [SourceProvider]) -> MediaQualityObservation? {
        titles.compactMap { title -> MediaQualityObservation? in
            if case .ready(let value) = state(for: title, providers: providers) { return value }; return nil
        }.max { $0.sample.pixelCount < $1.sample.pixelCount }
    }

    func check(_ titles: [MediaTitle], providers: [SourceProvider], force: Bool = false) {
        for title in titles {
            guard let provider = providers.first(where: { $0.id == title.providerID && $0.enabled }) else { continue }
            enqueue(Request(key: Key(provider: provider, titleID: title.id, mediaURL: nil), title: title, provider: provider, episode: nil, lineName: nil), force: force, priority: force)
        }
        startQueued()
    }
    func checkAlternatives(_ titles: [MediaTitle], providers: [SourceProvider], force: Bool = false) {
        let candidates = titles.compactMap { title -> Candidate? in
            guard let provider = providers.first(where: { $0.id == title.providerID && $0.enabled }) else { return nil }
            return Candidate(title: title, provider: provider)
        }
        enqueueAlternatives(candidates, force: force, priority: force)
        startQueued()
    }
    private func enqueueAlternatives(_ candidates: [Candidate], force: Bool, priority: Bool) {
        guard enabled, !suspended else { return }
        let ready = candidates.filter { if case .ready? = freshState(key(for: $0)) { return true }; return false }
        if !force, !ready.isEmpty { return }
        // Refresh an already working version first, rather than starting with an
        // unavailable catalog just because it sorts earlier in search results.
        let ordered = force ? ready + candidates.filter { candidate in !ready.contains { key(for: $0) == key(for: candidate) } } : candidates
        let remaining = ordered.filter { candidate in
            if !force, case .unavailable? = freshState(key(for: candidate)) { return false }
            return true
        }
        guard let first = remaining.first else { return }
        let key = key(for: first)
        // Scrolling a card back into view must not shorten a user's in-flight
        // refresh chain by filtering its failed alternatives through the cache.
        if !force, fallbacks[key]?.force == true { return }
        enqueue(Request(key: key, title: first.title, provider: first.provider, episode: nil, lineName: nil), force: force, priority: priority)
        if tasks[key] != nil || queue.contains(where: { $0.key == key }) {
            let bypassCache = force || (fallbacks[key]?.force ?? false)
            fallbacks[key] = FallbackChain(candidates: Array(remaining.dropFirst()), force: bypassCache)
        }
    }
    private func key(for candidate: Candidate) -> Key {
        Key(provider: candidate.provider, titleID: candidate.title.id, mediaURL: nil)
    }
    func check(line: PlaybackLine, providerName: String, force: Bool = false) {
        guard let episode = line.episodes.first else { return }
        let key = Key(provider: nil, titleID: nil, mediaURL: episode.url)
        // Provider name is display context only; the URL remains the identity of the media.
        let title = MediaTitle(id: "", title: "", year: "", posterURL: nil, summary: "", providerID: "", providerName: providerName)
        enqueue(Request(key: key, title: title, provider: nil, episode: episode, lineName: line.name), force: force, priority: true)
        startQueued()
    }
    func setEnabled(_ value: Bool) { enabled = value; if !value { cancelAll() } else { startQueued() } }
    func setSuspended(_ value: Bool) { suspended = value; if value { cancelAll() } else { startQueued() } }
    func setCatalogBusy(_ value: Bool) { catalogBusy = value; if !value { startQueued() } }
    func cancelAll() {
        tokens.removeAll(); queue.removeAll(); fallbacks.removeAll()
        tasks.values.forEach { $0.cancel() }; tasks.removeAll()
        inspections.values.forEach { $0.cancel() }; inspections.removeAll(); inspectionIDs.removeAll()
        states = states.filter { _, state in
            switch state { case .queued, .reading: return false; default: return true }
        }
    }

    private func freshState(_ key: Key) -> MediaQualityState? {
        guard let state = states[key] else { return nil }
        switch state {
        case .ready(let value): return now().timeIntervalSince(value.checkedAt) < successLifetime ? state : nil
        case .unavailable(_, let date): return now().timeIntervalSince(date) < failureLifetime ? state : nil
        default: return state
        }
    }
    private func enqueue(_ request: Request, force: Bool, priority: Bool = false) {
        guard enabled, !suspended, tasks[request.key] == nil else { return }
        if let index = queue.firstIndex(where: { $0.key == request.key }) {
            guard force || priority else { return }
            var promoted = queue.remove(at: index)
            promoted.bypassCache = promoted.bypassCache || force
            queue.insert(promoted, at: 0)
            return
        }
        if !force, freshState(request.key) != nil { return }
        if queue.count >= 48 {
            guard priority else { return }
            let displaced = queue.removeLast()
            fallbacks[displaced.key] = nil
            if case .queued = states[displaced.key] { states[displaced.key] = nil }
        }
        var queued = request; queued.bypassCache = force
        states[request.key] = .queued
        if priority { queue.insert(queued, at: 0) } else { queue.append(queued) }
    }
    private func startQueued() {
        guard enabled, !suspended, !catalogBusy else { return }
        while tasks.count < 2, !queue.isEmpty {
            let request = queue.removeFirst(), key = request.key, token = UUID()
            tokens[key] = token; states[key] = .reading
            let detailLoader = loadDetail, inspector = inspect
            tasks[key] = Task { [weak self] in
                var resolvedURLKey: Key?
                var reusedFailureDate: Date?
                do {
                    let episode: Episode, lineName: String, providerName: String
                    if let requested = request.episode {
                        episode = requested; lineName = request.lineName ?? ""; providerName = request.title?.providerName ?? ""
                    } else if let title = request.title, let provider = request.provider {
                        let detail = try await detailLoader(title, provider)
                        try Task.checkCancellation()
                        guard let line = detail.lines.first(where: { !$0.episodes.isEmpty }), let first = line.episodes.first else { throw SourceError.emptyDetail }
                        episode = first; lineName = line.name; providerName = provider.name
                    } else { throw SourceError.emptyDetail }
                    let urlKey = Key(provider: nil, titleID: nil, mediaURL: episode.url)
                    resolvedURLKey = urlKey
                    if !request.bypassCache, let failure = self?.urlFailures[episode.url],
                       let self, self.now().timeIntervalSince(failure.checkedAt) < self.failureLifetime {
                        reusedFailureDate = failure.checkedAt
                        throw NSError(domain: "MediaQualityController", code: 1, userInfo: [NSLocalizedDescriptionKey: failure.reason])
                    }
                    let sample: MediaQualitySample
                    let checkedAt: Date
                    if !request.bypassCache, case .ready(let cached)? = self?.freshState(urlKey) { sample = cached.sample; checkedAt = cached.checkedAt }
                    else {
                        guard let self, self.tokens[key] == token else { return }
                        let flight: Task<MediaQualitySample, Error>, flightID: UUID
                        if let existing = self.inspections[episode.url], let existingID = self.inspectionIDs[episode.url] { flight = existing; flightID = existingID }
                        else {
                            flightID = UUID()
                            flight = Task { try await inspector(episode.url) }
                            self.inspections[episode.url] = flight; self.inspectionIDs[episode.url] = flightID
                        }
                        do { sample = try await flight.value }
                        catch {
                            if self.inspectionIDs[episode.url] == flightID { self.inspections[episode.url] = nil; self.inspectionIDs[episode.url] = nil }
                            throw error
                        }
                        if self.inspectionIDs[episode.url] == flightID { self.inspections[episode.url] = nil; self.inspectionIDs[episode.url] = nil }
                        checkedAt = self.now()
                    }
                    try Task.checkCancellation()
                    guard let self, self.tokens[key] == token else { return }
                    self.urlFailures[episode.url] = nil
                    let observation = MediaQualityObservation(sample: sample, mediaURL: episode.url, sampleLabel: "\(lineName) · \(episode.name)", providerName: providerName, checkedAt: checkedAt)
                    // A line and its source card are views of the same media. Refresh all
                    // ready aliases without changing their source/episode attribution.
                    for (alias, state) in self.states {
                        if case .ready(let old) = state, old.mediaURL == episode.url, old.checkedAt <= checkedAt {
                            self.states[alias] = .ready(MediaQualityObservation(sample: sample, mediaURL: old.mediaURL, sampleLabel: old.sampleLabel, providerName: old.providerName, checkedAt: checkedAt))
                        }
                    }
                    self.states[key] = .ready(observation)
                    // Share a successful first-episode reading with the corresponding detail line.
                    if self.tasks[urlKey] == nil, !self.queue.contains(where: { $0.key == urlKey }) { self.states[urlKey] = .ready(observation) }
                    self.finished(key, token: token)
                } catch {
                    guard let self, self.tokens[key] == token else { return }
                    let failed = MediaQualityState.unavailable(error.localizedDescription, reusedFailureDate ?? self.now())
                    self.states[key] = failed
                    if let url = resolvedURLKey?.mediaURL {
                        self.urlFailures[url] = (error.localizedDescription, reusedFailureDate ?? self.now())
                        if self.urlFailures.count > 256 {
                            let oldest = self.urlFailures.sorted { $0.value.checkedAt < $1.value.checkedAt }.first?.key
                            if let oldest { self.urlFailures[oldest] = nil }
                        }
                    }
                    if let urlKey = resolvedURLKey, self.tasks[urlKey] == nil, !self.queue.contains(where: { $0.key == urlKey }) {
                        self.states[urlKey] = failed
                    }
                    self.finished(key, token: token)
                }
            }
        }
    }
    private func finished(_ key: Key, token: UUID) {
        guard tokens[key] == token else { return }
        tokens[key] = nil; tasks[key] = nil
        let alternatives = fallbacks.removeValue(forKey: key)
        if case .unavailable? = states[key], let alternatives, !alternatives.candidates.isEmpty {
            enqueueAlternatives(alternatives.candidates, force: alternatives.force, priority: true)
        }
        if states.count > 256 {
            let completed = states.compactMap { key, state -> (Key, Date)? in
                switch state { case .ready(let value): return (key, value.checkedAt); case .unavailable(_, let date): return (key, date); default: return nil }
            }.sorted { $0.1 < $1.1 }
            for (key, _) in completed.prefix(states.count - 256) { states[key] = nil }
        }
        startQueued()
    }
}
