# Source-aware Dolby Playback Implementation Plan

**Goal:** 根据原始媒体识别并保留兼容的Dolby Vision/HDR视频和Atmos音频，原生播放与SDR增强自动适配。
**Architecture:** Core清单/码流证据解析；App媒体检查与实际变体事件；VideoSurface逐帧SDR门禁及原生层；播放页分层状态。
**Tech Stack:** Swift5/macOS15+、AVFoundation、CoreMedia、CoreVideo、CoreAudio、SwiftUI；无第三方依赖。
**Spec:** ../specs/2026-09-28-source-aware-dolby-design.md

## Global Constraints

- 不把能力/可用清单误称正在输出；不把普通片源转换宣称为杜比。
- 不干扰用户现有播放器进程；测试独立profile和bundle。
- HDR/DV不通过sRGB8处理，不覆写源色彩，不修改媒体时间轴或系统音量/亮度。

## Review Focus

- 混合master和实际选中流不同；Atmos组必须确切关联。
- HLS动态切换和晚到GPU结果不能覆盖原生HDR帧。
- 未标范围和缺失格式信息不能默认“已验证SDR”。
- 切片、选音轨、暂停与旧异步任务竞态。
- 关闭空间化只是输出偏好，不应变更语言、片源或播放意图。

## Tasks

- [ ] Core：先写HLS声明、旧JSON和EC3 JOC结构测试并记录red；实现HLSProbe扩展与DolbyMetadata，再验证全Core。
- [ ] Renderer：先建立10bit标签及原生路由回归；新增VideoProcessingPermission/Policy及VideoSurface源检查门禁；真实SDR/HDR帧验证green。
- [ ] App：MediaExperienceInspector读取轨道/格式/实际variant事件，绑定item身份；PlaybackController明确系统HDR及音频策略；状态入口与音轨说明，验证设置隔离、选轨/换片、原始字幕和播放意图。
- [ ] 验收：官方Apple真实DV/Atmos播放、合成HDR渲染、完整Core和相关播放/广告/控制栏回归；独立复审；隔离原生UI验收。
- [ ] 发布：v0.2.9/build11，README和精确验收范围，签名与ZIP校验；保留用户当前播放进程。
