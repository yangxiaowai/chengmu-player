import Foundation
import CinemaCore

@main struct MediaQualityQueueSmoke {
    @MainActor static func main() async throws {
        var checks: [[String: Any]] = []
        func check(_ name: String, _ passed: Bool) { checks.append(["name": name, "passed": passed]); print("\(passed ? "PASS" : "FAIL") \(name)") }
        func wait(_ predicate: () -> Bool) async throws {
            let deadline = Date().addingTimeInterval(4)
            while !predicate(), Date() < deadline { try await Task.sleep(nanoseconds: 10_000_000) }
            if !predicate() { throw NSError(domain: "quality-queue-timeout", code: 1) }
        }
        let provider = SourceProvider(id: "fixture", name: "Fixture", endpoint: URL(string: "https://catalog.example/api")!, enabled: true)
        func title(_ id: String) -> MediaTitle { .init(id: id, title: "Movie \(id)", year: "2026", posterURL: nil, summary: "", providerID: provider.id, providerName: provider.name) }
        func detail(_ title: MediaTitle, _ url: URL) -> MediaDetail {
            .init(title: title, lines: [.init(id: "one", name: "Line 1", episodes: [.init(id: "first", name: "第01集", url: url, number: 1), .init(id: "second", name: "第02集", url: URL(string: "https://media.example/never-read.mp4")!, number: 2)])])
        }
        let c = MediaQualityController()
        var active = 0, maximum = 0, readCount = 0, detailCount = 0
        c.loadDetail = { value, _ in detailCount += 1; return detail(value, URL(string: "https://media.example/\(value.id).mp4")!) }
        c.inspect = { _ in
            active += 1; maximum = max(maximum, active); readCount += 1
            defer { active -= 1 }
            try await Task.sleep(nanoseconds: 30_000_000)
            return MediaQualitySample(width: 1920, height: 1080, frameRate: 24)
        }
        c.check((0..<5).map { title(String($0)) }, providers: [provider])
        try await wait { c.readingCount == 0 && c.queuedCount == 0 }
        check("two_job_limit_and_first_episode_only", maximum == 2 && detailCount == 5 && readCount == 5)
        c.check([title("0"), title("0")], providers: [provider])
        try await Task.sleep(nanoseconds: 50_000_000)
        check("cached_title_is_not_refetched", readCount == 5 && detailCount == 5)
        var clock = Date(); c.now = { clock }
        clock = clock.addingTimeInterval(901)
        c.check([title("0")], providers: [provider])
        try await wait { c.readingCount == 0 }
        check("success_cache_expires", readCount == 6)

        let shared = MediaQualityController(); var sharedReads = 0
        let sharedURL = URL(string: "https://media.example/shared.mp4")!
        shared.loadDetail = { value, _ in detail(value, sharedURL) }
        shared.inspect = { _ in sharedReads += 1; try await Task.sleep(nanoseconds: 40_000_000); return .init(width: 1280, height: 720) }
        shared.check([title("a"), title("b")], providers: [provider])
        try await wait { shared.readingCount == 0 }
        check("same_url_reads_are_shared_across_titles", sharedReads == 1)
        shared.check(line: detail(title("a"), sharedURL).lines[0], providerName: provider.name)
        try await Task.sleep(nanoseconds: 30_000_000)
        check("detail_line_reuses_matching_url_cache", sharedReads == 1)
        shared.inspect = { _ in sharedReads += 1; return .init(width: 1920, height: 1080) }
        shared.check([title("a")], providers: [provider], force: true)
        try await wait { shared.readingCount == 0 }
        check("forced_source_read_bypasses_url_cache", sharedReads == 2 && shared.best(in: [title("a")], providers: [provider])?.sample.width == 1920)
        shared.inspect = { _ in sharedReads += 1; return .init(width: 3840, height: 2160) }
        shared.check(line: detail(title("a"), sharedURL).lines[0], providerName: provider.name, force: true)
        try await wait { shared.readingCount == 0 }
        check("line_refresh_updates_existing_source_observation", shared.best(in: [title("a"), title("b")], providers: [provider])?.sample.width == 3840)
        let lastRead: Date?
        if case .ready(let observation)? = shared.state(for: sharedURL) { lastRead = observation.checkedAt } else { lastRead = nil }
        let later = Date().addingTimeInterval(60); shared.now = { later }
        shared.check([title("alias")], providers: [provider])
        try await wait { shared.readingCount == 0 }
        check("cache_reuse_preserves_original_measurement_time", lastRead != nil && shared.best(in: [title("alias")], providers: [provider])?.checkedAt == lastRead)
        check("sample_progress_counts_unique_urls", shared.completedCount == 1)

        let promotion = MediaQualityController(); var detailOrder: [String] = [], promotionReads = 0
        promotion.loadDetail = { value, _ in detailOrder.append(value.id); return detail(value, sharedURL) }
        promotion.inspect = { _ in promotionReads += 1; return .init(width: promotionReads == 1 ? 1280 : 1920, height: promotionReads == 1 ? 720 : 1080) }
        promotion.check([title("warm")], providers: [provider])
        try await wait { promotion.readingCount == 0 }
        detailOrder.removeAll()
        promotion.setCatalogBusy(true)
        promotion.check((0..<8).map { title("pending-\($0)") }, providers: [provider])
        promotion.check([title("pending-7")], providers: [provider], force: true)
        promotion.setCatalogBusy(false)
        try await wait { promotion.readingCount == 0 && promotion.queuedCount == 0 }
        check("forced_queued_request_is_promoted_and_bypasses_url_cache", detailOrder.first == "pending-7" && promotionReads == 2 && promotion.best(in: [title("pending-7")], providers: [provider])?.sample.width == 1920)

        let failure = MediaQualityController(); var failedReads = 0
        var failureClock = Date(); failure.now = { failureClock }
        failure.loadDetail = { value, _ in detail(value, sharedURL) }
        failure.inspect = { _ in failedReads += 1; throw NSError(domain: "fixture-failure", code: 1, userInfo: [NSLocalizedDescriptionKey: "来源暂时无响应"]) }
        failure.check([title("failure-a")], providers: [provider])
        try await wait { failure.readingCount == 0 }
        failure.check(line: detail(title("failure-a"), sharedURL).lines[0], providerName: provider.name)
        failure.check([title("failure-b")], providers: [provider])
        try await wait { failure.readingCount == 0 }
        check("failure_cooldown_shared_across_title_and_line_aliases", failedReads == 1)
        failure.check([title("failure-b")], providers: [provider], force: true)
        try await wait { failure.readingCount == 0 }
        check("explicit_refresh_bypasses_shared_failure_cooldown", failedReads == 2)
        failureClock = failureClock.addingTimeInterval(61)
        failure.check([title("failure-c")], providers: [provider])
        try await wait { failure.readingCount == 0 }
        check("shared_failure_cooldown_expires", failedReads == 3)

        let overlapping = MediaQualityController(); var overlapReads = 0
        var releaseFailure: CheckedContinuation<Void, Never>?
        overlapping.loadDetail = { value, _ in detail(value, sharedURL) }
        overlapping.inspect = { _ in
            overlapReads += 1
            if overlapReads == 1 { await withCheckedContinuation { releaseFailure = $0 } }
            throw NSError(domain: "fixture-failure", code: 1)
        }
        overlapping.check([title("overlap-a"), title("overlap-b")], providers: [provider])
        try await wait { releaseFailure != nil }
        overlapping.check(line: detail(title("overlap-a"), sharedURL).lines[0], providerName: provider.name)
        releaseFailure?.resume()
        try await wait { overlapping.readingCount == 0 && overlapping.queuedCount == 0 }
        check("failed_url_cooldown_survives_pending_line_state", overlapReads == 1)

        let stale = MediaQualityController(); var oldCompletion: CheckedContinuation<MediaQualitySample, Never>?
        stale.loadDetail = { value, _ in detail(value, sharedURL) }
        stale.inspect = { _ in await withCheckedContinuation { oldCompletion = $0 } }
        stale.check([title("a")], providers: [provider])
        try await wait { oldCompletion != nil }
        stale.setSuspended(true)
        stale.inspect = { _ in .init(width: 3840, height: 2160) }
        stale.check([title("a")], providers: [provider])
        check("playback_suspension_stops_queue_and_new_requests", stale.readingCount == 0 && stale.queuedCount == 0 && stale.state(for: title("a"), providers: [provider]) == nil)
        stale.setSuspended(false); stale.check([title("a")], providers: [provider])
        try await wait { stale.readingCount == 0 }
        oldCompletion?.resume(returning: .init(width: 320, height: 180))
        try await Task.sleep(nanoseconds: 50_000_000)
        check("late_cancelled_result_cannot_overwrite_new_read", stale.best(in: [title("a")], providers: [provider])?.sample.width == 3840)

        let bounded = MediaQualityController(); bounded.setCatalogBusy(true)
        bounded.check((0..<80).map { title(String($0)) }, providers: [provider])
        check("catalog_load_defers_probes_and_queue_is_bounded", bounded.readingCount == 0 && bounded.queuedCount == 48)
        bounded.check(line: detail(title("priority"), URL(string: "https://media.example/priority.mp4")!).lines[0], providerName: provider.name, force: true)
        check("manual_request_is_accepted_when_background_queue_is_full", bounded.state(for: URL(string: "https://media.example/priority.mp4")!) == .queued && bounded.queuedCount == 48)
        bounded.cancelAll()
        check("cancel_removes_queued_states", bounded.queuedCount == 0 && bounded.states.isEmpty)
        var disabled = provider; disabled.enabled = false
        bounded.check([title("a")], providers: [disabled])
        check("disabled_provider_not_probed", bounded.states.isEmpty)

        let alternatives = MediaQualityController(); var alternativeReads: [String] = []
        alternatives.loadDetail = { value, _ in detail(value, URL(string: "https://media.example/\(value.id).mp4")!) }
        alternatives.inspect = { url in
            alternativeReads.append(url.deletingPathExtension().lastPathComponent)
            if url.lastPathComponent.hasPrefix("bad") { throw NSError(domain: "unreachable", code: 1) }
            return .init(width: 1920, height: 1080, frameRate: 24)
        }
        let versions = [title("bad-one"), title("bad-two"), title("good-third")]
        alternatives.checkAlternatives(versions, providers: [provider])
        try await wait { alternatives.readingCount == 0 && alternatives.queuedCount == 0 }
        check("automatic_quality_tries_later_sources_after_failures", alternativeReads == ["bad-one", "bad-two", "good-third"] && alternatives.best(in: versions, providers: [provider])?.sample.width == 1920)
        let before = alternativeReads.count
        alternatives.checkAlternatives(versions, providers: [provider])
        try await wait { alternatives.readingCount == 0 && alternatives.queuedCount == 0 }
        check("successful_alternative_is_reused_without_restarting_failed_sources", alternativeReads.count == before)

        let recovery = MediaQualityController(); var recovered = false, recoveryReads = 0
        var releaseRefresh: CheckedContinuation<Void, Never>?
        recovery.loadDetail = { value, _ in detail(value, URL(string: "https://media.example/\(value.id).mp4")!) }
        recovery.inspect = { url in
            recoveryReads += 1
            if recovered && url.lastPathComponent == "bad-one.mp4" { await withCheckedContinuation { releaseRefresh = $0 } }
            if recovered && url.lastPathComponent == "bad-two.mp4" { return .init(width: 1920, height: 1080) }
            throw NSError(domain: "unreachable", code: 1)
        }
        recovery.checkAlternatives(Array(versions.prefix(2)), providers: [provider])
        try await wait { recovery.readingCount == 0 && recovery.queuedCount == 0 }
        recovered = true
        recovery.checkAlternatives(Array(versions.prefix(2)), providers: [provider], force: true)
        try await wait { releaseRefresh != nil }
        recovery.checkAlternatives(Array(versions.prefix(2)), providers: [provider])
        releaseRefresh?.resume()
        try await wait { recovery.readingCount == 0 && recovery.queuedCount == 0 }
        check("manual_refresh_keeps_recovered_fallback_when_auto_read_reattaches", recoveryReads == 4 && recovery.best(in: versions, providers: [provider])?.sample.width == 1920)

        let passed = checks.allSatisfy { $0["passed"] as? Bool == true }
        let report: [String: Any] = ["passed": passed, "checks": checks, "scope": "Injected metadata/detail closures; concurrency, cancellation races, queue cap and cache. No network/video quality evidence."]
        try JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys]).write(to: URL(fileURLWithPath: CommandLine.arguments[1]))
        if !passed { exit(1) }
    }
}
