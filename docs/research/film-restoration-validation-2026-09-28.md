# 真实影片恢复测量协议

日期：2026-09-28。本工具对同一段 4 秒、96 帧、24 FPS 的真实电影画面比较原片、冻结的 v0.3.1 清晰模式、新的时域处理、Apple AI 超分及“时域＋Apple AI”。素材为 Blender Foundation《Tears of Steel》，[CC BY 3.0 与署名要求](https://mango.blender.org/sharing/)，署名 **(CC) Blender Foundation | mango.blender.org**；720p MOV 第 62 秒开始的 4 秒，无音频。本地输入为 `.build/restoration-lab/clean-film.mp4`（960×400）、`compressed-film.mp4` 和 `noisy-film.mp4`（480×200）。报告保存输入 SHA-256。目录内的 `copyright.txt` 涉及 soundtrack，不能据此代替视频许可页面。

运行：

```sh
FILM_VALIDATION_COMPILE_ONLY=1 bash scripts/validate-restoration-film.sh
bash scripts/validate-restoration-film.sh docs/validation/restoration-film/report.json .build/restoration-lab
```

脚本独立使用 `swiftc`，不共享 SwiftPM 构建状态。需要 Apple Silicon、macOS 26 和受支持的 VideoToolbox 时域滤波；设备不支持或时域分支完全未生效时退出失败，不悄悄将原片当修复成功。

## 公平比较

- **原尺寸**：将 clean 参考以明确的 Lanczos 核缩小至 480×200，各候选仍在 480×200 测 RGB PSNR。各候选没有独立放大步骤，分数差异不混入“缩放器不一样”的影响。clean 的缩小核与退化生成时的缩小核若不同，会形成共同的参考误差，所以绝对 PSNR 不能视作严格数据集基准。
- **同展示尺度**：将每个候选已落地的处理结果，都用同一种正权重 B-spline（B=1,C=0）适配至 960×400，再与 clean 比较。此分数包含缩放误差，与原尺寸分数分开报告。Apple AI 使用生产管线实际查询的倍率，处理尺寸单独记录；含 AI 的重建本来就改变采样栅格，不把其回采样指标冒充“纯降噪”分数，只提供同展示尺度对比。
- **冻结旧版**：v0.3.1 clarity 独立复现 `CINoiseReduction(noiseLevel=0.015,sharpness=0)`，避免当前生产管线变化使旧版基线漂移。新时域直接链接生产 `TemporalRestorer`，强度 0.75。
- **动态时间误差**：统计 `((output[t]−output[t−1])−(clean[t]−clean[t−1]))²` 的均值及 RMSE，覆盖所有 95 对相邻帧。它比较相对于真实运动的时间变化误差，而不是把任何画面运动当闪烁。没有光流补偿；在对应 PTS、对应像素上作时间导数保真检查，不能单独证明无拖影。
- **颜色**：三个候选和参考由同一 Core Image 色彩配置转为 8-bit sRGB；指标仅 RGB、排除 alpha。这里只测 SDR。

## 无未来帧的实质执行检查

`AVAssetReader` 顺序提供当前退化帧，时域处理完成后才请求下一退化帧。工具断言在处理第 n 帧时仅向应用交付 n+1 帧；clean 参考只进入测量函数，不进入恢复器。生产恢复器的 `nextFrames=[]`、`previousFrames=[previous]` 表示当前 API 只传入一张历史原始帧。报告记录历史生效次数和所有重置原因。

这证明测试调用没有把未来图像提供给恢复器，不能声称审计了 AVFoundation 解码器的内部预读或 Apple 算法实现。压缩视频解码 B 帧自身可能需要内部重排序，这和恢复器的未来帧输入是两件事。

## 输出与证据边界

输出 compact JSON，以及每类退化第 24 帧的五个候选和一张 clean，两个变体共 11 张、含可选强噪声变体时共 16 张 960×400 PNG。记录每帧完成各自处理尺寸像素落地的耗时，包含处理和 RGBA 读回，不含解码、指标循环、共同展示缩放与保存 PNG；各模式顺序执行，因此不是严格随机化速度比较，更不是播放器最终帧率。

脚本通过只表示素材对齐、96 帧完整处理、时域实际生效、指标成功计算。**没有预设新算法必须赢的阈值**；如果新模式 PSNR 或动态误差更差，应据实呈现并判断是否保留原片。4 秒单场景不代表各种电影效果，也不能证明 4K 实时、长期温控或字幕完全正确。

## 后续加入烧录字幕的方式

建议从同一 clean 片段复制一个专用测试版本，在退化前合成固定中文、英文、数字及细边缘描边字幕，保存透明 alpha 遮罩；同一字幕分别保持 12 帧、切换文本、突然消失，并放到运动背景上。字体、字号、位置、采样尺度必须进入生成清单。

在相同输出栅格上单独测：笔画前景召回率、笔画外新增亮边/错误像素率、字幕边缘位移、字幕出现/消失后的残留帧数；分开计算字幕 ROI 与其外背景误差。OCR 字符准确率可作附加指标，但不能替代像素和笔画指标。外挂字幕的正确路线仍是在恢复之后合成，不能让算法重画文字。

本次现有真实影片片段未额外加入可精确测量的字幕遮罩，因此不将该实验报告作字幕保真验收。

## 素材重建参数

本轮生成参数为：原始 720p MOV 截取 62–66 秒，24 FPS、96 帧，缩至 960×400、H.264 CRF16 得到 clean；再以 bicubic 缩至 480×200、CRF34 生成压缩版本；另一路加入 `noise=alls=4:allf=t+u`，CRF30 生成带噪版本。原命令未明确设置噪声种子，故即便照参数重建，也不能宣称文件或像素与本次输入逐位一致；报告中的 SHA-256 是本轮输入的精确身份。

来源：[Blender 官方 720p MOV](https://download.blender.org/demo/movies/ToS/tears_of_steel_720p.mov)，[官方目录](https://download.blender.org/demo/movies/ToS/)。以下命令用于另一个输出目录，避免覆盖本轮有 hash 的输入；需要 FFmpeg。它们表达相同生成流程，不承诺跨 FFmpeg 版本或未固定噪声种子的逐位重现。

```sh
mkdir -p .build/restoration-film-regenerated
ffmpeg -ss 62 -i https://download.blender.org/demo/movies/ToS/tears_of_steel_720p.mov -t 4 -an \
  -vf 'scale=960:400,fps=24' -frames:v 96 -c:v libx264 -crf 16 -pix_fmt yuv420p \
  .build/restoration-film-regenerated/clean-film.mp4
ffmpeg -i .build/restoration-film-regenerated/clean-film.mp4 -an \
  -vf 'scale=480:200:flags=bicubic' -frames:v 96 -c:v libx264 -crf 34 -pix_fmt yuv420p \
  .build/restoration-film-regenerated/compressed-film.mp4
ffmpeg -i .build/restoration-film-regenerated/clean-film.mp4 -an \
  -vf 'scale=480:200:flags=bicubic,noise=alls=4:allf=t+u' -frames:v 96 -c:v libx264 -crf 30 -pix_fmt yuv420p \
  .build/restoration-film-regenerated/noisy-film.mp4
ffmpeg -i .build/restoration-film-regenerated/clean-film.mp4 -an \
  -vf 'scale=480:200:flags=bicubic,noise=alls=12:allf=t+u:all_seed=7' -frames:v 96 -c:v libx264 -crf 24 -pix_fmt yuv420p \
  .build/restoration-film-regenerated/heavy-noisy-film.mp4
```

强噪声分支使用显式种子 7；脚本仅在素材目录存在 `heavy-noisy-film.mp4` 时增加这组测试，同时保留压缩和轻噪声两组，不按结果好坏筛选场景。

## 2026-09-28 实测结果

独立编译与 GPU 顺序执行已完成；最终三组报告位于 `docs/validation/v0.3.2/film-restoration/report.json`，16 张样本 PNG 位于同名 `report.frames` 目录。初次两组报告 `initial-two-variants.json` 保留首次模型冷启动证据。每个变体完整处理 96 帧、95 对时间差；时域处理 94 帧使用历史，第 0 帧和第 59 帧切镜时重置。已检查输出样本 PNG 可正常显示，尚未进行动态片段盲看。

| 退化 | 模式 | 原尺寸 PSNR dB ↑ | 960×400 PSNR dB ↑ | 960×400 时间导数误差 RMSE ↓ |
| --- | --- | ---: | ---: | ---: |
| 压缩 CRF34 | 原片 | 31.374 | 30.796 | 2.905 |
| 压缩 CRF34 | v0.3.1 清晰 | 31.338 | 30.721 | 2.901 |
| 压缩 CRF34 | 时域 | 31.367 | 30.759 | 2.912 |
| 压缩 CRF34 | Apple AI | 不作纯降噪比较 | 31.153 | 2.946 |
| 压缩 CRF34 | 时域＋Apple AI | 不作纯降噪比较 | 31.129 | 2.933 |
| 带噪 CRF30 | 原片 | 32.030 | 31.267 | 2.744 |
| 带噪 CRF30 | v0.3.1 清晰 | 32.019 | 31.202 | 2.742 |
| 带噪 CRF30 | 时域 | 32.101 | 31.285 | 2.773 |
| 带噪 CRF30 | Apple AI | 不作纯降噪比较 | 31.665 | 2.706 |
| 带噪 CRF30 | 时域＋Apple AI | 不作纯降噪比较 | 31.706 | 2.726 |
| 强噪声 CRF24 | 原片 | 33.265 | 32.346 | 2.819 |
| 强噪声 CRF24 | v0.3.1 清晰 | 33.457 | 32.345 | 2.728 |
| 强噪声 CRF24 | 时域 | 33.503 | 32.431 | 2.733 |
| 强噪声 CRF24 | Apple AI | 不作纯降噪比较 | 32.770 | 2.770 |
| 强噪声 CRF24 | 时域＋Apple AI | 不作纯降噪比较 | 32.881 | 2.666 |

结论是**小幅、混合收益**：时域模式在轻噪输入原尺寸约增加 0.071 dB，但并未改善所有时间误差；压缩输入 PSNR 没有超越原片。组合模式相对 Apple AI 在压缩、轻噪输入分别约 −0.024 dB 和 +0.040 dB。强噪声输入中，时域原尺寸约增加 0.238 dB；同展示尺度组合相比原片约增加 0.535 dB、相比单独 AI 约增加 0.111 dB，时间导数误差 RMSE 从原片 2.819 降至 2.666。应保留全部三组结果，不能只挑强噪声数据宣布普遍更好；宜保持可选及原片对照，**不默认强制启用**。三个变体的 CRF 不相同，不能横跨组分数判断“加噪使画面变好”。

Apple AI 实际选择 ×4，将 480×200 处理为 1920×800；指标再统一至 960×400，**不是 4K 实测**。初次运行的 AI 冷启动第一帧约 1192 ms，保留在 `initial-two-variants.json`，不能被随后暖缓存运行抹去。最终三组的 AI 稳态约 5.3–5.5 ms；组合稳态约 8.0–8.1 ms（p95 约 9.3–9.8 ms）。这些是小尺寸、四秒输入且排除解码/共同展示缩放/指标循环的处理耗时；模型预热、长片内存和完整播放流畅度需要另外验证。
