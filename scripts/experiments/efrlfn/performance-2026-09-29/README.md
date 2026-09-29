# EfRLFN exact graph / device experiment — 2026-09-29

Offline experiment only. No production integration, downloads, package installations,
input downsampling, tiling, pruning, quantization change, or retraining. The three
rewrites preserve the original x2 network function. License and pinned provenance
are in `../EfRLFN-LICENSE.txt` and `../upstream-manifest.json`; the converter uses the
unchanged hash-checking `../convert.py` loader before reading official weights.

`results/` retains conversion parity, complete-frame timings, raw per-operation
MLComputePlan device support/preference/relative cost, and summaries. Large temporary
models/images/references remain in `.build/restoration-performance-2026-09-29/`.
MLComputePlan costs are predictions, not measurements of device utilization.

## Reproduce from repository root

Existing environment: `.build/restoration-venv/bin/python`, torch 2.7.0,
coremltools 9.0, NumPy, Pillow. Swift 6 SDK / macOS 27 / Apple M4 were used.
Do not run these probes concurrently with another GPU/ANE workload.
The converters refuse an existing model output; use a fresh artifact directory.
No script downloads the input model, source, or movie fixture.

```sh
experiment_scripts=scripts/experiments/efrlfn/performance-2026-09-29
experiment_artifacts=.build/restoration-performance-rerun
mkdir -p "$experiment_artifacts"
swiftc -O -parse-as-library "$experiment_scripts/plan.swift" -o "$experiment_artifacts/plan"
swiftc -O "$experiment_scripts/probe.swift" -o "$experiment_artifacts/probe"
swiftc -O scripts/experiments/efrlfn/render.swift -o "$experiment_artifacts/render"
for experiment_variant in baseline eca2d toeplitz padded64; do
  .build/restoration-venv/bin/python "$experiment_scripts/convert_optimized.py" \
    --upstream .build/restoration-lab/efrlfn-upstream \
    --weights .build/restoration-lab/efrlfn-x2.pt \
    --directory "$experiment_artifacts" --variant "$experiment_variant" \
    --fixture .build/restoration-lab/compressed-film-24.png
done
.build/restoration-venv/bin/python "$experiment_scripts/convert_optimized.py" \
  --upstream .build/restoration-lab/efrlfn-upstream \
  --weights .build/restoration-lab/efrlfn-x2.pt \
  --directory "$experiment_artifacts" --variant baseline --width 1920 --height 1080
.build/restoration-venv/bin/python "$experiment_scripts/verify_coreml.py" \
  --prepare --artifacts "$experiment_artifacts" --results "$experiment_artifacts/results" \
  --upstream .build/restoration-lab/efrlfn-upstream \
  --weights .build/restoration-lab/efrlfn-x2.pt \
  --fixture .build/restoration-lab/compressed-film-24.png
python3 "$experiment_scripts/run_benchmarks.py" \
  --artifacts "$experiment_artifacts" \
  --baseline "$experiment_artifacts/baseline-1280x720.mlpackage" \
  --baseline1080 "$experiment_artifacts/baseline-1920x1080.mlpackage" \
  --results "$experiment_artifacts/results" \
  --parity-fixture "$experiment_artifacts/parity-720.png"
.build/restoration-venv/bin/python "$experiment_scripts/verify_coreml.py" \
  --artifacts "$experiment_artifacts" --results "$experiment_artifacts/results"
python3 "$experiment_scripts/summarize.py" "$experiment_artifacts/results"
```

`--fixture` can be any locally available RGB image. The retained conversion records
use the documented previous public film fixture. The actual Core ML parity input is
that still image resized to 1280×720 to test a full-sized fixed-shape model. It is not
a quality benchmark or a speed trick: prediction processes every 720p input pixel and
outputs 2560×1440; no resize is included in the timed inference path.

## What is timed

`probe.swift` renders a CI image in the explicit sRGB transfer domain to an
IOSurface-backed BGRA input, synchronously predicts, then renders the resulting
sRGB CVPixelBuffer into a Metal BGRA texture and waits for command completion.
One first-frame and three warm-frame timings are retained. Pixel hashing occurs
outside timing; same-input first/last outputs match in every test. Compile/load time
is separate. No decode, media-clock scheduling, audio, or sustained thermal run is
included, so these are not playback FPS measurements.

## Exact rewrites

- `eca2d`: ECA `[B,1,C]` Conv1D becomes `[B,1,C,1]` Conv2D with a `(3,1)` kernel.
  Removes squeeze/expand operations, retains two transposes per block.
- `toeplitz`: three learned neighboring-channel taps become a sparse 52×52 pointwise
  matrix applied after global pooling. Removes all ECA transposes.
- `padded64`: the Toeplitz variant plus all 52-wide feature tensors expanded to 64,
  with zero input/output weights and biases in the added planes. Extra feature
  planes remain zero through tanh, residuals and attention; no new scene content is
  introduced. Tested to evaluate backend alignment; it was slower.

FP32 parity covers random 64×64 plus a compressed film 480×200 still. Completed
Core ML x2 outputs from the three rewrites were byte-identical for the selected
720p still, with ~0.266 RGB8 code mean error from the original CPU FP32 network.
This establishes conversion consistency on these fixtures, not restoration quality
across movies or temporal stability.
