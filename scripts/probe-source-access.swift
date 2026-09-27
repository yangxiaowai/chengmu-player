// After bash scripts/swift.sh build:
// swiftc -parse-as-library -target arm64-apple-macos15.0 -I .build/out/Products/Debug -L .build/out/Products/Debug -lCinemaCore scripts/probe-source-access.swift -o .build/probe-source-access
// .build/probe-source-access > docs/validation/v0.2.2/app-source-access.json
import Foundation
import CinemaCore

@main struct AppSourceAccessCheck {
    struct Output: Encodable {
        let routing = "HTTP proxies excluded; VPN routing and DNS still follow system settings. This is not a mainland-direct test."
        let scope = "Live check of the app's shared Core probe, not UI, decoding, or sustained playback."
        let reports: [SourceAccessReport]
    }
    static func main() async throws {
        var reports: [SourceAccessReport] = []
        for provider in SourceProvider.defaults where ["dytt", "mdzy"].contains(provider.id) {
            reports.append(try await SourceAccessProbe().check(provider: provider))
        }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        print(String(decoding: try encoder.encode(Output(reports: reports)), as: UTF8.self))
        if reports.contains(where: { !$0.passed }) { exit(1) }
    }
}
