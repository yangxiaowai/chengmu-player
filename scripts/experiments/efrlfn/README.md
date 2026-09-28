# EfRLFN x2 / Core ML reproducibility experiment

This is an **evaluation tool, not a production playback dependency**. It does not download weights, install packages or alter the app. On the current M4, even the fixed 720p model completed in about 105–112 ms per warm frame, so it was not added to the real-time player. Fixed 1080p → 4K was about 307–309 ms. See the [recorded results](../../../docs/research/mac-restoration-options-2026-09-28.md).

## Provenance

- Official repository: <https://github.com/EvgeneyBogatyrev/EfRLFN>
- Pinned source commit: `1f7f3678f1bd7ba04ca8ccb04726eef71bf8520a`.
- Paper: *Exploring Real-Time Super-Resolution: Benchmarking and Fine-Tuning for Streaming Content*, ICLR 2026, <https://arxiv.org/abs/2602.11339>.
- Official x2 weights: [author-provided Google Drive file](https://drive.google.com/file/d/1VeoW94hN1X-8kxGXQSyR53YzRqF1htKQ/view).
- Tested checkpoint: 1,968,047 bytes; SHA256 `fbfd1bb37973d2b8b53493c5b91c0ef106f74d200115250a8a025b8e6a121cb3`.
- Upstream license: MIT, Copyright (c) 2026 MSU Graphics & Media Lab, copied in [EfRLFN-LICENSE.txt](EfRLFN-LICENSE.txt).
- Exact source hashes are in [upstream-manifest.json](upstream-manifest.json); conversion checks them before loading definitions. There is no automatic network access or unverified `torch.load`: checkpoint loading uses `weights_only=True` and strict state-dict matching.

The tested Python environment was Python 3.13.3, torch 2.7.0, coremltools 9.0, NumPy 2.4.6, Pillow 12.2.0. A Python environment with these dependencies must be supplied explicitly. Core ML outputs target macOS 15+, FP16, RGB8 image input/output. No Python is required to run the Swift probe after conversion.

## Conversion

Obtain the pinned source and checkpoint into an experiment directory first. Required source files are `code/model.py`, `code/blocks.py`, `code/utils.py`, and `LICENSE`. The upstream `code` package conflicts with Python's stdlib, so the converter loads only those hash-verified definitions under isolated names.

```bash
# From the repository root; this example reuses the already prepared local environment.
.build/restoration-venv/bin/python scripts/experiments/efrlfn/convert.py \
  --upstream .build/restoration-lab/efrlfn-upstream \
  --weights .build/restoration-lab/efrlfn-x2.pt \
  --width 1280 --height 720 \
  --output .build/restoration-lab/efrlfn-1280x720-repro.mlpackage
```

Omit width and height to generate the dynamic version (width 64–1920, height 64–1080, default 64×64). Do not equate dynamic and fixed model performance: the dynamic model was substantially slower away from its default shape on this machine. Existing output paths are rejected, not overwritten. Each new model has a sidecar manifest containing versions, source and checkpoint provenance, image scaling, and output file hashes.

Model input is **sRGB-encoded RGB / 255**, not linear RGB; output is clamped RGB scaled by 255 for Core ML's RGB8 image output. This is a SDR-only experiment. It must not be used for PQ/HLG/HDR or unspecified color handling.

## Complete-frame timing

```bash
xcrun swiftc -O scripts/experiments/efrlfn/probe.swift -o .build/restoration-coreml-probe/repro-probe
.build/restoration-coreml-probe/repro-probe \
  .build/restoration-lab/efrlfn-1280x720-repro.mlpackage \
  .build/restoration-coreml-probe/repro-720 all 1280x720
```

Arguments: model package, output directory, `all` or `gpu` (`CPU_AND_GPU`), optional `WIDTHxHEIGHT`. With no dimensions it tests 64×64, 480×200, 960×400, 1280×720, 1920×1080; use a dynamic model for that sweep. Fixed models must receive their exact dimensions. The probe performs one initial frame plus four warm frames per shape, synchronous Core ML prediction and completed Metal rendering. It records compile/load separately; output dimensions must be exactly 2×, and first/last output pixel hashes verify same-frame repeatability. CPU readback for hashing is outside the timed interval. The input stays at its natural resolution: no internal downscaling and no tiling.

These short probes do **not** test sustained playback, audio sync, decode throughput, power, thermal behavior or temporal quality. Repeated identical output is not evidence that moving video is flicker-free. Do not translate the timings into a promised playback fps.

## RGB numerical parity / real-frame inspection

```bash
xcrun swiftc -O scripts/experiments/efrlfn/render.swift -o .build/restoration-coreml-probe/repro-render
.build/restoration-coreml-probe/repro-render \
  .build/restoration-coreml-probe/EfRLFN2-fixed480.mlpackage \
  .build/restoration-coreml-probe/repro-images \
  .build/restoration-lab/compressed-film-24.png
.build/restoration-venv/bin/python scripts/experiments/efrlfn/reference.py \
  --upstream .build/restoration-lab/efrlfn-upstream \
  --weights .build/restoration-lab/efrlfn-x2.pt \
  --input .build/restoration-lab/compressed-film-24.png \
  --output-prefix .build/restoration-coreml-probe/repro-images/compressed-reference \
  --coreml-output .build/restoration-coreml-probe/repro-images/compressed-film-24-coreml.png
```

`render.swift` converts the supplied SDR image through a linear-working-space `CIContext` **into an explicitly sRGB BGRA pixel buffer** before prediction, and interprets the result as sRGB. It does not copy each pixel through a Swift CPU loop. `reference.py` runs the original network in CPU FP32 and reports absolute RGB code error; it verifies conversion, not whether restored detail matches the lost scene. Our two real-frame checks had mean absolute errors near 0.265/255 and maximum error below 1.1/255.

EfRLFN uses global channel attention. Tiling would change its global pooling statistics; a larger overlap does not make the tiled algorithm mathematically equivalent to full-frame inference. This experiment deliberately uses full frames.
