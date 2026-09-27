# Playback stability validation

The change derives loading state from the current AVPlayerItem status, playback intent, live transport status, pending seek and fatal error. Published `loadingMessage` distinguishes preparation, seeking and buffering. `recoverySuggested` becomes true after a continuous 15-second wait and clears when the wait finishes or the item changes. It only suggests user recovery; it does not retry, switch lines or change network/buffer preferences.

Fatal item/failed-to-end handling now cancels the pending operation, pauses physical playback, clears play intent and preserves the first pending resume/seek destination (including zero) in an optional failure target for explicit retry. A separate read-only `hasPlaybackFailure` survives dismissing the error text and resets on opening the next item. Pressing Play in that lifecycle explicitly runs the existing retry operation, even after the error text is dismissed. End events must match the current item and seek generation, have no pending seek, and have actual media time within 0.5 seconds of a finite positive duration. Normal EOF and manual replay continue to work.

## Evidence

- `playback-stability-baseline.json`: original controller issues. Stall and failure notices were injected; EOF/seek-back race used an actual local-media EOF notification.
- `playback-preparation-failure-baseline.json`: the new 52-second preparation-failure regression failed before preserving retry intent. The loopback server first withheld bytes, then served generated WAV on explicit retry; failure notification was injected.
- `playback-dismissed-failure-baseline.json`: dismissed error text caused explicit Play to reuse the failed item before the lifecycle marker fix.
- `playback-repeated-failure-baseline.json`: duplicate injected failure notices during preparation overwrote the retained 52-second target before prioritizing the optional first-failure target.
- `playback-stability-headless.json`: 13/13 checks passed after the fixes, including real EOF/seek race, ordinary EOF/manual replay, pause/failure preventing next, preparation-failure retry with duplicate fatal events, dismissed-error replay, zero-second destination retry, real pending loopback load exceeding 15 seconds, and replacement clearing the wait suggestion.
- `playback-policy-tests.txt`: 5/5 pure Swift Testing tests passed, covering state precedence, EOF boundaries and the recovery threshold.
- `playback-controller-smoke.txt`: existing controller smoke passed, covering preference bounds, subtitles, paused retry, preparation retry and fatal-error manual recovery.
- `playback-responsiveness.json`: existing eight cases passed, including 32 yielding skip bursts, newest seek, canceled seek, rapid pause/play and replacement-item isolation.

The zero-second test sends a real controller seek to zero immediately before an injected fatal notice and verifies the rebuilt item resumes at zero; it does not assert the precise ordering of AVPlayer seek completion.

All compilation was independent Swift 5 / arm64 macOS 15 compilation with a temporary CinemaCore module. No app-wide SwiftPM build or test was invoked by this validation. Native UI, real provider outages and network transport failure are not claimed by these headless results. Parent handles final app bundle and native acceptance.

## Reproduction

Run `scripts/validate-playback-stability.sh` from the checkout. It generates its own local WAV, serves a private loopback fixture with a bounded withheld response, compiles into a temporary directory, saves the JSON report and releases its server/compiler artifacts. Requires the installed Swift toolchain and Python 3; no FFmpeg or downloaded media is needed.
