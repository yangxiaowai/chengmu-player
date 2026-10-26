import Foundation
import CinemaCore

@main struct MediaResponseIntegration {
    static func main() async throws {
        let base = URL(string: CommandLine.arguments[1])!
        var checks: [[String: Any]] = []
        func check(_ name: String, _ value: Bool, _ detail: String = "") { checks.append(["name": name, "passed": value, "detail": detail]); print("\(value ? "PASS" : "FAIL") \(name) \(detail)") }
        let probe = MediaResponseProbe(timeout: 0.6)
        for path in ["fast", "slow-headers", "never-body", "large-body", "empty", "redirect"] {
            do {
                let value = try await probe.inspect(url: base.appendingPathComponent(path))
                check("response_\(path)", value.milliseconds > 0 && value.milliseconds < 2000 && (path != "slow-headers" || value.milliseconds >= 150), "\(value.milliseconds) ms")
            } catch { check("response_\(path)", false, error.localizedDescription) }
        }
        for path in ["http-error", "method-not-supported", "timeout"] {
            let started = Date()
            do { _ = try await probe.inspect(url: base.appendingPathComponent(path)); check("reject_\(path)", false) }
            catch { check("reject_\(path)", Date().timeIntervalSince(started) < 2.5) }
        }
        let cancelled = Task { try await probe.inspect(url: base.appendingPathComponent("cancel")) }
        try await Task.sleep(nanoseconds: 100_000_000)
        let cancelStart = Date(); cancelled.cancel()
        do { _ = try await cancelled.value; check("inflight_cancellation", false) }
        catch { check("inflight_cancellation", Date().timeIntervalSince(cancelStart) < 1) }
        let (data, _) = try await URLSession.shared.data(from: base.appendingPathComponent("stats"))
        let stats = try JSONSerialization.jsonObject(with: data) as! [String: Int]
        check("head_requests_do_not_download_media_body", stats["bodyBytes", default: 0] == 0)
        check("cancelled_request_reached_server", stats["cancelRequests", default: 0] > 0)
        let passed = checks.allSatisfy { $0["passed"] as? Bool == true }
        try JSONSerialization.data(withJSONObject: ["passed": passed, "checks": checks, "scope": "Actual loopback HTTP server + production URLSession HEAD delegate: delayed headers, no/large body, redirects, 405/errors, timeout and cancellation. HTTP response headers, not body-first-byte, playback startup, throughput or mainland connectivity."], options: [.prettyPrinted, .sortedKeys]).write(to: URL(fileURLWithPath: CommandLine.arguments[2]))
        if !passed { exit(1) }
    }
}
