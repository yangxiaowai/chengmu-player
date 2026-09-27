import Foundation
import CinemaCore

/// Deterministic, headless checks of the real SourceAccessController queue.
/// The injected probe deliberately ignores task cancellation so late completion
/// can be exercised. No media, HTTP request, window, or UI interaction is used.
@main
struct SourceAccessSmoke {
    struct Failure: Error, CustomStringConvertible {
        let description: String
        init(_ description: String) { self.description = description }
    }
    struct Check: Encodable {
        let name: String
        let passed: Bool
        let detail: String
    }
    struct Summary: Encodable {
        let checkedAt: String
        let mode = "headless SourceAccessController with deterministic suspended probes"
        let mediaRequestsMade = false
        let nativeUIVerified = false
        let sourceAvailabilityVerified = false
        let passed: Bool
        let checks: [Check]
    }
    struct Snapshot: Sendable {
        let started: [String]
        let active: Set<String>
        let peakActive: Int
    }

    actor Gate {
        private var continuations: [String: CheckedContinuation<SourceAccessReport, Error>] = [:]
        private var counts: [String: Int] = [:]
        private var started: [String] = []
        private var peakActive = 0

        func probe(_ provider: SourceProvider) async throws -> SourceAccessReport {
            counts[provider.id, default: 0] += 1
            let invocation = "\(provider.id)#\(counts[provider.id]!)"
            started.append(invocation)
            // No cancellation handler: this is intentionally a non-cooperative
            // dependency, allowing the controller's result guards to be tested.
            return try await withCheckedThrowingContinuation { continuation in
                continuations[invocation] = continuation
                peakActive = max(peakActive, continuations.count)
            }
        }
        func snapshot() -> Snapshot {
            Snapshot(started: started, active: Set(continuations.keys), peakActive: peakActive)
        }
        func finish(_ invocation: String, failing: Bool = false) throws {
            guard let continuation = continuations.removeValue(forKey: invocation) else {
                throw Failure("Missing suspended invocation: \(invocation)")
            }
            if failing {
                continuation.resume(throwing: Failure("Intentional probe failure"))
            } else {
                let providerID = String(invocation.split(separator: "#")[0])
                do {
                    continuation.resume(returning: try Self.report(providerID: providerID, marker: invocation))
                } catch {
                    continuation.resume(throwing: error)
                    throw error
                }
            }
        }
        func finishAll() throws {
            for invocation in continuations.keys.sorted() { try finish(invocation) }
        }
        private static func report(providerID: String, marker: String) throws -> SourceAccessReport {
            // Use Codable so this executable can also link Core builds predating
            // the report's public initializer. Every nonoptional field is set.
            let object: [String: Any] = [
                "providerID": providerID, "checkedAt": 0,
                "catalogReachable": true, "playlistReachable": true,
                "segmentReachable": true, "sampleTitle": marker,
                "mediaHost": "fixture.invalid", "sampleBytes": 188,
                "elapsedMS": 1, "encrypted": false
            ]
            return try JSONDecoder().decode(SourceAccessReport.self, from: JSONSerialization.data(withJSONObject: object))
        }
    }

    static func provider(_ id: String) -> SourceProvider {
        SourceProvider(id: id, name: id, endpoint: URL(string: "https://fixture.invalid/\(id)")!)
    }
    @MainActor static func controller(_ gate: Gate) -> SourceAccessController {
        let controller = SourceAccessController()
        controller.probe = { provider in try await gate.probe(provider) }
        return controller
    }
    static func require(_ condition: Bool, _ message: String) throws {
        if !condition { throw Failure(message) }
    }
    @MainActor static func eventually(_ message: String, _ condition: () async -> Bool) async throws {
        let deadline = Date().addingTimeInterval(2)
        repeat {
            if await condition() { return }
            try await Task.sleep(nanoseconds: 1_000_000)
        } while Date() < deadline
        throw Failure("Timed out: \(message)")
    }
    @MainActor static func settle() async throws {
        // A short bounded yield lets a resumed controller Task publish its state.
        // The probe itself has no timer and never performs network requests.
        for _ in 0..<10 { await Task.yield() }
        try await Task.sleep(nanoseconds: 5_000_000)
    }

    @MainActor static func queueLimitAndDeduplication() async throws -> String {
        let gate = Gate(), model = controller(gate)
        let providers = ["a", "b", "c", "d", "e"].map(provider)
        model.check(providers + [providers[0], providers[4]])
        model.check(providers)
        try await eventually("first three probes start") { await gate.snapshot().started.count == 3 }
        try require(model.running == Set(["a", "b", "c"]), "Queue did not start the first three unique providers")
        try require(model.pending == Set(providers.map(\.id)), "Duplicate submissions changed pending membership")
        try await gate.finish("a#1")
        try await eventually("fourth provider starts after one completion") { await gate.snapshot().started.count == 4 }
        try require(model.reports["a"]?.sampleTitle == "a#1", "Completed report was not published")
        try require(model.running == Set(["b", "c", "d"]), "Queue did not replace exactly one running item")
        try await gate.finish("b#1")
        try await eventually("fifth provider starts") { await gate.snapshot().started.count == 5 }
        try await gate.finishAll()
        try await eventually("all queue state drains") { model.pending.isEmpty && model.running.isEmpty }
        let snapshot = await gate.snapshot()
        try require(snapshot.peakActive == 3, "Observed \(snapshot.peakActive) concurrent probes; expected maximum three")
        try require(Set(snapshot.started) == Set(providers.map { "\($0.id)#1" }), "Duplicate provider was probed more than once")
        try require(model.reports.count == 5, "Expected five successful reports")
        return "Five unique providers completed; duplicate submissions were ignored and peak active probes was three."
    }

    @MainActor static func cancelAllIgnoresLateResults() async throws -> String {
        let gate = Gate(), model = controller(gate)
        model.check(["a", "b", "c", "d", "e"].map(provider))
        try await eventually("three probes start") { await gate.snapshot().started.count == 3 }
        model.cancelAll()
        try require(model.pending.isEmpty && model.running.isEmpty, "cancelAll did not clear visible queue state immediately")
        try await gate.finishAll()
        try await settle()
        let snapshot = await gate.snapshot()
        try require(model.reports.isEmpty, "Canceled late result reappeared as a report")
        try require(snapshot.started.count == 3, "cancelAll allowed a previously queued provider to start")
        try require(model.pending.isEmpty && model.running.isEmpty, "Late canceled results recreated queue state")
        return "Cancel cleared three running and two queued checks; three non-cooperative late completions were ignored."
    }

    @MainActor static func removeRunningAndQueuedProviders() async throws -> String {
        let gate = Gate(), model = controller(gate)
        model.check(["a", "b", "c", "d", "e"].map(provider))
        try await eventually("initial probes start") { await gate.snapshot().started.count == 3 }
        model.remove("e") // Queued provider must never start.
        model.remove("a") // Running provider can still produce a late value.
        try await eventually("queue advances after removal") { await gate.snapshot().started.count == 4 }
        try require(!model.pending.contains("a") && !model.pending.contains("e"), "Removed provider remained pending")
        try await gate.finish("a#1")
        try await settle()
        try require(model.reports["a"] == nil, "Removed running provider's report reappeared")
        try await gate.finishAll()
        try await eventually("remaining providers finish") { model.pending.isEmpty && model.running.isEmpty }
        let snapshot = await gate.snapshot()
        try require(!snapshot.started.contains("e#1"), "Removed queued provider started later")
        try require(Set(model.reports.keys) == Set(["b", "c", "d"]), "Unexpected reports after provider removal")
        model.remove("b")
        try require(model.reports["b"] == nil, "Removing a completed provider retained its report")
        return "Removed queued, running, and completed providers stayed absent; removal advanced the remaining queue."
    }

    @MainActor static func oldCompletionCannotClearNewPendingCheck() async throws -> String {
        let gate = Gate(), model = controller(gate)
        model.check([provider("same")])
        try await eventually("old generation starts") { await gate.snapshot().started.count == 1 }
        model.cancelAll()
        model.check([provider("same")])
        try await eventually("new generation starts") { await gate.snapshot().started.count == 2 }
        try await gate.finish("same#1")
        try await settle()
        try require(model.pending.contains("same") && model.running.contains("same"), "Old completion cleared the new generation's state")
        try require(model.reports["same"] == nil, "Old canceled report appeared while a new check was pending")
        try await gate.finish("same#2")
        try await eventually("new generation publishes") { model.reports["same"]?.sampleTitle == "same#2" }
        try require(model.pending.isEmpty && model.running.isEmpty, "New generation did not drain normally")
        return "An old same-ID completion could not remove a newer pending/running check."
    }

    @MainActor static func oldCompletionCannotOverwriteNewReport() async throws -> String {
        let gate = Gate(), model = controller(gate)
        model.check([provider("same")])
        try await eventually("old generation starts") { await gate.snapshot().started.count == 1 }
        model.cancelAll()
        model.check([provider("same")])
        try await eventually("new generation starts") { await gate.snapshot().started.count == 2 }
        try await gate.finish("same#2")
        try await eventually("new report appears first") { model.reports["same"]?.sampleTitle == "same#2" }
        try await gate.finish("same#1")
        try await settle()
        try require(model.reports["same"]?.sampleTitle == "same#2", "Late old report overwrote the newest report")
        try require(model.pending.isEmpty && model.running.isEmpty, "Late old report recreated queue state")
        return "A newer same-ID report survived a subsequently delivered old canceled result."
    }

    @MainActor static func thrownProbeReleasesQueueSlot() async throws -> String {
        let gate = Gate(), model = controller(gate)
        model.check(["a", "b", "c", "d"].map(provider))
        try await eventually("initial probes start") { await gate.snapshot().started.count == 3 }
        try await gate.finish("a#1", failing: true)
        try await eventually("queued provider starts after thrown failure") { await gate.snapshot().started.count == 4 }
        try require(model.reports["a"] == nil && !model.pending.contains("a"), "Thrown probe left stale success or pending state")
        try await gate.finishAll()
        try await eventually("remaining queue drains") { model.pending.isEmpty && model.running.isEmpty }
        try require(Set(model.reports.keys) == Set(["b", "c", "d"]), "Failure prevented unrelated reports from completing")
        return "A thrown probe released its slot and the remaining providers completed."
    }

    @MainActor static func main() async {
        let cases: [(String, @MainActor () async throws -> String)] = [
            ("queue_limit_and_deduplication", queueLimitAndDeduplication),
            ("cancel_all_ignores_late_results", cancelAllIgnoresLateResults),
            ("remove_running_queued_and_completed_providers", removeRunningAndQueuedProviders),
            ("old_completion_cannot_clear_new_pending_check", oldCompletionCannotClearNewPendingCheck),
            ("old_completion_cannot_overwrite_new_report", oldCompletionCannotOverwriteNewReport),
            ("thrown_probe_releases_queue_slot", thrownProbeReleasesQueueSlot)
        ]
        var checks: [Check] = []
        for (name, body) in cases {
            do { checks.append(Check(name: name, passed: true, detail: try await body())) }
            catch { checks.append(Check(name: name, passed: false, detail: String(describing: error))); break }
        }
        let passed = checks.count == cases.count && checks.allSatisfy(\.passed)
        let summary = Summary(checkedAt: ISO8601DateFormatter().string(from: Date()), passed: passed, checks: checks)
        do {
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
            let data = try encoder.encode(summary)
            FileHandle.standardOutput.write(data + Data("\n".utf8))
        } catch {
            FileHandle.standardError.write(Data("Could not encode smoke evidence: \(error)\n".utf8))
            exit(1)
        }
        exit(passed ? 0 : 1)
    }
}
