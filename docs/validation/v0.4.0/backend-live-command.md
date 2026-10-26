# Minimal live HLS metadata sample

The driver uses an independently compiled CinemaCore static library. It performs exactly
one Mux public-HLS metadata attempt, then searches only mdzy for `星际穿越` with
`SourceService.search`. If an exact title is found, it calls `detail` once and
inspects only the first episode of the first returned usable line. A catalog
failure ends that sample without other titles, lines, providers or retries.

The provider comes from the app's `local.yingchuan.cinema` UserDefaults domain,
falling back to the compiled mdzy default only if no saved mdzy configuration
exists. The report records the configuration source and enabled state.

Reproduce from the repository root after building CinemaCore:

```bash
live_probe_dir=$(mktemp -d "${TMPDIR:-/tmp/}cinema-quality-live.XXXXXX")
xcrun swiftc -parse-as-library -swift-version 5 -target arm64-apple-macos15.0 \
  -emit-library -static -emit-module -module-name CinemaCore \
  -emit-module-path "$live_probe_dir/CinemaCore.swiftmodule" \
  Sources/CinemaCore/*.swift -o "$live_probe_dir/libCinemaCore.a"
xcrun swiftc -parse-as-library -swift-version 5 -target arm64-apple-macos15.0 \
  -I "$live_probe_dir" -L "$live_probe_dir" -lCinemaCore \
  scripts/validation/media-quality/live-sample.swift -o "$live_probe_dir/live-probe"
"$live_probe_dir/live-probe" docs/validation/v0.4.0/backend-live-sample-hls-fallback.json
```

Each metadata inspection is bounded by the production probe's eight-second
timeout and cancels the asset's loading. AVFoundation can request playlists and
initial media bytes needed for track metadata. HLS without exposed asset tracks
can prepare a private muted AVPlayerItem with display-sleep prevention disabled.
If preparation still yields no dimensions, it briefly reads at most the first
available video output frame. Every exit pauses and detaches the item and cancels
asset loading. The sample's `evidence` and summary distinguish track/prepared-item
metadata from a first-frame read. No complete media decoding, ffprobe, or whole
movie download is used.

The original `backend-live-sample.json` preserves the initial track-only failure;
`backend-live-sample-hls-fallback.json` records one further attempt per same source
after adding preparation/first-frame fallback.

The report is a snapshot from this host. It does not certify mainland-China
direct connectivity, every HLS rendition, the rendition selected during later
playback, continuous playback, perceptual quality or the identity of a movie.
