# EfRLFN 实时修复计算图优化：M4 实测（2026-09-29）

本轮完成设备分配核查和三种保持原网络函数的图优化。结论是：**固定 720p 输入仍约 120 ms/帧，1080p 输入约 321 ms/帧；当前 EfRLFN x2 不能满足这台 Mac 的逐帧实时播放。强制使用 GPU 反而更慢。** 未将实验模型接入生产默认路径。

这不是画质质量测评：等价改写旨在保持既有画质并加速，不会凭空改善 EfRLFN 的去噪能力、纹理真实性或视频闪烁。图片输出与数值参考一起核验，避免把异步提交时间或黑帧当作成功。

## 设备、模型与边界

- 本机 Apple M4 / 16 GB，macOS 27.0（26A428）；torch 2.7.0、coremltools 9.0，FP16 MLProgram、macOS 15 最低部署目标。
- 原始模型为 [MSU EfRLFN 官方仓库](https://github.com/EvgeneyBogatyrev/EfRLFN)，固定提交 `1f7f3678f1bd7ba04ca8ccb04726eef71bf8520a`，MIT，Copyright 2026 MSU Graphics & Media Lab。
- [官方 x2 权重](https://drive.google.com/file/d/1VeoW94hN1X-8kxGXQSyR53YzRqF1htKQ/view) 1,968,047 bytes，SHA256 `fbfd1bb37973d2b8b53493c5b91c0ef106f74d200115250a8a025b8e6a121cb3`。本轮使用已有文件，不重新下载；源码及权重在加载前验证 SHA256，`weights_only=True`、`strict=True`。
- 全分辨率固定输入；720p→2560×1440，1080p→3840×2160。没有先缩小输入，没有 tiles，也没有训练或修改权重语义。
- 计时包含明确 sRGB 编码域的 CI→CVPixelBuffer 输入、同步 Core ML prediction、输出 CI→Metal 并等待完成。编译/加载单列；不含视频解码、音频、播放器调度。每条件 1 次首帧 + 3 次 warm，不能作为持续播放 FPS 或热稳定性证明。
- 与其他 agent 串行使用 GPU/ANE；未安装新依赖。新实验构建/图像/参考约数十 MB，模型各约 1–2 MB。

## 实测耗时

单位 ms；warm 为三帧完成时间，输入帧相同以核查可重复性。`.all` 表示允许 Core ML 选择设备，不代表所有设备同时跑满。

| 输入 / 网络 | computeUnits | 首帧 | warm 各帧 | warm 均值 |
|---|---|---:|---|---:|
| 1280×720 原图 | all | 159.36 | 123.58 / 120.57 / 123.52 | 122.55 |
| 1280×720 原图 | cpuAndGPU | 1055.23 | 442.26 / 447.91 / 437.63 | 442.60 |
| 1280×720 原图 | cpuAndNeuralEngine | 144.47 | 118.07 / 118.53 / 123.75 | 120.12 |
| 1280×720 ECA Conv2D | all | 147.37 | 120.85 / 120.09 / 120.81 | 120.58 |
| 1280×720 ECA Conv2D | cpuAndNeuralEngine | 147.88 | 120.42 / 119.13 / 125.23 | 121.59 |
| 1280×720 ECA Toeplitz | all | 147.77 | 123.05 / 123.10 / 123.53 | 123.23 |
| 1280×720 ECA Toeplitz | cpuAndNeuralEngine | 149.04 | 123.59 / 118.32 / 118.19 | 120.03 |
| 1280×720 64 通道补零 | all | 220.06 | 141.33 / 138.44 / 142.85 | 140.87 |
| 1280×720 64 通道补零 | cpuAndNeuralEngine | 224.23 | 145.96 / 145.54 / 137.91 | 143.14 |
| 1920×1080 原图 | cpuAndNeuralEngine | 437.66 | 320.53 / 320.72 / 321.61 | 320.95 |

24 / 30 / 60 fps 的整帧预算为 41.67 / 33.33 / 16.67 ms，且解码、呈现仍需预算。本轮最快 720p 条件约为 24 fps 预算的 2.9 倍；1080p 约 7.7 倍。约 2 ms 的短测差异不足以认定 ECA 改写有稳定加速。前日约 105 ms 的固定 720p 短测与本轮约 120 ms 有差异，因此不混用不同窗口数据声称改进。

## 计算计划：已有 ANE 支持，不是 GPU 开关遗漏

读取本机 SDK 的 `MLComputePlan.load`、`modelStructure`、`deviceUsage(for:)` 和 `estimatedCost(of:)`。保留每个 operation 的 supported / preferred device 和相对成本权重，详见 `results/*/plan-*.json`。

**这些是 Core ML 预测的调度和相对成本，不是采样得到的 GPU/ANE 利用率、实际逐算子时间或功耗。** 不能将“99.547% 预测成本由 ANE 承担”写成“ANE 利用率 99.547%”。

原图 `.all` 计划的非 const 节点：103 个优先 ANE、2 个优先 CPU、1 个未提供设备。已报告的相对成本中 ANE 约 99.547%，CPU 约 0.453%；与 `.cpuAndNeuralEngine` 的计划相同。`.cpuAndGPU` 的 106 个非 const 节点优先 GPU，实测明显更慢。

| 原图 all 主要算子 | 个数 | 合计相对预测成本 |
|---|---:|---:|
| convolution | 33 | 34.90% |
| tanh | 18 | 28.41% |
| residual add | 7 | 22.42% |
| attention multiply（ANE） | 6 | 8.04% |
| global reduce_mean | 6 | 4.74% |
| ECA transpose | 12 | 0.000023% |

因此移除 transpose 能简化图，却没有证据表明它是主要瓶颈。18 个 52→52、3×3 主卷积，仅在 1280×720 就有约 `18×1280×720×52×52×9 = 403.7G MAC`；中间 tanh 使它们不能直接等价融合成单个线性卷积。CPU+GPU+ANE 的异构执行也不是把同一个逐层网络自动无成本地切成三份。

## 三种等价优化及数值证据

1. **Conv1D→Conv2D。** 原 ECA 将全局池化结果变为 `[B,1,C]` 再卷积；改为 `[B,1,C,1]` 的 `(3,1)` Conv2D，沿通道索引使用同三项权重。去掉 6 个 squeeze、6 个 expand_dims。Core ML 总结构节点从 374 降至 350（含 const）。原始 FP32 对照：64×64 随机输入和 480×200 真实压缩帧均逐元素相同。
2. **Toeplitz 通道矩阵。** 全局池化后的 `y_c = Σ w_k·pool(x)_(c+k−1)` 可以写成稀疏的 52×52 pointwise matrix，边缘继续补零。把六个 ECA 的全部 12 个 transpose 去掉，总节点 326。随机输入 max_abs=0；真实压缩帧 max_abs=7.15e−7、MAE=5.21e−8（未 clamp 的 FP32 归一化域）。
3. **52→64 通道补零。** 将所有主干卷积的前 52 项权重/偏置原样保留，其余置零；新特征通过 tanh、残差和乘法始终为零。ECA 第 52 项看到的额外邻居仍为零，保持原边界语义；末层只使用原通道。随机输入 max_abs=4.77e−7，真人输入 max_abs=7.15e−7。尽管通道对齐更规则，所需主卷积计算增加，实测更慢，弃用。

三个模型均实际处理完整 1280×720 RGB8 图并输出 2560×1440。与原始 CPU FP32 参考比较：MAE **0.26569 RGB8 code**，p99 **0.68666**，max **1.09184**。三张 Core ML PNG 的 SHA256 完全相同：`1223f6da72173e57af39ab568cd6e8b2f7472044b2107c8b2a4ccefc270853d5`。测试图由原本的 480×200 电影静帧放大为 720p，只用于转换/色彩数值核验；它不是 720p 清晰度评价，也不是输入降采样加速。

输入/输出都指定 sRGB，不将 CI 的 linear working space 数值直接喂给 RGB8 模型。全套性能探针 first/last 同帧 hash 一致；以上证据不能代替真实电影的运动一致性、字幕细节和主观画质评测。

## 决策和可复现材料

- EfRLFN 的本机默认流式接入仍不通过。强行增加缓冲仅延后卡顿，不能补足长期每帧算力。
- `.all` 或 `.cpuAndNeuralEngine` 明显优于强制 GPU；保留 GPU 给呈现与轻量视频滤波可能更符合整体管线，但并发后的实际成本要在播放器测量。
- 三种精确图优化均归档，不作为生产性能提升宣传。未继续无限扩展量化/训练组合；若要显著更快，需要更小模型、经过验证的近似算法或新的时域复用策略，后者必须重新衡量画质，不能保持“数学等价”承诺。
- [复现脚本](../../scripts/experiments/efrlfn/performance-2026-09-29/README.md)、[原始与汇总结果](../../scripts/experiments/efrlfn/performance-2026-09-29/results/summary.json)、[数值对照](../../scripts/experiments/efrlfn/performance-2026-09-29/results/coreml-parity.json) 已保留在仓库；大模型/参考图保留在 `.build`，可用已有官方文件复现。没有修改生产代码或既有实验 helper。
