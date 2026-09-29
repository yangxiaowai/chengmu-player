# 真正60fps：本机运动补偿插帧调查（2026-09-29）

本机 Apple M4 / macOS 27 的普通 VideoToolbox FRC 可以生成独立、位置正确的运动中间帧。短样本中，1080p 每对源帧生成两个相位约25.67ms，4K约96.49ms。因此首个实际候选是 **1080p、24→60fps、后台预热、至少一张源帧的前瞻缓冲**。这些是处理完成探针，不等于播放器已经持续呈现60fps；还必须完成调度、解码前瞻、音画同步与实际呈现计数验证。

## 三种“60”不能混淆

- 60Hz屏幕刷新或每秒调用60次draw，可以重复同一视频帧，不代表60张独立运动画面。
- 每秒处理60张原生60fps源帧，是处理吞吐量；不会把24fps内容变成60fps。
- 24→60fps需要在均匀的目标时刻生成新画面。本方案的目标PTS为全局`k/60`：第一对24fps源帧的相位是0.4、0.8，第二对是0.2、0.6。每两个源间隔输出5个网格时刻；奇数24fps源anchor未落在60网格，不能再额外插入，否则会变成不均匀72fps输出。

## SDK接口和实机能力

核对本机 `/Library/Developer/CommandLineTools/SDKs/MacOSX.sdk/System/Library/Frameworks/VideoToolbox.framework/Headers/` 中的 `VTFrameProcessor_FrameRateConversion.h`、`VTFrameProcessor_LowLatencyFrameInterpolation.h` 及Swift overlay。

普通 `VTFrameRateConversionConfiguration` 有 `.normal` / `.quality`，没有叫 `LowLatencyFrameRateConversion` 的类；真正低延迟类叫 `VTLowLatencyFrameInterpolationConfiguration`。Apple区分面向高质量编辑的FRC与面向实时视频的低延迟插值，实际选择仍需本机测试，见 [WWDC25官方介绍](https://developer.apple.com/videos/play/wwdc2025/300/)。

普通FRC在本机 `isSupported=true`，输入/输出格式为`RGhA`（RGBAHalf）。查询配置验证64×64、640×360、720p、1080p、4K及8192×4320可创建，8193宽不可创建；可选minimumDimensions/maximumDimensions属性返回nil，因此不能从它们猜最小尺寸。SDK标明macOS最大8192×4320。参数要求当前源帧、下一源帧、相位数组和对应独立输出缓冲；`usePrecomputedFlow=false`由处理器内部算光流。`.random`清内部序列缓存，`.sequential`保留连续序列优化。[官方配置入口](https://developer.apple.com/documentation/videotoolbox/vtframerateconversionconfiguration)、[参数入口](https://developer.apple.com/documentation/videotoolbox/vtframerateconversionparameters)。

这里的配置没有高质量SR那样的显式模型下载接口。本次未调用下载方法，会话成功建立；这不等于已审计操作系统全部内部资源获取。普通FRC会话建立约8–10秒，不能在主线程初始化。

低延迟插值本机也支持；macOS27正式能力query返回纯时间插值最大单边1920、最大像素2073600，联合×2空间插值最大单边640、最大像素230400。它的init即使对4K也会返回配置，**不能把init非nil当作支持证明**。低延迟格式是8bit视频范围`420v`；360p要求额外底部8像素padding，必须使用配置返回的属性建池，否则可能提交一个成功完成却没有有效输出的命令。隔离探针修正padding后再记真实结果。

## 真实中间帧与完成时间

使用独立合成夹具：深灰静止背景上平移带棋盘纹理的物体，知道任意相位的解析真值。每对24fps源帧生成两个实际相位；等待VT回调，输入提前转好RGBAHalf，计时包含内部光流和两个输出，不含输入转换、读回、解码、降噪、显示。各分辨率依次运行，未与其他GPU任务重叠。

| FRC输入 | 冷首对 ms | warm对数 | warm每对均值 ms | warm范围 ms |
|---|---:|---:|---:|---:|
| 640×360 | 144.13 | 5 | 12.16 | 11.16–14.07 |
| 1280×720 | 107.42 | 7 | 27.35 | 25.99–28.59 |
| 1920×1080 | 84.18 | 7 | 25.67 | 22.91–29.33 |
| 3840×2160 | 271.11 | 3 | 96.49 | 91.81–101.97 |

样本少，不能把这些分位数当长期热稳态保证。720p比1080p略慢仅是本次结果，不推断算法在所有尺寸的复杂度单调关系。24fps每源区间预算41.67ms；1080p尚有约16ms平均余量，后续增强/颜色转换/呈现必须一起计算。4K单独FRC已超预算，因此不作为实时候选。热机不是长期热稳态，本轮没有进行温控压力测试。

1080p的0.4相位预期质心946.745，输出946.500；相同ROI内MSE：运动插帧4.94，直接复制左帧2391.99，普通像素混合2080.98。输出逐像素既不等于左帧也不等于混合帧，且显著接近运动真值。这是运动补偿证据，不只是统计“提交了新纹理”。RGB与alpha均有限；没有重现高质量SR输出alpha NaN问题。诊断代码仍把alpha写1再呈现，但统计已确认原alpha无非有限值。

低延迟路径修正padding后的短测：360p单0.5相位约1.68ms；720p两相位约13.15ms；1080p单0.5相位约11.85ms，而1080p相位0.4/0.8约45.00ms。后者ROI MSE约874/804，明显高于普通FRC的解析运动误差；相位0.8的观察质心相当于约0.751。不能声称低延迟API满足任意相位高质量24→60。它可能适合后续原生30→60单中间帧，但本轮生产候选收敛到普通FRC。

所有原始小探针、JSON与棋盘PNG保留在 `.build/frame-rate-probe/`，并归档于 `docs/validation/v0.3.4/native-frame-rate/`：`main.swift/results.json`、`4k.swift/4k-results.json`、`low-main.swift/low-results.json` 与能力查询。原始JSON的p95是低位次序统计，短样本结论请使用上表均值/范围而非推断稳态。

## AVPlayer前瞻与同步：实测发现消费游标

本地24fps `clean-film.mp4`，主线程runloop驱动AVPlayer，不建立UI；20次请求`currentTime+80ms`：**20/20获得实际未来PTS**，通常领先播放器约40–80ms。

但同一`AVPlayerItemVideoOutput`取未来后立刻再请求当前PTS，**20/20返回nil**；后续当前时刻请求也13/20为nil。它不是无副作用的随机帧查询。不能在原有当前帧轮询旁加一个“取未来”分支。直接跳到+80ms还会跳过中间源PTS，例如0.375→0.458333漏掉0.416667。

实际接法必须由一个消费者沿时间轴逐帧单调预取、按返回的真实PTS去重并保存有界源队列，再把相邻源帧送入FRC，最终由播放器媒体时钟选择有序60网格呈现队列。不要给画面偷偷增加80ms延迟而继续播放原时间音频。可以在启播/seek阶段暂停时钟完成预热/首段缓存；运行中lookahead不足必须明确退回源帧率。这个本地文件结果不保证HTTP/HLS/DRM资源可以同样前瞻，网络重缓冲与变帧率需单独处理。

证据：`.build/frame-rate-probe/future-output.swift`、`future-output.json`。`copyPixelBuffer`在macOS27已提示使用新`pixelBufferAndDisplayTime`接口，但此实验故意测试当前播放器使用的旧API合同。

## 最小生产封装与验收

`FrameInterpolator.swift`独立封装RGBAHalf普通FRC，后台串行初始化；输入两张已转正且已过SDR门禁的CIImage、各自CMTime和相位数组；输出CIImage分别持有独立像素缓冲，等待实际完成。时间逆序/跨度异常/尺寸错误拒绝，顺序断裂用`.random`清缓存。`reset()`不强行终止已提交工作，调用方仍须按播放revision丢弃过期结果。

`InterpolatedFramePipeline.swift`复用既有EnhancementPipeline，先按目标尺寸增强源帧，再只生成`k/60`目标时刻；第一张参考帧和首次FRC调用标预热。处理ms计入增强、光流、插帧及最终纹理完成，单列会话加载成本。上限为1920单边且2073600像素，含portrait。片源/尺寸/模式/选区/时间跳变清参考；64×36 RGB差分检测切镜/大范围变化，不跨镜头生成morph。切镜处可保留落网格的真实源帧，不能伪称运动插帧完整连续。

独立验证脚本 `scripts/validate-frame-interpolation.sh` 覆盖24fps一秒→60个网格时刻、源anchor不额外混入、插帧像素与复制/混合不同、保留输出所有权、时间跳转和切镜。真实影片同PTS原片/增强PNG仅证明对应位置的实际画质路径，不作为插帧或4K重建证明。播放器持续呈现与音画同步由主线独立验收，不能用本文件内核计时代替。

最终独立helper验证 **15/15通过**，报告 `docs/validation/v0.3.4/frame-interpolation.json`：24fps一秒内精确60个网格点（48个运动补偿中间帧、12个源落点），运动真值ROI MSE2.43 vs混合241.62/复制423.76；重复处理后旧输出像素不变，seek/切源/切镜均通过。`frame-interpolation.frames/`保留解析运动和真实影片PTS1.0原片/时域增强PNG。

生产调度采用独立静音 `LookaheadVideoDecoder`，不再与主 output 共用前瞻消费游标。直接 copy 探针证明的是“未来帧读取会消费 output 游标”，不能据此推断主播放时钟倒退。主线随后独立复现的倒退根因是反复 remove/add 同一个主 item 的 output：5 秒墙钟内媒体只前进约 0.085 秒，并出现 18 次 TimeJump；稳定保留同一 SDR output 后，双解码器对照 5 秒约推进 5 秒且 0 次 TimeJump。两类证据不可混写成同一因果关系。

前瞻 helper 复用 asset 创建独立 item 和 10bit 输出，secondary 只读自己的当前时间，目标领先主 clock 0.30 秒；它不调用主播放器的 seek/play。每次内部 seek 更新 discontinuityID，caller 清缓存；网络无法前瞻由 surface 有限超时回退。HDR/nativeOnly 必须移除所属转换 output，SDR 原片/增强切换则保持同一实例。实际双播放器时钟和可见帧率以主线测试报告为准，不由本地 20 次 copy 结果推断。

## 连续输入转换缓存：消除冗余，不虚报提速

`VTFrameProcessorFrame.h` 明确帧对象持有底层 CVPixelBuffer；`VTFrameProcessor.h` 规定异步回调后本次输入/输出处理完成，FRC sequential 接受连续呈现顺序。生产 `FrameInterpolator` 因而缓存已完成一对的 current 帧，在下一对 previous PTS 连续且是同一个 CIImage 对象时复用其 RGBAHalf 输入。相同 PTS、不同对象不复用；reset/失败清空。缓存持有的缓冲不被重写，输出仍独立分配。

1080p 自然降噪 + 完整插帧链的 ABBA 短测（每轮 21 源帧，前 3 帧不计稳态）确认 20 对输入的转换次数从 40 降到 21，19 个连续对全部命中；中间输出与未缓存基线逐字节一致，reset 后结果也一致。但源间隔均值按 A/B/B/A 为 46.56/39.76/52.83/45.56 ms，聚合平均 46.06→46.30 ms，波动不支持“稳定提速”的说法。保留改动的依据是消除已证实的重复转换且像素不变，不能把转换次数下降当作端到端帧率提升。该短测包含空间处理、预览、FRC、最终纹理完成，不含解码或 draw/present；它也不能单独确认呈现队列阻塞是全部开销来源。证据：`docs/validation/v0.3.4/frame-input-cache-abba.json`。
