# 实时修复的原生能力与保守缩放设计（2026-09-29）

本次只考察本机 Apple M4 / macOS 27、SDR、无未来帧的实时路径。实验独立编译，未触发模型下载。GPU 实验与其他代理串行错峰。短探针不等于长时间播放、温控、音画同步或所有片源的质量证明。

## 已有硬件模型能否直接解决 1080p→4K

当天运行时重新查询：`VTSuperResolutionScalerConfiguration` 高质量模型已 ready（进度 1.0），仅支持倍率 `[4]`；1920×1080 的 ×2 配置返回 nil，×4 可建立。不要沿用 9 月 28 日“模型尚未就绪”的历史状态，也不要把先缩小输入再 ×4 称为原尺寸超分。1080p 原尺寸进入该模型实际产生 7680×4320，然后还需降至 4K。

系统 VideoEffect 资产目录只读元数据：模型 `com.apple.videoeffect.VSR`、版本 `1.0.0.11.6435,0`，下载包 62,259,200 字节（59.38 MiB），解包 69,414,912 字节（66.20 MiB）。本机已有 `vsrnet_4x.mlmodelc`；本次没有调用下载 API。包大小来自此机器目录，不能当成所有系统版本恒定大小。官方能力与生命周期参见 [Apple 配置 API](https://developer.apple.com/documentation/videotoolbox/vtsuperresolutionscalerconfiguration)、[模型下载 API](https://developer.apple.com/documentation/videotoolbox/vtsuperresolutionscalerconfiguration/downloadconfigurationmodel(completionhandler:)) 和 [WWDC25 原生视频处理介绍](https://developer.apple.com/videos/play/wwdc2025/300/)。

实际 first + 3 sequential 回调完成测试，包含输入转换、输出纹理，超过 4K 时附带正权重 B-spline 缩回；不是仅提交命令计时：

| 输入 | 原生 ×4 输出 | 显示尺寸 | 首帧总耗时 ms | 后 3 帧模型均值 ms | 后 3 帧总均值 ms |
|---|---|---|---:|---:|---:|
| 640×360 | 2560×1440 | 2560×1440 | 977.25 | 272.30 | 279.57 |
| 960×540 | 3840×2160 | 3840×2160 | 726.95 | 547.29 | 557.01 |
| 1280×720 | 5120×2880 | 3840×2160 | 1141.33 | 968.93 | 986.98 |

会话建立本身约 7–8 秒。720p 已远超逐帧预算，故没有进行 1080p→8K 的昂贵试跑。单张 8K RGBAHalf 缓冲约 253 MiB，仅当前/历史输出即约 506 MiB，尚未计输入、光流、模型。增加 GPU 占用无法把以上完成时间合理转化为实时 30fps。

### 输出像素合同复查

上述最初呈现读回为全零，不能据此说模型输出了黑画面。360p 两帧核查发现 RGhA 输出的 **RGB 有效、alpha 为 half `0xffff`（NaN）**；底色 raw RGB 约 0.1207 / 0.1792 / 0.2362。Core Image 已在导入时受 NaN alpha 影响，因此事后 `CIColorMatrix` 强制 alpha 为 1 仍为黑。隔离单帧探针在 CVPixelBuffer 原始内存将 alpha 写成 Float16(1) 后，CI 缩略图 alpha=255、RGB 最大203，证明模型确有 RGB 输出。该复查模型完成约246ms，仍无法实时。

因此先前表格是有效的“模型回调和命令完成”耗时，但不是已修复 alpha 的可上线输出路径质量验收。没有把此高质量模型接入生产。原始短探针源码与小型JSON已归档于 `docs/validation/v0.3.3/native-research/`，其中 `quality-sr-results.json`、`quality-sr-alpha-results.json`、`quality-sr-sanitize-results.json` 记录了以上复查。真实接入若再考虑此模型，需在不污染历史 RGB 的前提下规范化 alpha，并补完整色彩、视频时序验证。

## 现成空间放大器为何不能直接替换

[MetalFX spatial](https://developer.apple.com/documentation/metalfx/mtlfxspatialscalerdescriptor) 在本机支持 1080p→4K：BGRA8 sRGB/perceptual 与 RGBA16Float/linear 都能创建配置。输出要求 private storage，按实际 texture usage 分配。 [Apple 色彩处理模式](https://developer.apple.com/documentation/metalfx/mtlfxspatialscalercolorprocessingmode) 应与输入转换一致；不能只改像素格式而保持错误传递函数。MetalFX temporal 还要求深度、运动矢量和 jitter 等渲染数据，不是普通视频帧的即插即用增强器，见 [WWDC22 MetalFX](https://developer.apple.com/videos/play/wwdc2022/10103/)。

单一合成夹具：1080p 灰阶阶跃 64→192 与平区独立 ±8 噪声；放大到 4K。无时域降噪，first+3 warm，等待 GPU 真正完成，含输入转换、排除读回。

| 方法 | warm wall ms | warm GPU ms | 阶跃范围 | 最大过冲 code | 平区噪声 MSE |
|---|---:|---:|---|---:|---:|
| MetalFX perceptual | 4.93 | 3.37 | 58…202 | 10 | 43.50 |
| MetalFX linear | 5.04 | 3.68 | 53…202 | 11 | 41.09 |
| MPS Lanczos | 3.61 | 2.14 | 7…200 | 57 | 19.42 |
| CI B-spline（B=1,C=0） | 3.23 | 1.63 | 64…192 | 0 | 5.60 |

平区读回64/192正确；这不是伽马误配产生的过冲。对该样本，MetalFX 放大残噪，MPS Lanczos 的负瓣引入明显振铃；不能只因其快或“硬件加速”就默认更好。Apple 的 [MPS Lanczos 文档](https://developer.apple.com/documentation/metalperformanceshaders/mpsimagelanczosscale) 也说明锐边附近的振铃。上述只是一张压力图，不是普适质量排名。

可借鉴 [AMD 官方 FSR1](https://github.com/GPUOpen-Effects/FidelityFX-FSR) 的边缘自适应重采样思想，但不默认叠加 RCAS 锐化；其现有着色器并非 macOS Metal 即用实现。[GPU Gems 的三阶过滤推导](https://developer.nvidia.com/gpugems/gpugems2/part-iii-high-quality-rendering/chapter-20-fast-third-order-texture-filtering) 则提供正权重 B-spline 与双线性采样分解背景。这里引用算法思路，不声明复现论文训练结果或已采用这些项目的全部实现。

## 当前可解释的实时方案与验证边界

主线选择原尺寸时域降噪，再接 `DetailScaler` 的空间插值；未来帧为0，首帧/切源/seek/切镜沿用既有复位规则。低延迟 Apple AI 在设备允许倍率时独立标识，后续插值只标为“空间细节缩放”，不会把 4K 输出栅格称为原生 4K 重建。

`DetailScaler` 的候选算法为：线性光颜色空间采样，4×4 Catmull–Rom 重采样限制在本地2×2最小/最大值包络内；使用局部对比度与梯度方向一致性决定与双线性结果的混合，最大候选权重0.8。平区/无方向噪声倾向双线性，连续边缘才允许更窄过渡。最终直接写 sRGB BGRA8，避免再构造一张4K中间纹理并重渲染。没有生成式字幕重绘，但这也不等于逐像素保持内嵌字幕；字幕严格保护需要显式保护区，外挂字幕应在视频增强后合成。

独立数值验证脚本为 `scripts/validate-detail-scaling.sh`，可选第二参数覆盖生产类路径。它验证同一时域输出的阶跃、暗/中/亮平区独立噪声、60张完成帧和已有两张真实影片单帧。读回必须与既有 `CIContext.render` 最终纹理保持相同方向合同：影片图像比较不能复用局部柔化测试为选区坐标专门添加的 `.downMirrored`。

首轮有效的算法/性能观测：同一时域阶跃范围64…192，无新增过冲；10–90%过渡宽度2px，B-spline为3px。时域后六组平区噪声 MSE 相对双线性最大约1.044倍；未经降噪的192±8压力图约1.155倍，说明该缩放器不会独立消除原片噪点。最终19项独立检查全部通过；1080p→4K scaler-only 60帧完成均值3.58ms/p95 4.63ms（GPU均值2.25ms/p95 3.02ms），排除解码、时域处理、显示和读回，不能当整条播放器延迟。

最终报告为 `docs/validation/v0.3.3/detail-scaling.json`。两个非对称影片输入的既有 CI→BGRA8 纹理读回与直接 CI 像素完全相同（PSNR计为100）；新缩放器与既有双线性最终纹理采用同一种无额外镜像的读回，相似度48.74/49.35dB，确认方向合同一致。初稿7.3dB异常来自测试错误套用选区坐标的`.downMirrored`，没有因此修改生产shader。

| 单帧输入 | 新细节缩放 PSNR dB | B-spline PSNR dB | 双线性 PSNR dB |
|---|---:|---:|---:|
| noisy-film-24 | 32.346 | 31.692 | 32.303 |
| compressed-film-24 | 30.871 | 30.418 | 30.892 |

组内比较使用相同480×200降质输入、960×400清洁参考和2×输出，未调用时域历史。新方法在这两张图都高于B-spline；压缩图比双线性低0.021dB，不能声称所有输入都优于所有基线。这不是4K重建证明。是否视觉更好还需结合肤质、细纹、运动与字幕实际查看，不能只看PSNR或GPU使用率。
