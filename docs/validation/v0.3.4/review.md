# v0.3.4 插帧与播放生命周期独立审查

日期：2026-09-29。范围为当前工作树的 `VideoSurface`、`LookaheadVideoDecoder`、`FrameInterpolator`、`InterpolatedFramePipeline`、`PlaybackController`、`QualityPerformanceController` 和 `EnhancementPipeline`。先进行只读审查，随后独占 GPU 窗口顺序重跑空间修复与 HDR 路由回归；另经主线授权，仅在 FrameInterpolator 实现连续输入转换缓存并做 A/B 验证。各类证据不能代替可见 60 fps AVPlayer 验收。

## 本次发现与修正复查

### P2：暂停后恢复可能沿用过期的插帧启动计时（已修正，静态复查）

`Sources/CinemaApp/VideoSurface.swift` 的 `tick()` 在 `interpolationWasActive` 退出分支清空队列、停止独立解码器并置空 `currentFrame`，但未清空 `interpolationStartedAt` / `interpolationClockOrigin`。暂停本身不改变播放 generation。恢复 1× 后，`tickInterpolated()` 因计时值非空而继续使用上一次启动时间；若首次启动到恢复已超过 25 秒，新一轮还未取得帧就会命中启动超时，固定回退片源帧率。

主实现者已在退出分支重置两项启动时间、完成/呈现窗口和对应 FPS 指标；已读取最终分支确认。动态验证仍应覆盖「插帧启动后暂停超过 25 秒，再恢复」及「先播放超过 25 秒，短暂停后恢复」。本次只读审查未发现其他未解决的阻断项，这不替代下述运行验收。

### P2：视图重建后 nativeOnly 必须清除尚未认领的 SDR output（已修正，静态复查）

主线确认反复移除/添加 output 会使当前 AVFoundation 主时钟回跳后，将 SDR output 改为 item 持有并跨原片/增强/视图重建复用。由此新增边界：新 view 自己的 output 为空，不能仅清该引用而遗漏旧 view 留在同一 item 中的 output。修正后的 `detachOutput()` 枚举本 item 的 `CinemaItemVideoOutput`；`attachItem()` 在 nativeOnly 时立即清除，asset nativeOnly 分支再次确认清除。测试补充“stop 留一个稳定 SDR output，再创建 nativeOnly view 必须同步清空、零增强提交”，HDR 零输出门禁未放宽。

### P2：停止视图的资产加载回调可能重新挂回 output（已修正并通过回归）

停止 timer/GPU 结果尚不足以停止此前异步轨道加载回调。原回调只检查 item 身份，而 stop 后旧 view 仍可能持有相同 weak item，进而在新 view 的 nativeOnly 清理之后重新添加 SDR output。主线在 stop 清空 item/assessed 并更新 nativeRouteToken。新增回归保留旧 view 的强引用，在轨道任务执行前立即 stop，并创建 nativeOnly replacement；等待后仍为零 output，已通过。

## 已复查的修正与合同

- **有界等待**：已有正常播放时钟后启动 25 秒预热超时；已显示插帧画面后落后主时钟超过 120 ms 则回退源帧率。网络未提供未来帧、模型未及时就绪和解码错误有明确退出路径。主播放器自身尚未进入播放状态时继续显示原生画面，这与增强预热超时是两个状态。
- **时钟隔离**：独立解码器用同一 asset 创建新的 item 和静音 AVPlayer；读取的仅是该播放器当前时间，未从主 item 取未来帧，也未对主播放器 seek、调速或延迟音频。独立 lead 超出 0.12–0.45 秒时重定位到主时钟前 0.30 秒；重定位改变 discontinuityID，供 surface 丢弃旧参考和排队结果。这个合同的真实流媒体表现仍需运行验证。
- **解码器停止**：`resetInterpolationQueue()`、`showNative()`、`stop()` 及退出 60 fps 分支均调用 `lookahead.stop()` 并解除引用。原片对照、HDR/native permission、暂停、变速、同帧对照和 settings/seek reset 能到达这些路径。`stop()` 同时暂停 secondary player、取消 seek、移除 video output、清空 current item；延迟 seek 回调用 token 与 stopped 双重拒绝，不能再次启动已停止的解码器。
- **过期结果**：worker 完成回主线程后核对 revision 与 item；source/settings/seek、decoder discontinuity 和原生路由改变 revision。旧 GPU 工作无法同步取消，但其结果不能替换新时间线。每个中间帧拥有独立缓冲和纹理，独立 helper 验证保留旧输出后继续处理，像素未被后续帧改写。
- **有界缓存**：原始前瞻队列最多 12 项，过期源帧先淘汰；处理结果只接受主时钟前 40 ms 到后 400 ms 的窗口。输出队列达到 24 项后停止新增处理。一批可能使数量略超过 24，仍有每批最多 8 个中间帧的上界；不是无限延迟队列。
- **字幕/柔化**：启用局部柔化时暂不进入插帧路径，保留原有几何一致性检查和字幕保护逻辑；避免在不同帧/变换几何下重绘选区。切镜检查拒绝跨镜头变形，离开 60 Hz 格点的源锚点不会额外塞入稳定输出序列。
- **分辨率**：明确选择的 1080p/4K 目标用于所有处理模式，横竖屏保留比例。FRC 支持上界在生产和自检均为最长边不超过 1920、总像素不超过 1920×1080。超出明确报错，不暗中缩小输入冒充原尺寸测试。修复模式降采样走平滑滤波，只有放大才使用 DetailScaler。
- **颜色与 alpha**：源帧先过 ColorFrameGate；PQ/HLG/HDR 保留系统原生路径。FRC 只接已转正的 SDR，使用带 sRGB/709 标记的 RGBAHalf 输入和输出，最终以相同 sRGB 纹理合同显示。此前普通 FRC 探针检查过全部像素的有限性与 alpha；没有沿用高质量超分探针遇到的非有限 alpha 输出。当前自检亦检查透明度及动态范围。未将 SDR 插帧描述为 Dolby/HDR 增强。
- **独占自检**：全局 `NSRecursiveLock` 同时覆盖普通 pipeline、完整插帧 batch 和整个自检。自检的锁等待发生在测量外；内部递归进入空间处理不会死锁。取消标志在取得锁后及每帧之间检查，不能强行中断系统已提交的一帧或模型加载。
- **预算边界**：插帧 batch 的计时覆盖空间处理、切镜预览、FRC 与最终输出 GPU 完成；session 初始化单独记录，首个真实 FRC 标记为预热。每输入源帧可能产生多个输出，故用源帧间隔预算（24 fps 为 41.67 ms），不是把整批错误地比较 16.67 ms。自检 3 次预热后采 30 个源间隔，CPU 样本生成及正确性读回在计时外。
- **基准测试恢复**：PlaybackController 捕获测试前播放意图并暂停；测试完成只在 itemID 和 playbackIntentID 未被用户操作改变时恢复，避免自动播放另一个条目或覆盖用户的暂停选择。
- **呈现指标**：已将 UI 的“最近呈现”改为 drawable `addPresentedHandler` / `presentedTime` 的独立计数；GPU command completion 仍保留为完成绘制计数，并明确不是物理屏幕扫描。不同指标没有把源帧处理数或 60 Hz timer 当成真实 60 个运动补偿画面。
- **稳定 SDR output 与 HDR 隔离**：原片模式停止增强提交并恢复原生显示，但允许保留同一 item 的一个稳定 SDR output；跨模式反复 remove/add 已被独立主时钟实验证明会产生 TimeJump。surface 停止后 timer 与 secondary decoder 均停止，主 output 由 item 持有并可在视图返回时复用，不形成新的 decoder/轮询线程。HDR/nativeOnly 则必须清空全部所属 output、清除增强帧并隐藏增强层，不能套用 SDR 保留规则。

## 运行证据与尚未完成的验收边界

空间修复 `streaming-restoration.json` **35/35** 通过，覆盖时域生命周期、尺寸变换、4K 输出、HDR 拒绝和柔化保护像素。最新稳定 output 合同的 HDR 回归 `hdr-render-stable-output.json` **32/32** 通过，命令为 `bash scripts/validate-hdr-render.sh docs/validation/v0.3.4/hdr-render-stable-output.json green`，exit 0；覆盖 headless 实际 AVPlayer 的 SDR、PQ/HLG、权限撤销、晚到 GPU 结果拒绝、原片切换、故障恢复、本地 SDR HLS，以及新增的视图重建/停止竞态。原片断言改为稳定单 output + 不提交增强 + 媒体位置不回跳；所有 HDR/nativeOnly 零 output 断言保留。旧 `hdr-render.json` 27/27 是生命周期修改前结果，仅供历史追溯。它们不验证真实 Dolby 母版效果、音响设备或可见屏幕 60 fps。

`frame-interpolation.json` 为生产 helper 的 15/15 验证：640×360、24 fps 合成源在 1 秒前输出精确 60 个全局格点，其中 48 个运动补偿帧；生成帧不等于复制或混合。在可解析运动真值上，ROI MSE 为 2.431，线性混合为 241.615，复制前帧为 423.760。覆盖 streamID 改变、后跳、切镜、输出所有权，以及同 PTS 真实影片原片/修复证据。这只证明生成质量和时间戳合同，不证明 AVPlayer 已持续呈现 60 fps。

输入缓存改动后的同一生产 helper 回归另存 `frame-interpolation-cached.json`，**15/15**、exit 0。完整 1080p 链 ABBA 另存 `frame-input-cache-abba.json`，**4/4**：中间帧与未缓存版本逐字节相同，重置后相同，每轮 19/19 个连续对命中，输入转换从 40 次降到 21 次。各轮均值 46.56/39.76/52.83/45.56 ms，未缓存与缓存聚合均值 46.06/46.30 ms，不能宣称稳定提速；仅确认消除了冗余转换且未改变所测像素。计数置于 scratch 源码副本，未给生产增加测试字段；源文件归档 `native-frame-rate/cache-optimization/`。

最终 motion-ready 修正将真实中间帧标记为 `isInterpolated`，源参考默认 false，tagged 输出保留标记；surface 过滤过期帧后，只凭剩余的真实中间帧进入就绪状态。`frame-interpolation-final.json` **16/16**、exit 0，包含新增标记一致性检查。该次交接期间另一测试命令已启动，无法完全排除 GPU 时段重叠，因此仅引用正确性，不将其计时用于性能结论；JSON 已加明确备注。

缓存修改前 `quality-performance.json` 已复跑并读取：16/16 项通过。1080p 自然降噪 + FRC 平均 32.38 ms、P95 42.87 ms，30 个源间隔有 2 个超过 41.67 ms，输出 75 个 60 Hz 格点，其中 60 个为真实插值。4K 修复（不插帧）平均 18.38 ms、P95 21.34 ms，30 个源间隔没有超预算。首轮计数失败的原因为合成 PTS 用浮点构造时 26/24 被截到 64999/60000；修正为整数时基四舍五入后重跑，未修改生产 helper 或放宽断言。失败首轮另存 `quality-performance-truncated-fixture-time.json` 供追溯。

最终缓存/就绪元数据代码的独占自检另存 `quality-performance-final.json` / `.log`，**16/16**、exit 0。测试期间没有另一个播放测试或 SwiftPM 构建：1080p 自然降噪 + FRC 平均 **28.90 ms**、P95 **37.66 ms**，0/30 个源间隔超出 41.67 ms，75 个格点含 60 个真实插值；4K 修复（不插帧）平均 **18.08 ms**、P95 **20.94 ms**，0/30 超时。本次合成短测低于源帧预算，但与此前轮次存在差异，既不能归因全部来自缓存，也不能将其表述成持续播放或屏幕稳定 60 fps 认证。

真实 AVPlayer + 独立静音前瞻解码 + 可见窗口的持续表现、HLS 网络与切换/暂停恢复验收由播放验证执行者单独负责；锁屏或没有 drawable 的运行只能证明计算路径，不能证明屏幕 60 fps。

## 最终普通播放回归与发布表述

独立显示队列完成后，已顺序运行更新后的 `validate-restoration-playback.sh`，720p 与 1080p 两个输入均 **14/14**、exit 0。报告为 `restoration-playback-1280x720.json` 与 `restoration-playback-1920x1080.json`。均检查真实 3840×2160 输出、暂停 seek、原片对照保持同一 SDR output/位置不跳/零新处理，以及回到修复模式。3 秒短窗口的完成计数如下，不能读作物理显示帧率。

| 输入与模式 | 实际输出 | 采样处理均值 | 每媒体秒完成源帧 |
|---|---|---:|---:|
| 720p 时域降噪 | 1280×720 | 11.48 ms | 24.06 |
| 720p 流式修复 | 3840×2160 | 23.09 ms | 24.24 |
| 1080p 时域降噪 | 1920×1080 | 17.29 ms | 23.69 |
| 1080p 流式修复 | 3840×2160 | 23.51 ms | 23.78 |

最后只读确认：显示使用独立 MTLCommandQueue 和 CIContext，读取的是 worker 已完成且后续不修改的纹理，色彩空间保持 sRGB 合同；无需把尚未完成的跨队列写操作交给显示。未发现新的所有权或生命周期阻断项。

UI 根据 macOS 26 与 VT API 支持情况开放“60 fps目标（实验，可能回退）”，并重复说明本机自检不等于稳定播放；选择按钮为“尝试1080p60（自然降噪）”。`FrameBudget` 未放宽：按源帧周期计算，超时累积 +1、正常帧 -1，达到 10 回退。720p 先前试验生成 28 个中间帧后因未来帧未及时就绪回退，最后 motion-ready 重测又在 32 个生成帧后触发预算回退（12/15，主时钟 0 次跳变）。最后独占 1080p 确认同样出现预算回退（13/15，约 24.58 个完成绘制/秒，主时钟 0 次跳变，drawable 呈现回调为 0）；已读取 `report-1080p-final.json` 的失败项。一次可能与另一命令重叠的 1080p 15/15 未被复现，不能作为稳定性结论。720p 与 1080p 的持续 60 fps 都尚未通过，不能拿一轮合成自检覆盖这些真实播放边界。

## 后续性能方向（不扩大本轮实现）

优先分析整条链的 source interval，而非仅 FRC 内核：双路解码、CI 读回切镜预览、RGBAHalf 转换和最终纹理呈现都占预算。可先保持 1080p 自然降噪方案，减少无必要的重复颜色转换及每帧同步读回；优化必须重验同一运动/颜色/字幕样本。4K 普通 FRC 短测约 96.5 ms/两中间帧的证据不支持实时 24→60，因此当前拒绝 4K60、保留 4K 源帧率是合理边界。不能把重复显示或透明混合帧作为性能替代后继续宣称运动补偿插帧。
