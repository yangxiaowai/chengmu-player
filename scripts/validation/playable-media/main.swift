import Foundation
import CinemaCore

@main struct PlayableMediaSmoke {
    static func main() async throws {
        let base = URL(string: CommandLine.arguments[1])!
        let reportPath = URL(fileURLWithPath: CommandLine.arguments[2])
        var checks: [[String: Any]] = []
        func check(_ name: String, _ ok: Bool) { checks.append(["name": name, "passed": ok]) }
        func url(_ path: String) -> URL { base.appendingPathComponent(path) }
        let probe = PlayableMediaProbe(timeout: 2)
        let mp4 = try await probe.inspect(url: url("file"))
        check("range_get_accepts_extensionless_mp4", mp4 == .mp4)
        let hls = try await probe.inspect(url: url("playlist"))
        check("extensionless_hls_playlist_parsed", hls == .hls)
        let ignored = try await probe.inspect(url: url("ignores-range"))
        check("ignored_range_uses_bounded_prefix", ignored == .mp4)
        for path in ["html", "bad-range", "redirect-file"] {
            do { _ = try await probe.inspect(url: url(path)); check("reject_\(path)", false) }
            catch { check("reject_\(path)", true) }
        }
        let start = Date()
        do { _ = try await PlayableMediaProbe(timeout: 0.35).inspect(url: url("slow")); check("deadline", false) }
        catch { check("deadline", Date().timeIntervalSince(start) < 1.5) }
        let task = Task { try await probe.inspect(url: url("slow")) }
        try await Task.sleep(nanoseconds: 100_000_000)
        let cancelledAt = Date(); task.cancel()
        do { _ = try await task.value; check("cancellation", false) }
        catch { check("cancellation", Date().timeIntervalSince(cancelledAt) < 1.5) }
        try await Task.sleep(nanoseconds: 200_000_000)
        let (data, _) = try await URLSession.shared.data(from: url("stats"))
        let stats = try JSONSerialization.jsonObject(with: data) as! [String: Int]
        check("head_never_used", stats["head", default: -1] == 0)
        check("range_requested_for_file", stats["range", default: 0] >= 2)
        check("server_writes_bounded_when_range_ignored", stats["ignoredBytes", default: Int.max] <= 196_608)
        let passed = checks.allSatisfy { $0["passed"] as? Bool == true }
        let report: [String: Any] = ["passed": passed, "checks": checks, "server": stats,
                                     "scope": "Local HTTP server and generated MP4. Prefix and manifest checks only; not full decoding or playback."]
        try JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys]).write(to: reportPath)
        print(String(decoding: try JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys]), as: UTF8.self))
        if !passed { exit(1) }
    }
}
