# 连续输入缓存 ABBA

实际执行的是 `full.swift`：1080p 自然降噪 + 完整 InterpolatedFramePipeline，A/B/B/A 顺序，各 21 源帧，前 3 源帧作为预热。基线取自缓存改动前的 FrameInterpolator；Measured 副本只加转换/缓存计数，并没有修改生产类以适应测试。两个 helper 副本仅重命名类型并暴露测试读取计数的引用。

结果：上级目录的 `frame-input-cache-abba.json` / `.log`。4/4 正确性检查通过：输出逐字节一致，reset 后一致，连续对 19/19 命中，转换 40→21。完整处理均值有明显轮间波动，聚合 46.06→46.30 ms，不支持稳定提速结论。报告不包含 AVPlayer 解码、VideoSurface 绘制或呈现。

构建需当前工程 CinemaCore 模块，以及生产 VideoProcessingPolicy、DetailScaler、TemporalRestorer、EnhancementPipeline。编译这四个生产 Swift 文件及本目录两个 Measured FrameInterpolator、两个 helper 副本和 full.swift，使用 macOS 26 / Swift 5 / -O。勿同时链接未计数的 FrameInterpolatorBaseline.swift；它仅保存原始实现供审计。可运行已编译程序并传入 JSON 输出路径。没有归档二进制。
