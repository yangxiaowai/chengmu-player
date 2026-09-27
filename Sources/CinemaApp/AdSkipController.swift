import Foundation
import Combine
import CinemaCore

/// Scans a bounded look-ahead window. Completed evidence is compact and contains no video frames.
@MainActor
final class AdSkipController: ObservableObject {
    @Published private(set) var segments: [AdSkipSegment] = []
    @Published private(set) var status = "等待播放后识别"
    @Published private(set) var analyzedFrames = 0
    private var url: URL?
    private var itemID = UUID()
    private var protections: [NormalizedVideoRect] = []
    private var observations: [Int: AdFrameObservation] = [:]
    private var completedSegments: [AdSkipSegment] = []
    private var worker: Task<Void, Never>?
    private var workerID = UUID()
    private var analyzer: AdFrameAnalyzer?
    private var position = 0.0
    private var duration = 0.0
    private var enabled = false
    private var retryAfter = Date.distantPast
    private var consecutiveFailures = 0
    private let step = 2.0
    private let lookAhead = 45.0
    private let maxObservations = 360
    private let maxSegments = 128

    func configure(url: URL?, itemID: UUID, protectedRegions: [NormalizedVideoRect]) {
        let protected = [AdCleanupSettings.defaultProtection] + protectedRegions.filter { $0 != AdCleanupSettings.defaultProtection }
        guard self.url != url || self.itemID != itemID || protections != protected else { return }
        cancelWorker()
        self.url = url; self.itemID = itemID; protections = protected
        observations.removeAll(); completedSegments.removeAll(); segments = []; analyzedFrames = 0
        position = 0; duration = 0; retryAfter = .distantPast; consecutiveFailures = 0
        enabled = false
        status = url == nil ? "等待可分析的媒体" : "等待播放后识别"
    }
    func update(position: Double, duration: Double, shouldScan: Bool) {
        guard position.isFinite, position >= 0, duration.isFinite, duration > 0, position < duration,
              position / step < Double(Int.max / 2) else {
            enabled = false; cancelWorker(); status = "等待有效播放时间"; return
        }
        let jumped = abs(position - self.position) > 8
        self.position = position; self.duration = duration
        if jumped { cancelWorker() }
        enabled = shouldScan
        guard shouldScan, let url else {
            cancelWorker(); status = segments.isEmpty ? "识别已暂停" : "识别已暂停 · 已识别 \(segments.count) 段"; return
        }
        guard url.isFileURL || ["http", "https"].contains(url.scheme?.lowercased() ?? "") else {
            cancelWorker(); status = "该媒体类型暂不支持本地广告识别"; return
        }
        guard worker == nil, Date() >= retryAfter else { return }
        guard nextSample() != nil else { status = summary; return }
        let run = UUID(); workerID = run
        let analyzer: AdFrameAnalyzer
        if let existing = self.analyzer { analyzer = existing }
        else { analyzer = AdFrameAnalyzer(); analyzer.configure(url: url); self.analyzer = analyzer }
        status = analyzedFrames == 0 ? "正在预热本地广告识别…" : "正在分析前方画面…"
        worker = Task { [weak self] in await self?.run(id: run, analyzer: analyzer) }
    }
    /// Stop scanning and reject asynchronous callbacks; configure controls when evidence is cleared.
    func stop() {
        enabled = false; cancelWorker()
        status = segments.isEmpty ? "识别已停止" : "识别已停止 · 已识别 \(segments.count) 段"
    }
    private var summary: String {
        if observations.values.contains(where: { $0.classification == .unknown }) {
            return "部分画面暂无法识别 · 已识别 \(segments.count) 段"
        }
        return segments.isEmpty ? "当前前视范围已分析 · 继续播放时补扫" : "已识别 \(segments.count) 段 · 继续分析前方画面"
    }
    private func cancelWorker() {
        workerID = UUID(); worker?.cancel(); worker = nil
        analyzer?.cancel(); analyzer = nil
    }
    private func nextSample() -> (Int, Double)? {
        let first = max(0, Int(floor(position / step)))
        let last = Int(floor(min(duration - 0.1, position + lookAhead) / step))
        guard last >= first else { return nil }
        for key in first...last where observations[key] == nil { return (key, Double(key) * step) }
        return nil
    }
    private func run(id: UUID, analyzer: AdFrameAnalyzer) async {
        defer {
            // Keep the paused decoder warm when the look-ahead window is complete.
            if workerID == id { worker = nil }
        }
        while !Task.isCancelled, workerID == id, enabled, let (key, requested) = nextSample() {
            let frame = await analyzer.analyze(time: requested, protectedRegions: protections)
            guard !Task.isCancelled, workerID == id, enabled else { return }
            // Preserve actual PTS, not requested times; repeated/mismatched outputs must not create evidence.
            let usable = frame.time.isFinite && frame.time >= 0 && abs(frame.time - requested) <= 0.2 &&
                !observations.values.contains(where: { abs($0.time - frame.time) < 0.001 })
            let stored = usable ? frame : AdFrameObservation(time: requested, classification: .unknown)
            observations[key] = stored
            analyzedFrames += 1
            if observations.count > maxObservations {
                let oldest = observations.keys.sorted { abs(Double($0) * step - position) > abs(Double($1) * step - position) }
                for key in oldest.prefix(observations.count - maxObservations) { observations[key] = nil }
            }
            rebuildSegments()
            if stored.classification == .unknown {
                consecutiveFailures += 1
                retryAfter = Date().addingTimeInterval(min(30, pow(2, Double(min(consecutiveFailures, 4)))))
                status = analyzer.lastFailure ?? "画面分析暂不可用，稍后继续"
                analyzer.cancel(); self.analyzer = nil
                return
            }
            consecutiveFailures = 0; retryAfter = .distantPast
            status = segments.isEmpty ? "正在分析前方画面 · 已分析 \(analyzedFrames) 帧" : "已识别 \(segments.count) 段 · 正在分析前方画面"
            // Yield between frames so foreground interaction, decoding and previews retain priority.
            do { try await Task.sleep(nanoseconds: 150_000_000) } catch { return }
        }
        if workerID == id { status = summary }
    }
    private func rebuildSegments() {
        let ordered = observations.values.sorted { $0.time < $1.time }
        let found = AdSegmentPolicy.segments(from: ordered)
        for value in found where !completedSegments.contains(where: { $0.id == value.id }) { completedSegments.append(value) }
        // Overlapping rediscoveries can follow cache eviction or a differently aligned seek; keep the larger confirmed interval.
        completedSegments.sort { $0.start < $1.start }
        var compact: [AdSkipSegment] = []
        for value in completedSegments {
            if let last = compact.last, value.start <= last.end {
                if value.start >= last.start && value.end <= last.end { continue }
                if value.start <= last.start && value.end >= last.end { compact.removeLast() }
                else { continue } // Do not invent the unobserved union of differently bounded intervals.
            }
            compact.append(value)
        }
        completedSegments = Array(compact.suffix(maxSegments))
        segments = completedSegments
    }
}
