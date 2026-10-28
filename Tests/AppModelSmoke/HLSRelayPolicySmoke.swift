import Foundation

@main struct HLSRelayPolicySmoke {
    static func main() throws {
        func require(_ condition: @autoclosure () -> Bool, _ name: String) {
            guard condition() else { fputs("FAIL \(name)\n", stderr); exit(1) }
            print("PASS \(name)")
        }
        let root = URL(string: "https://media.example.test/master.m3u8")!
        require(DirectHLSRelay.supports(root), "unsigned_playlist_supported")
        require(!DirectHLSRelay.supports(URL(string: "https://media.example.test/master.m3u8?token=secret")!), "signed_playlist_system_route")
        let good = "#EXTM3U\n#EXT-X-MEDIA:TYPE=SUBTITLES,URI=\"sub.m3u8\"\n#EXT-X-STREAM-INF:BANDWIDTH=100\nvideo.m3u8\n"
        let parsed = try DirectHLSRelay.rewritePlaylist(good, base: root) { "/local/" + $0.lastPathComponent }
        require(parsed.contains("URI=\"/local/sub.m3u8\"") && parsed.contains("/local/video.m3u8"), "subtitle_and_variant_rewritten")
        for unsafe in ["#EXTM3U\n#EXT-X-KEY:METHOD=AES-128,URI=\"key\"\na.ts\n", "#EXTM3U\nhttps://other.example.test/a.ts\n", "#EXTM3U\na.ts?signature=secret\n", "#EXTM3U\n#EXT-X-FOO:URI=\"a.ts\"\n", "#EXTM3U\n#EXT-X-STREAM-INF:BANDWIDTH=100\nvariant.ts\n", "#EXTM3U\n#EXT-X-MEDIA:TYPE=SUBTITLES,URI=\"sub.ts\"\n"] {
            require((try? DirectHLSRelay.rewritePlaylist(unsafe, base: root) { _ in "/local" }) == nil, "unsafe_playlist_rejected")
        }
    }
}
