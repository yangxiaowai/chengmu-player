# AVFoundation metadata validation

The root `backend-media-quality.json` and `backend-unit-tests.log` preserve the
initial track-only implementation baseline. Current HLS fallback validation is
under `backend-hls-local/` (15 integration checks) and
`backend-hls-unit-tests.log` (six unit tests). Live sample evidence is recorded
separately in `backend-live-sample-hls-fallback.json`; the original unsuccessful
track-only live attempt remains in `backend-live-sample.json`.

Run `scripts/validate-media-quality.sh` from the repository. The app's production
probe uses AVFoundation only. ffmpeg is used by this development validation to
generate short local fixtures; Python runs inside conda `searchformoney` and serves
the HTTP fixtures on loopback. Neither is a product dependency.

The independent Swift driver validates:

- 640×360 H.264 at 24 fps, including codec FourCC and estimated track bitrate.
- A 90-degree track display matrix, reported as 360×640.
- A file named `claimed-4K.mp4` whose actual video remains 640×360.
- The same metadata over a local HTTP server supporting byte ranges.
- Rejection of malformed/unsupported URLs, embedded credentials, a corrupt file,
  and an audio-only file.
- Conservative labels, invalid-value normalization and a Codable round trip.
- A server accepting requests without returning response bytes: timeout and Task
  cancellation both return within two seconds, and the server observes each
  connection actually close within two seconds.

`backend-media-quality.json` records metadata and measured completion times.
`backend-http-events.jsonl` records the actual stalled connection lifetimes.
`backend-media-quality.log` records the independent driver's summary.
`backend-unit-tests.log` records the separate temporary SwiftPM package run of
`MediaQualityProbeTests.swift`, avoiding the repository's shared build lock.

The initial validation fixture used ffmpeg's `rotate` metadata option, which did
not write a display matrix with the installed ffmpeg 7.1.1. The fixture now uses
`-display_rotation 90`; ffprobe confirmed that the fixture contains a display
matrix before AVFoundation orientation validation. The default Python HTTP
server also required explicit Range handling to satisfy AVFoundation's request
for two bytes. These were fixture corrections.

The current implementation first loads track metadata. If HLS exposes no tracks,
it prepares a short-lived private muted player item on MainActor. Ready-to-play
presentation dimensions and available item track metadata can finish without
starting playback. Otherwise it briefly starts muted playback and returns at the
first available video-output pixel buffer. `evidence: firstFrame` and the engineering
`首帧读取` summary identify this case; `evidence: track`/`轨道读取` identifies track
or prepared-item metadata. Missing nominal frame rate remains absent.
The consumer UI shows resolution and frame rate without those internal evidence
labels; an unavailable frame rate is shown as unknown.

The player never attaches to a view, has volume zero and is muted, disables
display-sleep prevention, requests a small forward buffer and disallows live
network buffering while paused. Every success/error/cancellation path pauses the
player, detaches its item and output, and cancels asset loading. The same outer
eight-second budget covers track loading, preparation and first-frame fallback.

The local HLS fixture explicitly asserts that its unprepared AVURLAsset exposes
no video tracks before confirming successful fallback. Two additional HLS
playlists reference media segments whose server accepts connections but sends no
bytes. Their timeout/cancellation tests observe actual socket closure, in
addition to the original stalled-asset tests. All four connections close within
two seconds; exact measurements are in the new local report and HTTP event log.

These checks establish metadata extraction and local cancellation/resource
release behavior. They do not establish perceptual quality, end-to-end playback,
remote-provider availability, every HLS variant, or the rendition selected later
by a player. No complete movie is decoded, and duration/playability are not
required to load metadata.
