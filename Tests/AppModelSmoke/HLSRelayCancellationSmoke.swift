import Foundation

private final class Flag: @unchecked Sendable {
    private let lock = NSLock(); private var state = false
    func set() { lock.withLock { state = true } }
    var triggered: Bool { lock.withLock { state } }
}
@main struct HLSRelayCancellationSmoke {
    static func main() async throws {
        let origin = URL(string: try String(contentsOfFile: CommandLine.arguments[1], encoding: .utf8))!
        let failure = Flag()
        guard let relay = DirectHLSRelay(url: origin.deletingLastPathComponent().appendingPathComponent("slow-bad.m3u8"), onFailure: { failure.set() }) else { exit(1) }
        defer { relay.stop() }
        let task = URLSession.shared.dataTask(with: relay.url); task.resume()
        try await Task.sleep(nanoseconds: 200_000_000); task.cancel()
        try await Task.sleep(nanoseconds: 2_000_000_000)
        guard !failure.triggered else { fputs("FAIL canceled_preview_did_not_trigger_fallback\n", stderr); exit(1) }
        print("PASS canceled_preview_did_not_trigger_fallback")
    }
}
