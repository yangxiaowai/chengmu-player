# Mac 影视修复与轻量超分方案核查（2026-09-28）

本报告针对 M4 / 16 GB、Swift + AVFoundation + Metal 播放器。核查范围是公开论文、作者仓库、模型发布页和 Apple/PyTorch 文档。调研后使用主线程准备的官方 EfRLFN x2 权重与隔离环境，完成 Swift Core ML 实测；结果见末节，其余候选未在当前 Mac 实跑。外部项目的演示速度不能作为本播放器的实测结果。

## 建议优先实测的两个候选

1. **EfRLFN x2，经本地 Core ML 转换**：训练任务直接包含压缩流媒体，2 倍模型适合 1080p → 2160p，模型小，算子比较规整。先验证整帧数值等价与压缩真人短片，再决定是否能进实时路径。其单帧结构不提供视频时域一致性保证。
2. **Real-ESRGAN general-x4v3（优先 DNI 0.25 / 0.5 / 1.0 对照）**：更适合已存在噪声、模糊和压缩伪影的真人画面。已有小体积 Core ML 转换产物可快速做第二个真实对照。默认 4 倍会使 1080p 中间结果达到 8K，若最终只需 4K，应测量多余运算与缩回的质量代价，不能把它称为原生 x2 模型。

动画应独立配置 Real-CUGAN / Anime4K，不把动画模型应用到全部影视。ESPCN / FSRCNN 适合作为低成本参考线；SwinIR 的轻量经典超分权重并不等于面向严重压缩真人的修复权重。

## 候选与适配边界

| 方案 | 面向本任务的价值 | Mac 接入现状与负担 | 主要风险 / 优先级 |
| --- | --- | --- | --- |
| EfRLFN x2 | StreamSR 压缩视频场景；不必先生成 8K | 官方是 PyTorch CUDA；可转 Core ML，已有社区 MLX 权重 | 无跨帧机制；全局注意力使分块结果不等于整帧；第一候选 |
| Real-ESRGAN general-x4v3 | 通用退化修复；强弱降噪权重插值可抑制过度磨皮 | 官方 `.pth` 两份各 4.66 MB；第三方 Core ML general 压缩包 2.18 MB | GAN 纹理/字幕变形及闪烁；x4 代价；第二候选 |
| Real-CUGAN / Pro | 动画线条、纹理、虚化区域；提供保守修复和多档降噪 | nihui 的 ncnn + MoltenVK macOS 包 49.5 MB，发布流程包含 arm64 | 不是默认真人修复器；仍须检查跨帧稳定性；动画专用 |
| Anime4K | 1080p 动画实时线条重建和降噪 | GLSL 着色器；存在 Metal 移植；MIT 上游 | 上游明确不针对真人或严重退化旧片；Metal 移植有采样对齐已知问题 |
| FSRCNN / ESPCN | 轻量 x2 基准，可量化“只超分”和“真正修复”的区别 | OpenCV 有现成加载路径；Core ML 需自行转换或核验第三方导出 | 常规低分辨率训练，不能假定去噪/去压缩有效；不作最终画质方案 |
| SwinIR-S / realSR | Transformer 质量参考；有 PSNR/GAN 两类真实超分权重 | 轻量 x2 发布文件 16.4 MB；真实 x2 M 模型 63.9 MB；需适配 MPS/Core ML | “轻量”仍需实测；窗口与分块边界敏感；不优先进入实时路径 |

表中大小来自下文可追溯发布页，MB 沿用网页标注，并非解压后驻留内存。

## EfRLFN：2026 年压缩流媒体方向

论文《Exploring Real-Time Super-Resolution: Benchmarking and Fine-Tuning for Streaming Content》（ICLR 2026）发布 StreamSR，并评估 11 个轻量模型在压缩流媒体上的表现。这比仅做双三次下采样训练更贴近网络影视源，但仍是**单图超分**，不是多帧视频复原。论文指标和主观评价不能直接证明当前 Mac 上播放更好。[论文](https://arxiv.org/abs/2602.11339) · [会议论文](https://openreview.net/pdf?id=HIG7riDJ9N)

官方仓库当前快照 `1f7f3678f1bd7ba04ca8ccb04726eef71bf8520a`，`code/model.py` 为 52 特征通道、6 个 ERLFB，末尾 PixelShuffle。ERLFB 使用 Conv2d、tanh、残差、Conv1d、sigmoid 和全局平均池化 ECA；没有可见的 deformable convolution 或自定义 CUDA 扩展。原推理脚本硬编码 `.cuda()`，README 的 `inference.py` 名称也与实际 `inference_model.py` 不一致，不能原封不动作为 Mac 运行命令。[模型源码](https://github.com/EvgeneyBogatyrev/EfRLFN/blob/1f7f3678f1bd7ba04ca8ccb04726eef71bf8520a/code/model.py) · [块源码](https://github.com/EvgeneyBogatyrev/EfRLFN/blob/1f7f3678f1bd7ba04ca8ccb04726eef71bf8520a/code/blocks.py) · [推理源码](https://github.com/EvgeneyBogatyrev/EfRLFN/blob/1f7f3678f1bd7ba04ca8ccb04726eef71bf8520a/inference_model.py)

**转换风险推断**：以上均有常见 Core ML 对应算子，但是否成功、FP16 误差和运行分配仍须实测。固定输入 `torch.jit.trace → coremltools.convert → MLModel` 是最小验证路径。先保持 RGB / `[0,1]` / NCHW 的输入规范，不把归一化、通道顺序或视频有限范围转换混入模型对比。ECA 在每块内重新做全局平均池化，因此即使扩大 halo，分块与整帧也不严格等价；拼缝检测必须覆盖亮暗交界、人脸、字幕和缓慢平移。[Apple 转换流程](https://apple.github.io/coremltools/docs-guides/source/convert-pytorch-workflow.html)

官方 x2 权重链接在 [README](https://github.com/EvgeneyBogatyrev/EfRLFN#model-weights) 指向 [Google Drive 文件](https://drive.google.com/file/d/1VeoW94hN1X-8kxGXQSyR53YzRqF1htKQ/view)。后续已取得该官方 x2 文件：1,968,047 字节，SHA256 `fbfd1bb37973d2b8b53493c5b91c0ef106f74d200115250a8a025b8e6a121cb3`；安全加载与 strict state-dict 匹配通过。仓库拼作 `weigths/` 的目录只有说明文件，不能把仓库 clone 当成已取得权重。社区 [mlx-community/EfRLFN-x2](https://huggingface.co/mlx-community/EfRLFN-x2) 有 `model.safetensors`，Hub 文件元数据为 **1,953,137 字节**、SHA256 **`9d4f74557ec88ed93a13698e11af471bf224c8531efc147682d46800ed5cf958`**，配置为 52 通道 / 6 块 / x2；NOTICE 声称来自官方权重，但本报告未独立验证这种等价性。[文件元数据](https://huggingface.co/api/models/mlx-community/EfRLFN-x2/tree/main) · [权重读取链接](https://huggingface.co/mlx-community/EfRLFN-x2/resolve/main/model.safetensors)

官方 `LICENSE` 和 `LICENCE` 同为 MIT，版权人为 2026 MSU Graphics & Media Lab；社区模型卡也标 MIT。分发转换产物时保存原版权通知、来源、原文件/转换后文件哈希及转换参数；不把训练数据下载链接当作训练数据再分发授权。[官方许可](https://github.com/EvgeneyBogatyrev/EfRLFN/blob/main/LICENSE)

## Real-ESRGAN compact、DNI 与 Core ML

官方 general-x4v3 使用 `SRVGGNetCompact(num_feat=64, num_conv=32, upscale=4)`，基本卷积在低分辨率空间完成，最后 PixelShuffle 并加 nearest 残差。官方 DNI 对强降噪和 weak-denoise 两份参数逐层加权；`-dn 0` 保留更多噪声、`1` 更强降噪，默认 `0.5`。**这不是简单把强降噪成片与原图混合**。建议同一段源先测 0.25 / 0.5 / 1.0，找纹理保留与压缩伪影消减的平衡。[官方选模/DNI入口](https://github.com/xinntao/Real-ESRGAN/blob/master/inference_realesrgan.py) · [DNI 与分块实现](https://github.com/xinntao/Real-ESRGAN/blob/master/realesrgan/utils.py) · [架构](https://github.com/xinntao/Real-ESRGAN/blob/master/realesrgan/archs/srvgg_arch.py)

官方 `.pth` 发布文件各 **4.66 MB**：

- [realesr-general-x4v3.pth](https://github.com/xinntao/Real-ESRGAN/releases/download/v0.2.5.0/realesr-general-x4v3.pth)
- [realesr-general-wdn-x4v3.pth](https://github.com/xinntao/Real-ESRGAN/releases/download/v0.2.5.0/realesr-general-wdn-x4v3.pth)

大小依据 [v0.2.5.0 资产页](https://github.com/xinntao/Real-ESRGAN/releases/expanded_assets/v0.2.5.0)。官方 Python helper 默认只检测 CUDA / CPU，但 `RealESRGANer` 接受显式 `device=torch.device('mps')`，需先检测 `torch.backends.mps.is_available()`。框架支持 MPS 不等于整条代码都已通过 MPS 测试。[PyTorch MPS 文档](https://docs.pytorch.org/docs/2.14/notes/mps.html)

快速 Core ML 备选：[hanxiao/real-esrgan-coreml](https://github.com/hanxiao/real-esrgan-coreml)，当前快照 `15ab3bf80a577cecb93bb2b7ed48711ba7d894d5`。其转换配置直接引用官方 general-x4v3 权重，macOS 最低目标 15；运行时为 Core ML / NumPy / Pillow，无需 PyTorch。已发布固定 522×522、FP16 的 general 包 **2.18 MB**，输入 NCHW `input`，输出名称应从模型 description 读取。Swift 可编译 `.mlpackage` 后直接调用 `MLModel`，不必把 Python 带进播放器。[转换源码](https://github.com/hanxiao/real-esrgan-coreml/blob/15ab3bf80a577cecb93bb2b7ed48711ba7d894d5/convert.py) · [推理源码](https://github.com/hanxiao/real-esrgan-coreml/blob/15ab3bf80a577cecb93bb2b7ed48711ba7d894d5/upscale.py)

[固定 general 模型下载](https://github.com/hanxiao/real-esrgan-coreml/releases/download/v1.0.0/RealESRGAN_general_522_fp16.zip)，发布 SHA256 为 **`41368af9dcbcc300c0fe0442202acbf98d30dc07c28d49bf656883f7fef3656a`**。[资产页](https://github.com/hanxiao/real-esrgan-coreml/releases/expanded_assets/v1.0.0)

这个现成 general 包是强降噪权重，不提供 DNI 选择。仓库 README 与 `pyproject.toml` 声明 MIT，但本次根目录 `LICENSE` URL 返回 404；上游权重来源仓库有可读 BSD-3-Clause。把该包作为实验候选时需记录第三方转换来源，正式集成优先自行转换已验证的官方权重。该仓库 README 中 ANE 说明与当前源码的 flexbatch/ANE 注释不一致，因此不采用其 ANE 派发和性能结论。[依赖声明](https://github.com/hanxiao/real-esrgan-coreml/blob/main/pyproject.toml) · [原始 BSD-3-Clause](https://github.com/xinntao/Real-ESRGAN/blob/master/LICENSE)

仅用于独立实验目录的复现入口（本报告未执行）：

```bash
# 已准备隔离 Python 环境后，固定上述 commit；避免自动取最新依赖。
python upscale.py frame.png -o general.png --model general --compute-unit CPU_AND_GPU
# 官方 PyTorch general 的 CPU 对照路径；MPS 需要显式传 device 的小封装。
python inference_realesrgan.py -n realesr-general-x4v3 -i frames -o results-dn05 -dn 0.5 --fp32 --outscale 2
```

`--outscale 2` 是先 x4 推理再用 Lanczos4 调整输出，非真正 x2 网络，且可能重新引入锐边振铃；公平比较应统一末端采样器。官方 ncnn 便携实现也说明分块可产生不一致。不要用其“可播放视频”表述推断该单帧 GAN 保证时间一致性。[官方说明](https://github.com/xinntao/Real-ESRGAN#portable-executable-files-ncnn)

## 动画候选与 Mac 二进制

Real-CUGAN 是百万级动漫数据训练的动画超分模型，2 倍档有多种降噪和保守修复。官方原始工具面向 CUDA/CPU；nihui 的 ncnn 移植明确支持 Apple Silicon，macOS 20220728 包 **49.5 MB**，包含模型和运行所需二进制，无需 CUDA/PyTorch。发布脚本分别构建 x86_64/arm64，再合并 universal，并静态链接 MoltenVK/OpenMP。此处验证的是发布流程，未下载后执行 `file` / `otool` 检查具体发布包。[原始项目](https://github.com/bilibili/ailab/tree/main/Real-CUGAN) · [Mac 移植](https://github.com/nihui/realcugan-ncnn-vulkan) · [发布资产](https://github.com/nihui/realcugan-ncnn-vulkan/releases/expanded_assets/20220728) · [构建流程](https://github.com/nihui/realcugan-ncnn-vulkan/blob/master/.github/workflows/release.yml)

可复现命令：`./realcugan-ncnn-vulkan -i frame.png -o output.png -s 2 -n 0 -c 1 -m models-se`。应先用准确 sync 模式与保守强度做质量参照，再研究性能。上游与移植均 MIT；正式捆绑仍需保留 ncnn、MoltenVK 等各自通知。[原始许可](https://github.com/bilibili/ailab/blob/main/Real-CUGAN/LICENSE) · [移植许可](https://github.com/nihui/realcugan-ncnn-vulkan/blob/master/LICENSE)

Anime4K 上游 MIT，明确为原生 1080p 动画优化，未针对严重退化的低清旧片，不能将“Anime4K”当作真人影视的通用修复器。其 [Anime4KMetal](https://github.com/imxieyi/Anime4KMetal) 移植为 Apache-2.0，以 GLSL → Metal 动态转换播放；文档承认与 mpv 的亚像素对齐差异和大型 shader 编译卡顿。集成应独立为动画预设，不覆盖影视默认档。[Anime4K](https://github.com/bloc97/Anime4K) · [Metal 移植说明](https://github.com/imxieyi/Anime4KMetal/blob/master/README.md)

## FSRCNN / ESPCN 与 SwinIR

FSRCNN / ESPCN 将卷积主要放在低分辨率空间，适合建立低延迟 x2 参考线。原论文的实时结果属于其测试硬件和输入，不代表本 Mac 1080p/4K 播放性能。OpenCV `dnn_superres` 可加载现成 FSRCNN / ESPCN 模型，但为当前 Swift app 引入整套 OpenCV 仅为基准未必划算；TensorFlow旧仓库的 GPU/CUDA 依赖也不等于 Metal 支持。[FSRCNN 作者项目](https://mmlab.ie.cuhk.edu.hk/projects/FSRCNN.html) · [OpenCV 官方示例](https://docs.opencv.org/4.x/d5/d29/tutorial_dnn_superres_upscale_image_single.html) · [FSRCNN 模型仓库](https://github.com/Saafke/FSRCNN_Tensorflow)

[ESPCN 第三方实现](https://github.com/anujdutt9/ESPCN) 提供 Core ML 导出选项，但不是已经验证可用于低码率真人片的现成模型；其页面主要示例为 x3，改变倍率不能只改命令而不换权重。本轮不优先引入。

SwinIR 官方把 lightweight SR 与 real-world SR 分开：轻量 S 使用 60 维特征、4×6 深度、直接 pixel shuffle；真实 SR M 用更大模型和不同重建头。不能拿 DIV2K 轻量 SR 的 16.4 MB 文件宣称同时实现强压缩恢复。实际 x2 realSR PSNR/GAN 独立发布文件各 63.9 MB，适合做画质参照而非先默认实时集成。代码 Apache-2.0；官方未提供经本机验证的 Swift/Core ML 模型。[源码任务分支](https://github.com/JingyunLiang/SwinIR/blob/main/main_test_swinir.py) · [权重大小](https://github.com/JingyunLiang/SwinIR/releases/expanded_assets/v0.0) · [许可](https://github.com/JingyunLiang/SwinIR/blob/main/LICENSE)

## 实时播放的工程判定

以下为本项目工程建议，不是论文或仓库的性能承诺：

- 24 / 30 / 60 fps 对应完整帧周期 41.67 / 33.33 / 16.67 ms；模型预算须扣除解码、色彩转换、Metal 交接、字幕、UI 与呈现。报告中分开记录模型时间和完整管线 P50/P95、丢帧、峰值内存、冷启动与热稳定阶段。
- 预读可吸收短暂抖动，不能修复平均处理速度低于播放帧率。若持续每帧处理时间大于帧周期，必须降档或建立明确的离线/预处理模式，不能以越来越长的队列假装实时。
- 1 帧 4K RGBA8 约 31.6 MiB，RGBA16F 约 63.3 MiB；100 帧仅图像就约 3.1 / 6.2 GiB。16 GB 统一内存下只保留有限队列；不把整段影片展开为所有 4K 中间帧。
- 单帧 GAN 在纹理、人脸、字幕上可能出现不稳定细节；同时比较停帧与正常速度/慢放连续段。包含低光噪声、缓慢平移、快速运动、头发/织物、烧录字幕和切镜，避免只挑静态建筑图。
- 对有干净参考的自行压缩样本，报告 PSNR/SSIM、噪声ROI、边缘过冲、字幕误差和运动补偿后的时域误差；对未知真值网络片只做并列观感和稳定性检验，不把更锐、更平滑或无参考分数变好等同于恢复真实细节。
- 烧录字幕已是模型输入的一部分，应与其它高对比细节一同验证；外部字幕在增强后绘制。HDR/Dolby、保护媒体与未知色域继续走已经验证的原生路径，不把 SDR 训练权重强行用于原生 HDR。
- 首轮采用整帧小分辨率对照建立数值可信性，再对同一帧测试 tile 大小/halo/重叠融合和接缝。对 EfRLFN 全局注意力还需观察同一物体跨 tile 边界时的连续帧亮度变化。

本报告不替代实际播放器验收。是否纳入默认档位，应由当前机器、真实短片对比和持续播放预算共同决定。

## 后续本机实验：EfRLFN 不进入实时生产管线

在 Apple M4 / 16 GB / macOS 27 上，使用上述官方 x2 权重、自行转换 Core ML FP16、Swift `MLModel`、RGB8 图像输入输出。每个尺寸真实完成 5 帧：一帧首次推理和 4 帧热运行。总耗时包括 CI sRGB 输入写入、同步 Core ML 推理、Metal 输出呈现纹理的 command 完成；不含解码、音频、UI。没有缩小输入或分块。首末帧同样输入的完整输出像素哈希相同。

| 自然输入 → 模型实际输出 | 动态模型 `.all` warm均值 | 固定模型 `.all` 首帧 | 固定模型 warm 范围 | 判断 |
| --- | ---: | ---: | ---: | --- |
| 480×200 → 960×400 | 48.38 ms | 31.25 ms | 11.85–13.86 ms | 小样低分辨率可探索，非480p |
| 854×480 → 1708×960 | 未测 | 80.20 ms | 58.14–67.47 ms | 超过24fps完整帧周期 |
| 960×400 → 1920×800 | 195.98 ms | 66.75 ms | 45.77–48.19 ms | 超过24fps完整帧周期 |
| 1280×720 → 2560×1440 | 456.37 ms | 137.20 ms | 104.68–111.63 ms | 超过24fps完整帧周期 |
| 1920×1080 → 3840×2160 | 1104.47 ms | 403.33 ms | 306.59–309.46 ms | 超过24fps完整帧周期 |

固定输入改善显著，但 720p 的 105–112 ms 与 1080p 的 307–309 ms 均不满足实时影视播放。854×480 也超过 24 fps 的 41.67 ms **总**帧预算；不能把宽 480 的 480×200 测试误称为“480p 实时”。因此本轮只保留可复现实验，不把该模型伪装成播放器的新实时修复档位。动态输入只有默认 64×64 速度较快；`.CPU_AND_GPU` 对照也不能解决高分辨率速度问题。尚未取得每层真实设备派发数据，故不把这种差异直接定性为 ANE/GPU 派发结论。

输入色彩没有混用线性 RGB。Core Image 使用 linear 工作空间，但写给模型的 CVPixelBuffer 明确为 sRGB；64×64 合成样本对官方 CPU FP32 的 MAE 为 0.263/255、最大误差 0.981/255。真实压缩与噪声电影帧（480×200 → 960×400）分别为 MAE 0.265/255 与 0.264/255，P99 约 0.702/255，最大误差小于 1.1/255。这是转换与通道/色彩一致性证据，不代表细节恢复质量已经全面合格，也不代表动态视频无闪烁。

`VTLowLatencySuperResolutionScalerConfiguration` 的同机能力查询：480×200 支持 1.5/2/4 倍，960×400 支持 1.5/2 倍，1280×720 与竖屏720×1280仅1.5倍，1920×1080无可用倍率；这些是接口查询结果，不能等同于已验证每档画质或实时吞吐。

可复现工具位于 [scripts/experiments/efrlfn](../../scripts/experiments/efrlfn/README.md)，不自动下载权重、不自动装依赖、不修改生产 app。源码与权重输入有固定 SHA256 校验，保留 MIT 许可。数值证据保存在 [coreml-efrlfn](../validation/restoration-2026-09-28/coreml-efrlfn/)，包含动态/固定尺寸完成时间、环境与权重来源、真实帧/合成帧转换误差及 VT 查询。
