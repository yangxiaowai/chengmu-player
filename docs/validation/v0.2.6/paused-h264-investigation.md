# Paused H.264 preparation investigation

No product change was made. The first native validation-harness cold start stayed unknown/preparing until the tester pressed Play; its absolute-path and window-task revision did not alone resolve this. This remains a harness cold-start limitation, not a verified player defect.

Independent real AVFoundation checks used the identical `.build/seek-preview-ui.mp4` (H.264, 90 seconds):

- Controller open(resume: 3) followed synchronously by pause reached ready at actual/visible 3 seconds, rate 0, playback intent false and loading false.
- The same sequence with an attached AVPlayerLayer also reached item status 1 (readyToPlay) at 3 seconds while paused. `paused-h264-layer-probe.json` contains numeric status evidence. The later explicit Play probe advances normally.
- Actual AppModel resume(record at 3) followed immediately by pause, then paused switchLine to a second matching line, repeated eight times. All 16 checkpoints reached ready at actual 3 seconds, rate 0, intent false and loading false. See `paused-h264-appmodel-probe.json`.
- Separate metadata-load/direct-seek exploratory probes were unnecessary: each item had already prepared before those probes were issued. They are not evidence of a required fix.

Parent's native QA additionally exercised delayed alternative-source detail/playlist selection while paused at 31 seconds; the replacement was ready, still at 31 seconds and still paused. This native result is parent-observed rather than produced by the independent headless harness.

No preroll, buffer setting, network setting, UI or controller change was introduced. The local SDK explicitly requires AVPlayer.status readyToPlay and rate zero before preroll; blindly adding it during unknown preparation could throw an exception. The published player's paused H.264 replacement path has positive headless and native evidence, while the validation application's initial cold-start behavior remains separately bounded.
