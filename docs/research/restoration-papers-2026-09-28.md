# 映川视频修复：论文与开源实现调研

核查日期：2026-09-28。目标设备按 Mac M4、16 GB 统一内存评估。本报告记录文献核查阶段的一手论文、作者仓库、官方模型卡及关键推理源码；该阶段未运行模型。随后完成的 EfRLFN 官方权重核验、Core ML 转换和 M4 实测，见 [Mac 实验记录](mac-restoration-options-2026-09-28.md)与[可复现工具](../../scripts/experiments/efrlfn/README.md)。“公开提供权重”表示作者提供入口，不代表本轮完成了文件下载、校验、许可证授权确认或中国大陆直连测试。以下兼容性及接入优先级是工程判断，不是本机性能测量。

## 结论与研发顺序

当前需求应同时解决压缩伪影、时域闪烁和保真，不能仅把低分辨率帧放大。优先比较 **EfRLFN 的压缩场景轻量重建、RealViformer 的单向时域重建**；用 RealBasicVSR 作为真实退化视频的质量基线，用 FastDVDnet 分离验证“多帧降噪”收益。NanoVSR 适合研究小模型部署，但现有训练主要针对双三次缩小，不能直接证明能处理网剧的二次压缩。

本机日常播放路线应保留可关闭的轻度处理、原片对照和超时回退。重模型先用短片段离线对比，不把“能加载模型”“单张图片可跑”或 NVIDIA 上的 FPS 当作 Mac 连续播放能力。SeedVR2/FlashVSR 暂作高质量离线候选；尤其不能在用户已抱怨噪点和不自然纹理的情况下默认切到生成式模型。

## 12 个代表性方案

时延分为等待输入帧的前视时延和计算时延；下表帧数不包含解码、模型加载、传输与显示。

| 方法与一手来源 | 面向的退化与特点 | 时序依赖、实际流式条件 | 对映川/M4 的判断 |
| --- | --- | --- | --- |
| **RealBasicVSR，CVPR 2022**：[论文](https://arxiv.org/abs/2111.12704)、[作者仓库](https://github.com/ckkelvinchan/RealBasicVSR) | 真实模糊、噪声、压缩混合退化；先清理输入，再用 BasicVSR 传播信息，避免伪影不断累积。 | BasicVSR 双向传播，需要完整处理窗口；`--max-seq-len` 可以限制内存，分段并不自动保证边界连续。`is_sequential_cleaning` 只指清理逐帧执行，不代表整个模型因果。 | 适合作为质量对照。官方旧 PyTorch/MMCV/MMEditing 环境需隔离；CoreML 接入要拆分光流、状态和重建。默认 GAN 权重可能补纹理，需与保真结果对照。 |
| **BasicVSR++，CVPR 2022**：[论文](https://arxiv.org/abs/2104.13371)、[官方实现](https://github.com/ckkelvinchan/BasicVSR_PlusPlus) | 二阶传播、光流指导可变形对齐；另有去噪、去模糊、压缩增强配置，不能混用各任务权重。 | 源码包含 `backward_1/forward_1/backward_2/forward_2`；非零前视，默认非单帧因果。 | 高质量基线；MMCV 可变形卷积与 CUDA 路径增加 Apple 移植工作。不能只把 `.cuda()` 改成 `mps` 就宣称支持。 |
| **RVRT，NeurIPS 2022**：[论文](https://arxiv.org/abs/2206.02146)、[官方实现](https://github.com/JingyunLiang/RVRT) | 局部帧并行、全局递归；引导可变形注意力，覆盖 SR、去模糊和高斯去噪。 | 小 clip 不代表只等待小 clip：官方网络仍多次双向传播，需要所选序列的未来帧。 | 适合离线学术对照；有自定义可变形算子和 CUDA 特定缓存路径。非商业许可证亦不适合直接随通用应用分发。 |
| **VRT，2022**：[论文](https://arxiv.org/abs/2201.12288)、[官方实现](https://github.com/JingyunLiang/VRT) | 多尺度时域注意力、并行 warping；用相邻帧补充信息，覆盖多种视频恢复任务。 | 多帧 clip 交互，非严格因果；时域/空间切块需要重叠，窗口缩小会改变质量和边缘行为。 | 计算/内存成本较高，暂无本机实时证据。优先级低于 RVRT；官方常用数据集分数不能直接外推影视片源。 |
| **RealViformer，ECCV 2024**：[论文](https://arxiv.org/abs/2407.13987)、[官方实现](https://github.com/Yuehan717/RealViformer) | 通道注意力降低退化查询导致的伪影传播；比“干净双三次 SR”更贴近真实网剧。 | 论文 §4.1 与源码均为**单向递归**：当前帧、上一帧及历史特征即可，不需要未来帧。但现有脚本每 100 帧批量推理，并在每段重置状态。 | 值得做真正持久化状态的流式原型。需要处理 SPyNet、warping、状态重置和大运动；官方脚本仅选 CUDA/CPU，尚不是可用的 Apple 后端。 |
| **MGLD-VSR，ECCV 2024**：[论文](https://arxiv.org/abs/2312.00853)、[官方实现](https://github.com/IanYeung/MGLD-VSR) | 运动约束扩散采样，时域解码器缓解随机细节闪烁。 | 多帧、多步扩散，官方示例 `ddpm_steps=50`；不是逐帧实时方案。 | 用于研究生成式质量上限，不作为实时主线。xformers/MMCV/扩散依赖较重；代码与模型卡许可还需澄清，详见下表。 |
| **SeedVR2，ICLR 2026**：[论文](https://arxiv.org/abs/2506.05301)、[官方实现](https://github.com/ByteDance-Seed/SeedVR) | 一步扩散对抗后训练，提供 3B/7B，擅长感知细节重建。作者明确承认轻度退化输入可能过度生成细节、过锐化，大运动可能失败。 | 一步指扩散采样步数，不是单帧/零延迟；时空窗口与视频段一起处理，存在预读和峰值内存。 | M4 16 GB 不应承诺 4K 实时。官方 CUDA/Apex 环境之外的 Mac 移植必须单独验收。使用时要有保真强度和字幕/面孔检查，适合可等待的实验路线。 |
| **FlashVSR，CVPR 2026**：[论文](https://arxiv.org/abs/2510.12747)、[官方实现](https://github.com/OpenImagingLab/FlashVSR) | 一步扩散、稀疏注意力、Tiny Conditional Decoder，专门研究长视频流式 SR。 | 因果 latent/KV cache，但论文明确仍有 **8 帧前视**；30 FPS 下约 267 ms 输入等待，另加计算。 | 官方约 **17 FPS / A100 / 768×1408**；并非 M4 或 4K 实时证明。需要 Block-Sparse Attention CUDA 后端，官方提醒去掉 LCSA 的第三方移植会损伤质量。 |
| **FastDVDnet，CVPR 2020**：[论文](https://arxiv.org/abs/1907.01361)、[官方实现](https://github.com/m-tassano/fastdvdnet) | 无显式光流，5 帧 CNN 降噪，模型接受噪声强度图；公开权重主要针对高斯/截断高斯噪声。 | 输入 `t−2…t+2` 输出中心帧，至少等待 2 帧；30 FPS 下约 67 ms，另加计算。 | 简单卷积结构值得评估 CoreML 转换；需要真实压缩适配与可靠噪声估计。不能把去高斯噪声能力等同于消除码流块效应或恢复 4K。 |
| **COMISR，ICCV 2021**：[论文](https://arxiv.org/abs/2105.01237)、[Google 官方源码](https://github.com/google-research/google-research/tree/master/comisr) | 专门考虑压缩，递归超分辨率，模拟 YouTube 压缩验证。 | 官方推理保留 `pre_inputs/pre_gen/pre_warp`，使用当前帧与历史结果；推理状态可因果更新。 | 方法与场景匹配，但 TensorFlow v1 风格与 TensorFlow Addons 的迁移成本较高；适合参照退化建模，非首选直接嵌入。 |
| **NanoVSR，ECCV 2026**：[论文](https://arxiv.org/abs/2607.10495)、[官方实现](https://github.com/filippawlicki/nanovsr) | 纯卷积、重参数化、小模型；不依赖显式光流或自定义 CUDA 算子。 | **双向 T=15** 分段推理，有缓冲；30 FPS 收齐 15 帧约需半秒，另加计算。官方 demo 每段独立执行，应检查接缝和状态。 | 有较好的转换可行性。27.2 FPS 是 Orin NX 16 GB/25 W、180×320 输入、TensorRT FP16；输出 720p，不能外推 4K。主要训练于双三次退化，应另测真实压缩。 |
| **EfRLFN / StreamSR，ICLR 2026**：[论文](https://arxiv.org/abs/2602.11339)、[官方实现](https://github.com/EvgeneyBogatyrev/EfRLFN) | 在真实多码率流媒体上研究轻量 SR，针对压缩数据训练；2×/4×权重公开。 | **单帧**模型，无未来帧要求，也不包含视频时域融合；逐帧运行仍需检查闪烁。 | 本机可移植性优先候选。论文的 RTX 2080、RTX A6000/ONNX/TensorRT 数字不是 M4 数据；先测 2×1080p→4K 的内存、延迟与细节收益。 |

## 代码和权重许可分别核查

这里记录作者当日发布的声明，不作额外授权推断。没有独立权重声明的项目，在将权重预装/再分发之前需保存实际权重附带条款并补齐来源，不应仅根据 GitHub 代码徽章判断。

| 项目 | 代码声明 | 权重公开状态与独立声明 |
| --- | --- | --- |
| RealBasicVSR | [Apache-2.0](https://github.com/ckkelvinchan/RealBasicVSR/blob/master/LICENSE) | README 提供 Dropbox/Google Drive/OneDrive。未见单独模型许可证；本轮未下载。 |
| BasicVSR++ | [Apache-2.0](https://github.com/ckkelvinchan/BasicVSR_PlusPlus/blob/master/LICENSE) | README 提供 Dropbox、OpenMMLab 任务权重；未见独立模型许可证。 |
| RVRT | [CC BY-NC 4.0](https://github.com/JingyunLiang/RVRT/blob/main/LICENSE)；依赖另有 MIT/Apache | [作者 Releases](https://github.com/JingyunLiang/RVRT/releases) 提供多任务模型；未见独立权重宽松授权。源码头部个别 BSD 描述不能覆盖根许可证/README 的非商业声明。 |
| VRT | [CC BY-NC 4.0](https://github.com/JingyunLiang/VRT/blob/main/LICENSE) | [作者 Releases](https://github.com/JingyunLiang/VRT/releases)；未见独立权重宽松授权。 |
| RealViformer | [MIT](https://github.com/Yuehan717/RealViformer/blob/main/LICENSE) | README 提供 Google Drive；未见独立权重模型卡许可证。 |
| MGLD-VSR | [S-Lab 1.0，非商业](https://github.com/IanYeung/MGLD-VSR/blob/main/LICENSE.txt) | README 的官方 [HF 权重卡](https://huggingface.co/IanYeung/MGLD-VSR/blob/main/README.md) 却标 Apache-2.0，属于待澄清的不一致；不能因模型卡宽松就忽略推理代码限制。 |
| SeedVR2 | [Apache-2.0](https://github.com/ByteDance-Seed/SeedVR/blob/main/LICENSE) | 官方 [3B](https://huggingface.co/ByteDance-Seed/SeedVR2-3B)、[7B](https://huggingface.co/ByteDance-Seed/SeedVR2-7B) 模型卡均明确 Apache-2.0。 |
| FlashVSR | [Apache-2.0](https://github.com/OpenImagingLab/FlashVSR/blob/main/LICENSE) | 作者 [v1.1 模型卡](https://huggingface.co/JunhaoZhuang/FlashVSR-v1.1) 明确 Apache-2.0；其他依赖和派生模型单独审查。 |
| FastDVDnet | [MIT](https://github.com/m-tassano/fastdvdnet/blob/master/LICENSE) | `model.pth`、`model_clipped_noise.pth` 在作者仓库；未见独立模型条款。README 注明训练代码更新后不能必然重现旧权重性能。 |
| COMISR | [Apache-2.0](https://github.com/google-research/google-research/blob/master/LICENSE)，推理文件亦明确 | README 提供 `gs://gresearch/comisr/model/`，未见独立模型许可证，未下载验证。 |
| NanoVSR | [MIT](https://github.com/filippawlicki/nanovsr/blob/main/LICENSE) | 作者 README Model Zoo 提供多个规模的权重链接；未见独立权重声明。 |
| EfRLFN | [MIT](https://github.com/EvgeneyBogatyrev/EfRLFN/blob/main/LICENSE) | README 提供 Google Drive 2×/4×权重；未见独立权重声明。 |

## 不能混淆的“Mac 可运行”

社区 [MFLUX SeedVR2 的 MLX 实现](https://github.com/mflux-community/mflux/blob/main/src/mflux/models/seedvr2/README.md) 提供 `generate_image` 和图片目录批处理，库代码为 MIT，底层 SeedVR2 权重仍按其 Apache-2.0 条款。当前文档展示的是**图片处理**，不是带视频隐状态的持续解码接口，也不是本机时域一致性测试。固定随机种子逐张处理不等于时域稳定。

该实现的 `softness` 实为输入预缩小：越大，先丢掉越多细节再重建，不能把它直接用作“去噪强度”。在噪声问题未判定前这样做，可能以丢纹理和补造纹理代替修复。文档给出的 2160 是**短边**，也不应不加判断地套到超宽/竖屏视频或认为必然就是 3840×2160。

## 对实现的具体建议

1. **用真实退化做选择**：把随机噪声、压缩蚊噪/块效应、原片胶片颗粒、锐化振铃区分开。低码率源优先温和去块/降噪，胶片颗粒不自动抹净；1080p 好源不因“4K”选项额外磨皮。
2. **先去噪，后重建，最后有限细节恢复**：全局锐化会放大残留噪声。细节增强应避开平坦暗部，在高置信边缘上限制幅度；参数变化要平滑，避免画面一闪一闪。此处是依据上述退化研究提出的工程方案，不是复刻某篇模型。
3. **时域处理必须有退出条件**：镜头切换、拖动、跳广告、播放源/尺寸/颜色信息变化时清空历史；遮挡、大位移、光流不可信时退回当前帧，不能把上一帧平均过去造成拖影。
4. **字幕后合成**：外挂字幕在增强后绘制；烧录字幕先保护高对比文字/已定义保护区，再测笔画是否改变。生成式模型不能默认为文字保真，字幕 OCR 正确率也不能替代观看检查。
5. **保持颜色链**：模型训练/推理多为 SDR RGB。HDR/PQ/HLG、杜比动态元数据不应经过未经验证的 SDR 模型；保留原生直通，不以 SDR 美化结果宣称杜比升级。
6. **同一输入帧服务两项工作**：增强和广告识别可复用解码，但广告 OCR 读取未改写原始采样帧，避免生成式模型改变广告字样后影响识别；识别调度不阻塞显示。

## 必须建立的视频验收集

合成噪声静态图能定位锐化问题，但不足以证明网剧恢复更好。最低采用每段 10–20 秒、至少 8 类样本：暗场人物、皮肤/头发、运动镜头、快速剪辑、树叶/织物细纹、渐变天空、烧录中文字幕、低码率动画。使用有明确可用来源的片段，保留来源、编码、色彩、PTS 和版本；在同一观看尺寸下比较原片、v0.3.1、候选模型。

- **有参考样本**：从高质量片段合成 H.264/HEVC 的不同码率、缩放、噪声与二次压缩；同时看 PSNR/SSIM/LPIPS，避免只奖赏“看起来锐”的纹理。
- **无参考真实样本**：盲看偏好 + 闪烁、拖影、文字和面部改变记录。NIQE/MUSIQ/CLIP-IQA 只能作辅助；更高分不证明剧情中细节真实恢复。
- **时域检查**：光流对齐后的残差/误差，静态区亮度与颜色波动，镜头切换后的残留帧数，拖动/恢复后的首帧状态。
- **本机资源**：启动/稳态的 p50/p95/p99 处理耗时、峰值统一内存、丢帧、20 分钟持续温度/性能、音画同步。24 FPS 与 30 FPS 帧预算分别约 41.7 ms 与 33.3 ms；模型处理预算要给解码/显示/字幕/OCR留出空间。
- **批准路径**：先验证一个分辨率档，达到视频质量和时延目标才开放下一档。只完成导出或跑通一帧时，界面继续标“实验”，不默认启用。

## 源码核查补充入口

- RealViformer 因果结构：[archs/realviformer_arch.py](https://github.com/Yuehan717/RealViformer/blob/main/archs/realviformer_arch.py)；批量脚本：[inference_realviformer.py](https://github.com/Yuehan717/RealViformer/blob/main/inference_realviformer.py)。
- BasicVSR++ 双向与可变形对齐：[basicvsr_pp.py](https://github.com/ckkelvinchan/BasicVSR_PlusPlus/blob/master/mmedit/models/backbones/sr_backbones/basicvsr_pp.py)。
- RVRT 双向传播：[network_rvrt.py](https://github.com/JingyunLiang/RVRT/blob/main/models/network_rvrt.py)。
- RealBasicVSR 清理与 BasicVSR 组合：[OpenMMLab 官方实现](https://github.com/open-mmlab/mmagic/blob/main/mmagic/models/editors/real_basicvsr/real_basicvsr_net.py)。
- FastDVDnet 五帧输入：[models.py](https://github.com/m-tassano/fastdvdnet/blob/master/models.py)。
- COMISR 历史状态与逐帧执行：[inference_and_eval.py](https://github.com/google-research/google-research/blob/master/comisr/inference_and_eval.py)。
- NanoVSR 双向模型：[nanovsr.py](https://github.com/filippawlicki/nanovsr/blob/main/models/nanovsr.py)；分段脚本：[demo.py](https://github.com/filippawlicki/nanovsr/blob/main/demo.py)。

此文档是文献/源码可行性核查记录；后续 EfRLFN 实测已单列，其他模型没有本机推理证据。未完成广泛画质盲测或再分发审核。
