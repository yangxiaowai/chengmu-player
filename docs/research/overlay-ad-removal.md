# 画面广告文字/网址/贴片处理调研

日期：2026-09-27。已只读检查 `VideoSurface.swift`、`EnhancementPipeline.swift`、`PlayerView.swift` 与字幕相关调用。本文保留调研建议，并在“最终实现取舍”记录实际落地方案；验证结果见 v0.2.3 验收记录。

## 推荐范围

V1 默认关闭；用户在暂停画面人工圈选广告区域，预览后启用。可提供局部模糊/遮挡和邻域填补，但应明确是隐藏覆盖内容，不能恢复广告下未知的真实背景。固定圈选无法保证跟随移动广告；全屏广告插段不能用局部滤镜解决，也不能自动跳过而假定不误删剧情。

字幕优先：默认底部保护带，再允许用户额外圈定顶部/中部硬字幕保护区。广告处理区及其羽化/采样边距若与保护区重叠，直接拒绝该选区，不自行裁掉字幕。硬字幕位置未知时，默认底部带不是“全片字幕绝对保护”的证据；移动字幕或广告重叠字幕应保留原画。无法可靠区分时不得自动删除。

## 成熟方法及证据

| 方法 | 官方支持的行为 | 适合本工程的边界 |
|---|---|---|
| FFmpeg `delogo` | 用矩形周围像素插值；参数 x/y 为左上角，w/h 指范围；官方明确提示结果可能难看 | 静态小Logo可试，纹理/运动背景可能涂抹。不是内容识别或真实背景恢复 |
| FFmpeg `removelogo` | 以同视频尺寸bitmap指定Logo像素，再用邻域像素填充；mask过大会破坏更多信息并增加开销 | 需要准确mask，不自动识别广告/字幕；改AVPlayer为转码链增加整合和延迟成本 |
| Core Image Gaussian blur＋裁剪/合成 | 官方提供高斯模糊；clamp可避免边缘透明采样；crop限定图像区域 | 现有Metal/CIContext内组合局部效果，避免CPU读回。模糊未必让大字完全不可读；需人工预览或遮挡选项 |
| Vision `VNRecognizeTextRequest` | 发现并识别图中文字，提供语言及速度/精度参数 | 只能作为可选候选框辅助；OCR并不证明这是广告，也不保证找全硬字幕。不逐帧默认运行或自动删除 |

一手链接：[FFmpeg delogo](https://ffmpeg.org/ffmpeg-filters.html#delogo)、[FFmpeg removelogo](https://ffmpeg.org/ffmpeg-filters.html#removelogo)、[Apple Gaussian blur](https://developer.apple.com/documentation/coreimage/cifilter-swift.class/gaussianblur())、[clampedToExtent](https://developer.apple.com/documentation/coreimage/ciimage/clampedtoextent())、[cropped(to:)](https://developer.apple.com/documentation/coreimage/ciimage/cropped(to:))、[Vision OCR](https://developer.apple.com/documentation/vision/vnrecognizetextrequest)。Apple页面通过其官方Markdown版本核对内容。

## 当前内核接入点

- `EnhancementPipeline.process` 已将 CVPixelBuffer 包装为 CIImage，应用 preferredTransform 并将 extent 原点归零。最终选择在 Apple AI / 去噪 / Lanczos / 锐化完成后，应用显示方向的归一化选区；避免局部变化通过增强算子扩散到保护区。GPU图像链延续到现有输出纹理，不添加每帧FFmpeg进程、PNG文件、CPU位图往返或独立全帧OCR。
- 关闭广告处理时应完全绕过额外滤镜。开启后只处理选区及必要边距，复用现有context/device/queue。CIImage惰性组合不等于零开销；同一frame最终GPU完成时间仍要计入FrameBudget。
- `VideoSurface.tick` 目前 `.original` 直接走 AVPlayerLayer；去广告是独立开关，若启用，即使增强mode为原片也须进入图像处理路径。增强/去广告失败回退AVPlayerLayer会恢复原广告，应显示状态，不能声称回退期间广告仍去除。
- worker串行、最多一帧在途，已有revision和迟到帧丢弃。更改选区/保护区必须改变revision或配置快照，防止旧结果覆盖新预览。不要把可变配置直接在worker与主线程共享。
- `PlayerView` 的 SwiftUI 字幕在 VideoSurface 之后叠加；继续保持软字幕最后独立绘制。`PlaybackController` 有legibleOutput和外部字幕，不能把这些文字烘进待修复视频帧。硬字幕在视频像素内，只能靠明确保护范围避开。
- 不改变原始媒体、PTS、音轨、字幕文件；处理只影响呈现。选区绑定当前item/分集，换集/换源/视频方向变化默认清空或禁用并重新确认。seek清旧帧；静态选区可保留在同item，但按时间启用的范围必须重新判定，不能沿用旧时刻结果。

## 坐标转换与边缘

建议UI存储“显示方向、视频有效画面、左上角原点”的归一化 CGRect，取值0…1。先计算resizeAspect的实际内容矩形并剔除黑边；不能直接用全View矩形归一化。SwiftUI坐标以points计，MTK drawableSize是像素，二者不可混用。AppKit NSView默认未翻转时y原点在下方；若用SwiftUI拖拽坐标需显式约定。

变为现有原点归零的Core Image坐标时，若规范输入左上角为(x,y,w,h)、图像尺寸W×H，则像素框为 `(xW, (1−y−h)H, wW, hH)`。只翻转一次；不要再对已经应用preferredTransform的图像反转旋转。旋转后的W/H而非编码buffer的W/H是选择基准。输出放大仍由同归一化矩形推导，防止4K和Apple1.5倍率错位。

blur输入先clamp避免黑边，再对局部效果crop并合成到原图，最终extent严格保持原尺寸。mask的羽化会扩大实际改动范围，保护检查必须包含羽化范围；若从保护带采样也会把字幕拖入填补区域，保守拒绝采样邻域触及保护区。矩形边缘、角落或可用邻域不足应拒绝填补或改遮挡，不能读取图像范围外假定有背景。

## 最小验证（应由实现者执行）

1. 生成或使用有权处理的测试卡：四角彩色标记＋广告矩形＋底部/顶部/中部硬字幕；无去广告时校验原图，启用后校验仅批准修改区变化、保护区像素不变。比较同一增强模式启用与关闭柔化的最终输出；全帧缩放/锐化自身会改变像素，不能把增强后输出直接与原片比较并归因于柔化。
2. 16:9/4:3黑边、90°旋转、窗口缩放/全屏、Retina points↔pixels、GPU4K及AppleAI倍率，分别检查选区落点和字幕未遮住。裁到黑边、越界、保护带边界接触/羽化重叠必须拒绝。
3. 同时切换原片/增强/去广告、拖动seek、切集/换源；确认旧revision结果不回写、保护及选区状态不会串集，软字幕最后正常显示。
4. 10秒720p/1080p运动片段比较额外GPU完成耗时、p95、掉帧与音画同步，再持续播放检查预算和回退；只运行现有GPU benchmark不能证明实际音画同步或整集实时。
5. 检查大字/移动URL是否仍可辨读、复杂背景涂抹、填补/锐化后文字残影。结果不可接受时应关闭该区域或改遮挡，不宣称无痕修复。

限制：本调研未验证滤镜性能、背景修复质量、OCR分类准确率或真实影片字幕保护。首版人工选区＋明确保护区能给出可审查的行为边界，不能解决所有移动广告/重叠硬字幕/广告插段。

## 最终实现取舍

实际代码选择在增强之后进行局部柔化，再严格裁剪回广告矩形，避免广告像素变化经去噪/超分影响保护区。比较基准是同一增强模式未启用柔化的输出，不是声称所有增强模式与原始解码像素完全相同。默认原片模式启用柔化也走GPU路径。遇到非方形像素、特殊clean aperture或显示比例不一致时拒绝柔化并显示原片；不猜测选区坐标。用户已选择手动框选方案，不增加自动OCR分类。
