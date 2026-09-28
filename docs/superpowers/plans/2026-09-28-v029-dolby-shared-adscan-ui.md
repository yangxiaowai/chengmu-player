# v0.2.9 实施计划：片源适配杜比、增强内嵌广告识别、界面完善

**目标：** 在 v0.2.8 基础上完成三件事，并按片源（而非按文件名或分辨率）决定实际处理。
**架构：** CinemaCore 负责清单/码流证据的纯解析；CinemaApp 负责原生与增强路由、媒体检查、共享帧广告识别和界面。
**技术栈：** Swift 5 / macOS 15+、AVFoundation、CoreMedia、CoreVideo、Vision、Metal/CoreImage、SwiftUI；无第三方依赖。
**设计与调研：** [杜比设计](../specs/2026-09-28-source-aware-dolby-design.md)、[杜比可行性](../../research/dolby-feasibility-2026-09-27.md)、[广告设计](../specs/2026-09-27-local-ad-skip-design.md)。

## 范围

### 一、按片源适配杜比视界与杜比全景声

1. **证据层（Core）**：`HLSMediaDeclarations` 保留最外层主清单的全部 `EXT-X-STREAM-INF`（`VIDEO-RANGE`、`CODECS`、`SUPPLEMENTAL-CODECS`、`AUDIO` 组）与 `EXT-X-MEDIA` 音频 rendition（`CHANNELS="16/JOC"`、`NAME`、`LANGUAGE`、`DEFAULT`、`URI`）。`DolbyMetadata` 解析 `dec3`（E-AC-3 扩展：JOC/Atmos）与 `dvcC`/`dvvC`（Dolby Vision 配置盒）。普通 HEVC、4K、`ec-3`、名字含 "Atmos" 一律不能单独成立。
2. **判定层（App）**：`MediaExperienceInspector` 读取当前 item 的实际视频/音频轨道与格式描述、HLS 变体切换事件，只在证据成立时标记“正在原生播放杜比视界/全景声”。清单里存在 ≠ 正在选中。
3. **呈现层**：明确 DV/HDR 与未知色彩走 `AVPlayerLayer` 原生层，不挂 8 位增强输出；只有确认 SDR（709/sRGB 传输函数与色原色）的帧进入现有增强。增强输出改为 10bit 广色域纹理，非 8 位 sRGB。许可撤销时立即移除输出并作废在途 GPU 结果，不重建 item、不打断时钟。
4. **音频层**：保留原轨与系统解码，不注入 `audioMix`，不做下混；自动模式下允许多声道空间化，可切“保持原声布局”。双声道不被包装成全景声。
5. **说明层**：播放页“视听适配”面板分层显示片源声明、当前选中、系统能力与实际决策，无法测量的部分明确写“未验证”。

### 二、图像增强与广告识别共用解码

现状：广告识别自带独立 `AVPlayer`/`AVAssetImageGenerator` 解码器，每 2 秒重新解码一次，与主播放和增强各解码一遍。用户要求“边增强边识别”，以减少等待与开销。

1. 增强路径在取样时刻把同一张已解码帧渲染成 960×540 缩略图，交给 `AdSkipController` 作为观察帧；不再为同一时间点启动第二次解码。
2. `AdFrameAnalyzer` 新增共享帧入口；OCR、分类、区间构建规则不变（复用同一 `AdTextClassifier`/`AdSegmentPolicy`）。
3. 无增强输出（原片模式、杜比/HDR 原生、取帧失败、用户关闭增强）时自动回退到现有独立解码路径，功能不降级。
4. 共享帧只在允许分析的时刻取样（播放中、非暂停/缓冲/拖动、未超预算），不改变主播放时间轴与声音。

### 三、界面完善

统一设计令牌（层级、圆角、描边、强调色、动效时长），重做播放页状态区、片库网格与详情/设置页的排版与层次；新增“视听适配”面板；保持既有交互与可达性不变。

## 任务

- [x] Core：`DolbyMetadataTests`、`HLSDolbyDeclarationsTests` 与清单解析；152 项 Core 测试通过。
- [x] Renderer：`VideoProcessingPermission` + 逐帧色彩门禁 + 原生层路由 + 10bit 输出；18 项 HDR/未知色彩检查通过。
- [x] App：`MediaExperienceInspector`、`PlaybackController` 音频策略与片源状态、`sourceInfo` 绑定。
- [x] UI：视听适配面板与设计令牌改版。
- [x] 共享帧：当前帧共用、前方预读、9 项组合回归与 10 项广告播放回归通过。
- [x] 验收：Apple 官方样本声明只读探测、合成 HDR 路由、全量 Core/smoke、原生 UI 隔离验收；实际杜比内容播放仍未确认。
- [x] 发布：v0.2.9/build11，README、验收记录、本地签名与 ZIP 完整性校验；未干扰用户正在播放的影片。

## 边界

- 不把硬件能力写成“正在输出杜比”；不把 SDR 增强或双声道空间化称为杜比。
- 不修改系统音量/亮度/显示设置，不下载整片，不保存视频帧。
- 识别仍是实验功能：真实插播可能漏检或保留边缘；无增强时回退独立解码。
