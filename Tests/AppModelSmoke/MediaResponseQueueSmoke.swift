import Foundation
import CinemaCore

@main struct MediaResponseQueueSmoke {
    @MainActor static func main() async throws {
        var checks: [[String: Any]] = []
        func check(_ name: String, _ value: Bool) { checks.append(["name": name, "passed": value]); print("\(value ? "PASS" : "FAIL") \(name)") }
        func wait(_ predicate: () -> Bool) async throws {
            let deadline = Date().addingTimeInterval(4)
            while !predicate(), Date() < deadline { try await Task.sleep(nanoseconds: 10_000_000) }
            guard predicate() else { throw NSError(domain: "response-fixture-timeout", code: 1) }
        }
        let provider = SourceProvider(id: "a", name: "来源 A", endpoint: URL(string: "https://fixture.invalid/catalog")!)
        let url = URL(string: "https://fixture.invalid/movie.m3u8")!
        func title(_ id: String) -> MediaTitle { .init(id: id, title: "影片", year: "2026", posterURL: nil, summary: "", providerID: provider.id, providerName: provider.name) }
        func detail(_ title: MediaTitle) -> MediaDetail { .init(title: title, lines: [.init(id: "line", name: "主线路", episodes: [.init(id: "e1", name: "第01集", url: url, number: 1)])]) }
        func controller() -> MediaQualityController {
            let value = MediaQualityController()
            value.loadDetail = { value, _ in detail(value) }
            value.inspect = { _ in .init(width: 1920, height: 1080) }
            value.measureResponse = { _ in .init(milliseconds: 180) }
            return value
        }
        func ms(_ state: MediaResponseState?) -> Int? { if case .ready(let value) = state { return value.sample.milliseconds }; return nil }

        let early = controller(); var finishQuality: CheckedContinuation<MediaQualitySample, Never>?
        early.inspect = { _ in await withCheckedContinuation { finishQuality = $0 } }
        early.check([title("early")], providers: [provider])
        try await wait { finishQuality != nil }
        check("latency_is_visible_before_quality_finishes", ms(early.responseState(for: title("early"), providers: [provider])) == 180 && early.state(for: title("early"), providers: [provider]) == .reading)
        finishQuality?.resume(returning: .init(width: 1920, height: 1080)); try await wait { early.readingCount == 0 }

        let failure = controller()
        failure.inspect = { _ in throw URLError(.cannotDecodeContentData) }
        failure.check([title("fail")], providers: [provider]); try await wait { failure.readingCount == 0 }
        check("quality_failure_keeps_successful_media_response", ms(failure.responseState(for: title("fail"), providers: [provider])) == 180)
        let timeout = controller()
        timeout.measureResponse = { _ in throw URLError(.timedOut) }
        timeout.check([title("timeout")], providers: [provider]); try await wait { timeout.readingCount == 0 }
        check("response_timeout_does_not_discard_usable_quality", timeout.best(in: [title("timeout")], providers: [provider])?.sample.width == 1920)
        if case .unavailable(let reason, _)? = timeout.responseState(for: title("timeout"), providers: [provider]) { check("timeout_is_not_displayed_as_zero_ms", reason == "响应超时") } else { check("timeout_is_not_displayed_as_zero_ms", false) }

        let shared = controller(); var probes = 0
        shared.measureResponse = { _ in probes += 1; try await Task.sleep(nanoseconds: 40_000_000); return .init(milliseconds: probes == 1 ? 180 : 420) }
        shared.check([title("one"), title("two")], providers: [provider]); try await wait { shared.readingCount == 0 }
        check("same_url_shares_one_probe_and_source_line_results", probes == 1 && ms(shared.responseState(for: url)) == 180 && ms(shared.responseState(for: title("two"), providers: [provider])) == 180)
        shared.check([title("three")], providers: [provider]); try await wait { shared.readingCount == 0 }
        check("cached_metadata_reuses_latency_without_network", probes == 1 && ms(shared.responseState(for: title("three"), providers: [provider])) == 180)
        shared.check(line: detail(title("one")).lines[0], providerName: provider.name, force: true); try await wait { shared.readingCount == 0 }
        check("explicit_refresh_updates_all_matching_aliases", probes == 2 && ms(shared.responseState(for: title("one"), providers: [provider])) == 420 && ms(shared.responseState(for: title("two"), providers: [provider])) == 420)

        let stale = controller(); var late: CheckedContinuation<MediaResponseSample, Never>?
        stale.measureResponse = { _ in await withCheckedContinuation { late = $0 } }
        stale.check([title("late")], providers: [provider]); try await wait { late != nil }
        stale.setSuspended(true)
        check("playback_cancels_pending_latency_states", stale.readingCount == 0 && stale.responseState(for: title("late"), providers: [provider]) == nil)
        stale.measureResponse = { _ in .init(milliseconds: 90) }; stale.setSuspended(false)
        stale.check([title("late")], providers: [provider]); try await wait { stale.readingCount == 0 }
        late?.resume(returning: .init(milliseconds: 999)); try await Task.sleep(nanoseconds: 40_000_000)
        check("late_cancelled_probe_cannot_overwrite_new_latency", ms(stale.responseState(for: title("late"), providers: [provider])) == 90)
        var clock = Date().addingTimeInterval(901); shared.now = { clock }
        check("latency_expires_with_session_measurement_cache", shared.responseState(for: title("one"), providers: [provider]) == nil)
        clock = .distantFuture
        let expired = controller(); var expirationClock = Date(), expirationReads = 0
        var finishExpiredQuality: CheckedContinuation<MediaQualitySample, Never>?
        expired.now = { expirationClock }
        expired.measureResponse = { _ in expirationReads += 1; return .init(milliseconds: 210) }
        expired.inspect = { _ in await withCheckedContinuation { finishExpiredQuality = $0 } }
        expired.check([title("expires")], providers: [provider]); try await wait { finishExpiredQuality != nil }
        expirationClock = expirationClock.addingTimeInterval(10)
        finishExpiredQuality?.resume(returning: .init(width: 1920, height: 1080)); try await wait { expired.readingCount == 0 }
        expirationClock = expirationClock.addingTimeInterval(891)
        expired.inspect = { _ in .init(width: 1920, height: 1080) }
        expired.check([title("expires")], providers: [provider]); try await wait { expired.readingCount == 0 }
        check("expired_response_refreshes_even_while_quality_cache_is_fresh", expirationReads == 2 && ms(expired.responseState(for: title("expires"), providers: [provider])) == 210)
        let failedDetail = controller(); var detailProbeCalls = 0
        failedDetail.loadDetail = { _, _ in throw SourceError.emptyDetail }
        failedDetail.measureResponse = { _ in detailProbeCalls += 1; return .init(milliseconds: 1) }
        failedDetail.check([title("empty")], providers: [provider]); try await wait { failedDetail.readingCount == 0 }
        check("catalog_failure_does_not_invent_media_latency", detailProbeCalls == 0 && ms(failedDetail.responseState(for: title("empty"), providers: [provider])) == nil)
        for kind in ["line", "source"] {
            let joined = controller(); var finishJoined: CheckedContinuation<MediaQualitySample, Never>?, joinedProbes = 0
            joined.measureResponse = { _ in joinedProbes += 1; return .init(milliseconds: 180) }
            joined.inspect = { _ in await withCheckedContinuation { finishJoined = $0 } }
            joined.check([title("initial")], providers: [provider]); try await wait { finishJoined != nil }
            if kind == "line" { joined.check(line: detail(title("initial")).lines[0], providerName: provider.name, force: true) }
            else { joined.check([title("joined")], providers: [provider], force: true) }
            try await wait { ms(kind == "line" ? joined.responseState(for: url) : joined.responseState(for: title("joined"), providers: [provider])) == 180 }
            check("late_\(kind)_join_replays_completed_response", ms(kind == "line" ? joined.responseState(for: url) : joined.responseState(for: title("joined"), providers: [provider])) == 180)
            finishJoined?.resume(returning: .init(width: 1920, height: 1080)); try await wait { joined.readingCount == 0 }
            check("late_\(kind)_join_does_not_stay_reading_after_metadata", joinedProbes == 1 && ms(kind == "line" ? joined.responseState(for: url) : joined.responseState(for: title("joined"), providers: [provider])) == 180)
        }
        let queuedFailure = controller(); var finishFailure: CheckedContinuation<MediaQualitySample, Error>?
        queuedFailure.inspect = { _ in try await withCheckedThrowingContinuation { finishFailure = $0 } }
        queuedFailure.check([title("queued-failure")], providers: [provider]); try await wait { finishFailure != nil }
        queuedFailure.setCatalogBusy(true)
        queuedFailure.check(line: detail(title("queued-failure")).lines[0], providerName: provider.name)
        finishFailure?.resume(throwing: URLError(.cannotDecodeContentData)); try await wait { queuedFailure.readingCount == 0 }
        queuedFailure.setCatalogBusy(false); try await wait { queuedFailure.readingCount == 0 && queuedFailure.queuedCount == 0 }
        check("queued_line_keeps_response_after_shared_metadata_failure", ms(queuedFailure.responseState(for: url)) == 180)
        let passed = checks.allSatisfy { $0["passed"] as? Bool == true }
        try JSONSerialization.data(withJSONObject: ["passed": passed, "checks": checks, "scope": "Actual shared quality/response coordinator with controlled async closures, no real network or native pointer interaction."], options: [.prettyPrinted, .sortedKeys]).write(to: URL(fileURLWithPath: CommandLine.arguments[1]))
        if !passed { exit(1) }
    }
}
