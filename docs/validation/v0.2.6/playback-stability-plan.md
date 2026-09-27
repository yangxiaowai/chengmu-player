# Playback stability scope

Read-only baseline used the real current PlaybackController, a generated silent 120-second local WAV, and an existing CinemaCore build. Product files were unchanged during baseline capture.

1. A stall notification delivered after pause left `isLoading=true`, although playback intent was false and actual AVPlayer rate was zero. This notification was injected to exercise the delayed-event handler; no network stall is claimed.
2. An injected failed-to-end notification set the fatal error while playback intent and physical playback remained active. The notification was injected; a real network transport failure is not claimed.
3. A real local-media EOF notification was followed synchronously by seeking back to 20 seconds, before the controller's delayed MainActor handler. `onFinished` still ran and playback intent became false at the new 20-second position. No EOF notification was injected in this case.

Bounded change: derive preparation, seeking and buffering indicators from the current item/transport/intent/error state through one pure policy; publish `loadingMessage` and suggest manual recovery after a continuous 15-second wait. Retain the existing 12-second buffer preference and all network settings. Do not automatically retry or switch sources. Stabilize fatal failures by canceling pending seek state and pausing explicitly. Accept EOF only when its item and latest seek generation match, no seek is pending, and actual media time is close to a valid duration. Normal EOF replay and paused/manual retry must continue to work.

Validation: pure state/EOF policy tests; a targeted real-controller smoke for paused stall, terminal failure, real EOF/seek race, ordinary EOF/replay, and waiting/recovery cancellation; existing playback-controller and responsiveness smokes. These are headless tests, not native UI or remote playback verification.
