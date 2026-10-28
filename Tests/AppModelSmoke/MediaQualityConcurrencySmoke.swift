import Foundation
import CinemaCore

@main struct MediaQualityConcurrencySmoke {
    @MainActor static func main() async throws {
        let reportURL = URL(fileURLWithPath: CommandLine.arguments[1])
        let provider = SourceProvider(id: "probe", name: "probe", endpoint: URL(string: "https://fixture.invalid/api")!)
        func title(_ id: String) -> MediaTitle { .init(id: id, title: id, year: "2020", posterURL: nil, summary: "", providerID: provider.id, providerName: provider.name) }
        let media = URL(string: "https://fixture.invalid/shared.mp4")!
        func detail(_ item: MediaTitle) -> MediaDetail {
            .init(title: item, lines: [.init(id: "line", name: "Line", episodes: [.init(id: "episode", name: "正片", url: media, number: nil)])])
        }
        func wait(_ message: String, timeout: TimeInterval = 4, _ condition: () -> Bool) async throws {
            let deadline = Date().addingTimeInterval(timeout)
            while !condition() && Date() < deadline { try await Task.sleep(nanoseconds: 10_000_000) }
            guard condition() else { throw NSError(domain: message, code: 1) }
        }
        var checks: [[String: Any]] = []
        func check(_ name: String, _ passed: Bool) { checks.append(["name": name, "passed": passed]); print("\(passed ? "PASS" : "FAIL") \(name)") }

        let parallel = MediaQualityController()
        var responseContinuation: CheckedContinuation<MediaResponseSample, Never>?
        var inspectorStarted = false
        parallel.loadDetail = { item, _ in detail(item) }
        parallel.measureResponse = { _ in await withCheckedContinuation { responseContinuation = $0 } }
        parallel.inspect = { _ in inspectorStarted = true; return .init(width: 1920, height: 1080) }
        parallel.check([title("one")], providers: [provider])
        try await wait("response started") { responseContinuation != nil }
        try await Task.sleep(nanoseconds: 250_000_000)
        check("quality_starts_while_response_is_pending", inspectorStarted)
        responseContinuation?.resume(returning: .init(milliseconds: 120))
        try await wait("parallel inspection completes") { parallel.readingCount == 0 && parallel.queuedCount == 0 }
        if case .ready(let quality)? = parallel.state(for: title("one"), providers: [provider]),
           case .ready(let response)? = parallel.responseState(for: title("one"), providers: [provider]) {
            check("both_observations_retained", quality.sample.width == 1920 && response.sample.milliseconds == 120)
        } else { check("both_observations_retained", false) }

        let shared = MediaQualityController()
        var responseCalls = 0, qualityCalls = 0
        shared.loadDetail = { item, _ in detail(item) }
        shared.measureResponse = { _ in responseCalls += 1; try await Task.sleep(nanoseconds: 80_000_000); return .init(milliseconds: 90) }
        shared.inspect = { _ in qualityCalls += 1; try await Task.sleep(nanoseconds: 80_000_000); return .init(width: 1280, height: 720) }
        shared.check([title("first"), title("second")], providers: [provider])
        try await wait("shared inspection completes") { shared.readingCount == 0 && shared.queuedCount == 0 }
        check("same_media_has_one_shared_flight", responseCalls == 1 && qualityCalls == 1)

        let failure = MediaQualityController()
        failure.loadDetail = { item, _ in detail(item) }
        failure.measureResponse = { _ in throw URLError(.timedOut) }
        failure.inspect = { _ in .init(width: 3840, height: 2160) }
        failure.check([title("failure")], providers: [provider])
        try await wait("response failure finishes") { failure.readingCount == 0 && failure.queuedCount == 0 }
        if case .ready(let value)? = failure.state(for: title("failure"), providers: [provider]),
           case .unavailable? = failure.responseState(for: title("failure"), providers: [provider]) {
            check("response_failure_does_not_discard_quality", value.sample.width == 3840)
        } else { check("response_failure_does_not_discard_quality", false) }

        let cancel = MediaQualityController()
        var headEntered = false
        cancel.loadDetail = { item, _ in detail(item) }
        cancel.measureResponse = { _ in headEntered = true; try await Task.sleep(nanoseconds: 2_000_000_000); return .init(milliseconds: 100) }
        cancel.inspect = { _ in try await Task.sleep(nanoseconds: 2_000_000_000); return .init(width: 1920, height: 1080) }
        cancel.check([title("cancel")], providers: [provider])
        try await wait("head enters") { headEntered }
        cancel.cancelAll()
        try await Task.sleep(nanoseconds: 150_000_000)
        check("cancel_clears_pending_results", cancel.state(for: title("cancel"), providers: [provider]) == nil && cancel.responseState(for: title("cancel"), providers: [provider]) == nil && cancel.readingCount == 0)

        let passed = checks.allSatisfy { $0["passed"] as? Bool == true }
        let result: [String: Any] = ["passed": passed, "checks": checks,
            "scope": "Headless MediaQualityController with deterministic injected probes; no real network or playback."]
        try JSONSerialization.data(withJSONObject: result, options: [.prettyPrinted, .sortedKeys]).write(to: reportURL)
        exit(passed ? 0 : 1)
    }
}
