# 播放内核技术调研

核验日期：2026-09-27。证据为公开官方文档、上游源码和发布页；未安装依赖，未运行播放器，未做 M4/16GB 的播放、HDR 或性能验证。本文件是候选比较，不是已批准的设计规格。

## 结论与路线比较

当前已确认 Mac 桌面优先、以后扩展其他设备，以及网络链接和本地导入、剧集库。用户后来明确三部指定剧必须在软件内直接播放，并新增“边看边增强”的要求。**SwiftUI界面 + AppKit视频视图 + 内嵌libmpv仍是候选，尚未锁定**。必须补充比较libmpv渲染/shader路线与可访问原生像素缓冲的VideoToolbox/Metal路线；字幕、格式兼容和音画同步的实现成本也要计入。详见[流式增强研究](streaming-enhancement-notes.md)。这是选型建议，不是已验证性能。

| 路线 | 适合条件 | 主要成本与限制 |
|---|---|---|
| SwiftUI/AppKit + libmpv | 先把 Mac 的 MKV、多音轨、字幕与网络直链做好 | 原生视频渲染、线程与动态库打包需要实现；Windows 界面以后另做。参考 IINA 的内嵌实践，不能直接假设有现成 Metal libmpv API |
| Electron 或 Tauri + libmpv | 近期必须共享 Mac/Windows UI，或已有成熟 Web 界面 | 框架只解决界面与系统接口，原生视频视图仍需桥接；并不会自动获得 mpv 的格式能力。Electron 基于 Chromium/Node，Tauri 在 Mac 用 WKWebView、Windows 用 WebView2，Web 视频能力随运行时不同 |
| Web + hls.js/Shaka（需要时配媒体服务器） | 资源主要是标准 HLS/DASH/MP4，优先多设备访问 | 解码由浏览器提供；MKV、ASS/PGS、DTS、HDR 不能按通用原生播放器能力承诺。服务端转封装/转码能补部分缺口，也增加运行与画质成本 |

上面框架事实依据：[Electron](https://github.com/electron/electron)、[Tauri Webview](https://v2.tauri.app/reference/webview-versions/)。跨平台将来可能更重要，但目前不应为了它额外增加原生视频层与 Web 层之间的桥接。

## 内嵌与外部播放必须区分

mpv 官方推荐在另一应用里用 libmpv 作播放后端；JSON IPC 可以控制独立 mpv 进程，但启动独立 mpv/IINA 窗口只满足“调用播放器”，不能当作上述内嵌设计已经完成。[mpv 手册](https://mpv.io/manual/stable/#embedding-into-other-programs-libmpv)

libmpv 的 render API 当前列明 OpenGL 和软件后端，并说明相比 window embedding 更推荐 render API。IINA 的 Swift 源码确实通过 `MPV_RENDER_API_TYPE_OPENGL` 建立内嵌 renderer。故 SwiftUI 本身不负责视频解码；可用 AppKit 视频视图承接渲染，但不能写成“直接把 libmpv 接 Metal 就完成”。[render.h](https://raw.githubusercontent.com/mpv-player/mpv/master/include/mpv/render.h)、[IINA MPVController.swift](https://raw.githubusercontent.com/iina/iina/develop/iina/MPVController.swift)

## 项目能力与适配

- **mpv/libmpv**：广泛格式、字幕类型与轨道切换；Mac 有 VideoToolbox、Windows 有 D3D11VA 等硬解路径。HLS/DASH 的实际输入能力还取决于 FFmpeg 编译配置和流特性，不能等同浏览器播放器的全部自适应行为。优先候选用于本地与未受 DRM 保护的网络媒体。[mpv](https://github.com/mpv-player/mpv)、[FFmpeg demuxers](https://ffmpeg.org/ffmpeg-formats.html#Demuxers)
- **IINA**：Mac 原生、基于 mpv，已有字幕、章节、播放列表、历史、画中画；适合参考原生集成和交互，不是 Windows 方案，也不是现成影视搜索/剧集聚合服务。[IINA](https://github.com/iina/iina)
- **Jellyfin**：媒体库/客户端/服务端体系，适合以后 NAS、自有媒体库与多设备同步；当前纯本机应用无需默认运行它。容器/编码不兼容时可能转封装或转码；字幕烧录尤其增加转码负担。[Jellyfin](https://github.com/jellyfin/jellyfin)、[兼容性](https://jellyfin.org/docs/general/clients/codec-support/)
- **hls.js**：HLS、字幕、可选音轨；需使用包含相应功能的构建，light 构建剔除字幕/替代音轨/EME 等。HEVC/AV1/Dolby Vision 支持依赖运行时；所有 HLS 资源都需允许 GET 的 CORS 响应头。它不承担影视发现或 DASH 播放。[hls.js](https://github.com/video-dev/hls.js)
- **Shaka Player**：HLS/DASH 与 EME；支持 MP4/WebM/TS、WebVTT/TTML/SRT 等但受浏览器能力限制。适合标准网络流或正式授权 DRM 接入。播放保护内容仍需许可证服务器、兼容 CDM 和相应认证；一条网页链接不足以获得这些能力。[Shaka](https://github.com/shaka-project/shaka-player)、[DRM 配置](https://shaka-project.github.io/shaka-player/docs/api/tutorial-drm-config.html)

## 必须保留的实际边界

1. **4K、HDR、画质增强是不同指标。** 能解码 3840×2160 不代表屏幕能按原生 4K 显示，也不代表正确 HDR。母片编码、位深、帧率、码率、硬解、色彩管理、显示器都影响结果。mpv CLI 的 gpu-next/HDR 路径不能未经验证就等同 libmpv OpenGL 内嵌路径；IINA 发布记录也持续修正 HDR 问题。[mpv 手册](https://mpv.io/manual/stable/)、[IINA 发布记录](https://github.com/iina/iina/releases)
2. **网络检索与播放内核是独立能力。** 上述项目都不能保证自动搜到任意影视的公开高质量来源。需要逐来源验证可用接口、资源元数据、有效直链；网页地址、媒体地址、临时签名地址不能混为一谈。原生请求不受浏览器 CORS 执行约束是架构推断，但服务器的鉴权、Cookie、Referer、Range 与链接过期仍需处理。
3. **流式增强决定帧接口与调度。** 用户要求边看边处理。mpv的缩放/着色器不自动等于AI超分，也不能假定libmpv渲染接口能直接提供VideoToolbox所需像素缓冲。需同时验证硬解、转换/拷贝、推理、呈现与同步，采用有界帧队列及过载策略；10秒样片之后仍需持续播放测试。“输出4K尺寸”不证明“恢复真实4K细节”。
4. **DRM 不按格式后缀判断。** HLS/DASH 可以是清晰流、普通加密流或商用 DRM；选 libmpv 不能推导为具备 Widevine/FairPlay 许可证会话。Web 方案也不能把官方 Chrome 的 CDM 能力直接归给任意 Electron/Chromium 构建。[Shaka DRM 矩阵](https://github.com/shaka-project/shaka-player#drm-support-matrix)

## 维护与许可证快照

以下精确 release tag 均于核验日直接打开确认，发布页当时标为 Latest；不是已选依赖版本，实现时需锁定具体构建与依赖。Jellyfin 的 v12.1 页面正文明确称其为稳定版，版本数字不是从标题裁剪猜测。mpv 另有自动开发构建，需和稳定版本区分。

| 项目 | 稳定发布快照 | 许可证 |
|---|---|---|
| mpv | [v0.41.0](https://github.com/mpv-player/mpv/releases/tag/v0.41.0)；另有开发构建 | 默认 GPLv2+；满足源码与依赖条件的特定构建可 LGPLv2.1+，不能只看 libmpv 名称。具体二进制还受 FFmpeg 等依赖影响 |
| IINA | [v1.4.4](https://github.com/iina/iina/releases/tag/v1.4.4)；另有后续预发布 | [GPLv3](https://raw.githubusercontent.com/iina/iina/develop/LICENSE) |
| Jellyfin | [v12.1](https://github.com/jellyfin/jellyfin/releases/tag/v12.1) | 服务端 GPLv2；客户端各仓库分别核验 |
| hls.js | [v1.7.3](https://github.com/video-dev/hls.js/releases/tag/v1.7.3) | Apache-2.0 |
| Shaka | [v5.2.12](https://github.com/shaka-project/shaka-player/releases/tag/v5.2.12) | Apache-2.0 |
| Electron/Tauri | 本次未选版本 | Electron MIT；Tauri MIT/Apache-2.0 |

mpv 的许可证判断依据：[上游 Copyright](https://raw.githubusercontent.com/mpv-player/mpv/master/Copyright)。这些项目均有公开发布/维护信息，本次没有进行漏洞审计或证明未来维护持续性。

## 进入实现前的能力核验建议

用代表性可访问资源核验内嵌首帧、音画同步、拖动、换轨、字幕、暂停恢复、全屏和错误恢复；分别记录 4K HEVC/AV1、HDR/SDR、MKV/MP4、HLS/DASH、网络中断结果。记录真实硬解状态、掉帧和资源占用；不要用“能打开窗口”替代内嵌播放与4K验收。未来 Windows 用同一媒体样本复验，不能继承 Mac 的结果。
