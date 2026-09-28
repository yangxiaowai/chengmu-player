# Apple 原生时域修复能力探针（2026-09-28）

本轮目标是降低噪声，同时保留运动边缘、细纹理与字幕笔画。只加空间模糊容易抹掉细节；Apple 的时域降噪利用运动估计和相邻帧，适合优先验证。本记录先区分设备能力查询和真正执行结果，生产接入验证结果另附。

## 已核实的一手依据

- [WWDC25：Enhance your app with machine-learning-based video effects](https://developer.apple.com/videos/play/wwdc2025/300/)：原生时域降噪可以服务实时和编辑场景；低延迟超分偏向视频会议，高质量超分偏向视频编辑；`VTMotionBlur` 是增加运动模糊效果，不是视频去模糊修复。
- [VTTemporalNoiseFilterConfiguration](https://developer.apple.com/documentation/videotoolbox/vttemporalnoisefilterconfiguration)：运行时查询支持与输入格式，不以 macOS 版本单独认定能力。
- [VTTemporalNoiseFilterParameters](https://developer.apple.com/documentation/videotoolbox/vttemporalnoisefilterparameters)：至少一个过去或未来参考帧；强度 0–1；`hasDiscontinuity` 重置处理器状态。可不提供未来帧，故不必延迟两帧等待。
- [VTSuperResolutionScalerConfiguration](https://developer.apple.com/documentation/videotoolbox/vtsuperresolutionscalerconfiguration)：应先检查模型下载状态；设备支持不代表模型已就绪。
- [VTFrameProcessor](https://developer.apple.com/documentation/videotoolbox/vtframeprocessor)：输入和输出在完成回调之前不得修改。以下测试等待真实完成回调，并读取输出像素。
- 同时核对本机 SDK 的 `VTFrameProcessor_TemporalNoiseFilter.h`、`VTFrameProcessor_SuperResolutionScaler.h`、CoreVideo `CVPixelBuffer.h`。SDK 描述与 Swift 导入形式存在差异：本机 `minimumDimensions`、`maximumDimensions`、`previousFrameCount`、`nextFrameCount` 是可选值，不能假定总能读取。

## 本机能力查询

设备 Apple M4，macOS 27.0 (26A428)。时域降噪、光流、运动模糊、高质量超分、低延迟超分均报告支持。时域降噪报告最小 160×64，最大 16384×8192；测试 640×360、1280×720、1920×1080、3840×2160 的配置均成功，但这里只对 720p/1080p 执行了连续帧质量和性能测试。

时域配置最多可用过去 1 帧与未来 2 帧，**本轮实时候选只用过去 1 帧，未来 0 帧**。实际支持的是压缩 IOSurface YUV 格式，包括公开常量 `kCVPixelFormatType_Lossless_420YpCbCr8BiPlanarFullRange` (`&8f0`) 和 10-bit 对应的 `&xf0`，不是直接把 BGRA 缓冲传给算法。本机支持列表共 16 项，含无损和有损变体；生产只能选择无损变体。

高质量 `VTSuperResolutionScalerConfiguration` 在本机只报告 4×，640p/720p/1080p 视频配置创建成功，但模型状态均为 `downloadRequired`（0%），输入格式为 RGBA Half。**没有触发模型下载，没有执行高质量超分，因此没有该路径画质或速度结论。** 与已有 `VTLowLatencySuperResolutionScalerConfiguration` 路径是不同处理器。

## 隔离探针：真实完成及质量结果

独立 `swiftc -O`，不使用应用或共享 SwiftPM 构建。源文件及原始 JSON 在 `.build/restoration-native-probe/`，不访问用户影片/偏好。合成连续 18 帧；每配置真正处理 15 帧；独立均匀 RGB 噪声 ±15 个 8-bit 值，含暗区、平移矩形、3px 明暗细纹、在第 8 帧切换位置的字幕形状。对照真值也经过相同 YUV 转换，避免把颜色转换误差计作降噪效果。空间对照是现用 `CINoiseReduction(noiseLevel: 0.015, sharpness: 0)`。

下面是因果模式、强度 0.75、第 8 帧的 RGB MSE；越低越接近合成真值，不代表真实电影主观观感评分。

|尺寸/区域|原始噪声帧|现有空间降噪|原生时域降噪|
|---|---:|---:|---:|
|720p 暗平区|53.25|23.65|26.43|
|720p 运动区|52.85|49.82|14.35|
|720p 细纹|52.39|51.80|23.18|
|720p 切换字幕|54.65|39.36|27.81|
|1080p 暗平区|52.85|23.30|18.29|
|1080p 运动区|52.48|49.51|16.69|
|1080p 细纹|53.14|52.51|25.20|
|1080p 切换字幕|52.74|35.67|31.61|

720p 暗平区并非每帧优于空间降噪，不能宣传全面碾压。此次强度 0.75 的运动、细纹和字幕区域优于空间对照。0.25/0.5/0.75 均运行过，强度与误差不是简单单调关系，选择 0.75 依据是这些样本的整体表现。

两种分辨率第 1/8/15 帧字幕前景召回均为 100%，字幕附近背景误点亮为 0；这是针对合成粗笔画、阈值分割的检验，不能代表所有实际细小或彩色字幕。无噪声的 720p 控制组上述三帧与原图各区域 MSE=0；未观察到该样本被无谓柔化。

|因果模式|时域处理完成均值（热机）|输入格式转换均值|首次处理|
|---|---:|---:|---:|
|720p|约 4.35 ms|约 0.61 ms|约 15–18 ms|
|1080p|约 8.63 ms|约 1.21 ms|约 19–21 ms|

计时等待 `process(parameters:completionHandler:)` 的完成回调；这些是框架真实处理完成的墙钟时间，**不是仅 CPU 提交时间，也不能称为 GPU-only 时间**。不包含解码、网络、显示、播放器线程调度及最终 4K 缩放。不据此承诺实际影片持续 60fps。使用未来两帧的样本也执行过，质量有所提高但需要等待未来帧，不纳入当前实时接入。

额外从 0.033s 跳到 100.1s：清空旧参考，第一张新帧只用于建立参考，第二张新帧 `hasDiscontinuity=true`。复用会话与全新会话输出逐像素相同（max diff 0、MSE 0）。

## 最小接入方案

1. 在已有串行增强 worker 中保留单个原生时域会话；输入必须已通过现有 SDR/HDR gate 并转为正确显示方向。
2. 使用当前帧与上一张**源帧**；不把修复输出递归喂回参考，不取未来帧、不修改音频时间轴、不建立第二条解码链。
3. 单独保留原图作为首次、seek、切镜、设备/格式不可用时的原始观感基准。`usedHistory=false` 不可标作“时域处理完成”。
4. `streamID` 改变、PTS 倒退/重复/大间隔、尺寸变化、显著切镜或大范围快速运动时丢弃参考。场景保护使用低分辨率 RGB 差作保守门限；它是避免明显串帧的防线，不是通用光流或完美切镜识别。
5. 把处理完成时间计入现有帧预算。保留原片对照、HDR 原生输出、广告扫描共享帧、字幕和广告柔化的原有边界。
6. 验证生产封装时采用 16-bit 浮点 RGB 中间帧和无损压缩 10-bit YUV，避免新增 8-bit 中间量化；单独检查色偏、曝光、运动、字幕切换及重置。当前播放器最终输出格式属于主管线范围，不在本模块擅自修改。

## 生产封装后重复验证

新增 `Sources/CinemaApp/TemporalRestorer.swift`，没有改动主管线文件。接口为 `TemporalRestorer(width:height:context:strength:)` 和 `process(_:time:streamID:)`，默认强度 0.75，返回 `image`、`usedHistory`、`resetReason`、`milliseconds`。使用 16-bit float RGB 输入中间帧和无损压缩 10-bit YUV，错误明确抛出，没有静默缩小分辨率或偷偷改为空间锐化。

保护检查先跑出 84/86：等亮度彩色切镜没有被纯亮度差捕捉，32×18 棋盘平移预览受到采样混叠。改为 **64×36 RGB 最大通道差**，再验证 86/86 通过；保留场景门限是保守旁路，不能声称识别全部运动或切镜。

可复现命令：

```sh
bash scripts/validate-temporal-restoration.sh /tmp/native-temporal.json
```

[本轮正式 JSON](../validation/restoration/native-temporal-2026-09-28.json) 使用生产封装；12 连续帧/分辨率，另含切镜、等亮度色彩切换、快速大范围平移、seek/倒退/重复/非法 PTS、新 streamID、尺寸变化、干净画面、色彩与 10-bit 灰阶测试。84/86 的红灯和后续报告暂存 `.build/restoration-native-probe/integration-before-color-guard.json`、`integration-after-color-guard.json` 与 `integration-final.json`。

正式封装第 6 帧结果如下。**与前表不同，真值和原始噪声直接取原始 RGB，未预先转换为 YUV；两组表的数值不能直接互相比增幅。**

|尺寸/区域|原始噪声帧 MSE|现有空间降噪 MSE|时域封装 MSE|
|---|---:|---:|---:|
|720p 暗平区|79.89|28.53|16.95|
|720p 运动区|80.08|79.05|14.39|
|720p 细纹|80.08|79.67|24.72|
|720p 切换字幕|79.08|54.70|27.97|
|1080p 暗平区|79.92|28.60|21.50|
|1080p 运动区|79.72|78.70|12.07|
|1080p 细纹|79.92|79.53|23.46|
|1080p 切换字幕|79.65|50.32|25.84|

- 720p 完整模块热帧均值 6.83 ms、p95 7.01 ms；1080p 均值 11.90 ms、p95 12.90 ms。包含预览、半浮点/无损 10-bit 转换和完成回调等待；仍不包含解码、4K 放大、最终显示。第一次真正时域处理约 19.35/24.25 ms，首次建立参考另计。
- 在第 1/6/11 帧，合成字幕粗笔画前景召回均 100%，背景误点亮均 0；第 6 帧发生字幕位置切换。
- 干净细节图输出 MSE 0.00334；四个无噪彩色/灰色平场各 RGB 通道最大偏差为 1 个 8-bit 编码值，检查界限为 2。
- 640 像素的高精度灰阶斜坡，经处理后仍分辨 640 个量化采样值，证明该模块没有先降为 8-bit。不能由此替主管线最终输出格式作结论。
- 首帧、切镜和 seek 建立参考帧逐像素保持输入图；seek 后的输出与全新会话一致。局部运动经真正时域处理，广泛快速变化由保护旁路。

这些验证证明模块在上述合成退化和本机硬件上有效。真实影片的压缩块、胶片颗粒、运动遮挡、人脸和复杂细小字幕仍需要实际样本对照，不把合成 MSE 当作所有影片的主观观感保证。
