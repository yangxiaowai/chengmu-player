# Isolated native research evidence

These small Swift sources and JSON files were copied from `.build/native-optimization-probe/` after the September 29 experiments. No model, video, compiled binary, or large image is included. The corresponding interpretation, official references and scope limits are in `docs/research/realtime-restoration-design-2026-09-29.md`.

- `sr-capabilities*`, `scale-two-query.swift`: read-only VT configuration/model readiness queries. No model download invocation.
- `model-size.json`: sanitized system asset catalog metadata, not a network transfer measurement.
- `quality-sr.swift` / `quality-sr-results.json`: native high-quality ×4 first + 3 sequential frames per supported tested resolution; callback and final command completion. 1080p omitted after lower resolutions exceeded real-time budgets. Display pixels in this initial test are invalid because native output alpha is NaN.
- `quality-sr-alpha*`: actual **2-frame** 640×360 input diagnostic. Its inherited top-level `scope` text says first+3; the frame rows are authoritative. Raw output is RGBAHalf. The `raw_min/max` alpha extrema remain initialization sentinels because all sampled alpha values were NaN. RGB samples are finite. CI alpha replacement after import did not repair it.
- `quality-sr-sanitize*`: actual **1-frame** diagnostic, despite the same inherited scope text. Directly writes Float16(1) to the output pixel buffer's alpha before importing into Core Image. Subsequent alpha=255 and nonzero RGB prove that the model RGB output exists. This CPU repair is diagnostic, not production code or a real-time proposal.
- `scaler-capabilities*`: MetalFX spatial format/configuration queries.
- `spatial-upscale*`: one synthetic 1080p→4K step/noise fixture, first+3 completed GPU frames, no temporal denoising. No universal image-quality conclusion.

The sources use working-directory-relative `.build/native-optimization-probe/` output names; recreate that folder before reproducing. Compile independently with `swiftc -O <source.swift> -o <temporary binary>`. The reported machine was Apple M4 with macOS 27. Run GPU measurements alone; do not overlap with playback, other enhancement probes or model inference. High-quality sessions take seconds to initialize and hundreds of milliseconds per frame.
