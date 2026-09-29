# 候选实验复现

这些脚本为本轮 CPU 探索归档，最终生产结论以完整 GPU 管线报告为准。guided/probe.py、constrained/probe.py 与 direction_check.py 中保留原输出路径，默认重新运行会写 `.build/repair-v036`；归档报告不会被覆盖。

使用现有本地 `.build/restoration-lab` 四份影片。文件哈希在 fixture-manifest.json；影片生成方法和 CC BY 3.0 署名在 `docs/research/film-restoration-validation-2026-09-28.md`。不自动联网下载。

```sh
mkdir -p .build/repair-v036
swiftc -O -parse-as-library -swift-version 5 -target arm64-apple-macos15.0 Sources/CinemaApp/TemporalRestorer.swift docs/validation/v0.3.6/candidate-probes/export-temporal.swift -o .build/repair-v036/export
.build/repair-v036/export .build/restoration-lab .build/repair-v036/post-temporal
# Synthetic-only is self-contained; no film assets needed:
bash scripts/validate-compression-cleaner.sh /tmp/cleaner-synthetic.json
# Optional historical five-frame measurements (not complete pipeline):
bash scripts/validate-compression-cleaner.sh /tmp/cleaner-with-film.json green .build/repair-v036/post-temporal
```

导出图为 480×200、top-down RGBA、little-endian float32、sRGB 编码值，可能包含扩展 SDR 越界值。所有比较方使用同一最终裁剪，不能只裁剪候选。生产时域默认强度 0.75；全部 96 帧顺序处理，仅保存事先指定 12/24/48/72/84。

所有 GPU 脚本串行运行，避免与播放器、本机自检或其他测试竞争。不同测量路径（直接浮点回读、再物化 half texture、最终 RGB10 输出）的微小误差不可混成同一个画质结果。
