# 本地插播广告识别与自动跳过 Implementation Plan

**Goal:** 在现有播放器中，本地识别澳门新葡京推广画面，自动跳过确认主段并支持撤销。

**Architecture:** 纯策略、独立OCR取帧、播放前视扫描、真实播放器seek分层。扫描失败保持原片，代次隔离，原媒体时间轴不变。

**Tech Stack:** Swift 5、macOS15+、AVFoundation、Vision、SwiftUI，无新增依赖。

**Spec:** ../specs/2026-09-27-local-ad-skip-design.md

## Global Constraints

- 扫描和识别在本机，不上传视频，不申请API密钥。
- 不修改媒体/字幕文件，不改写HLS清单，不把discontinuity当广告。
- 默认开启但标为实验；可关闭、可撤销，正常播放优先。
- 当前用户正在观看，测试使用隔离夹具，发布后不自动重启其播放进程。

## Review Focus

- 字幕中的品牌、角标、小字不能误跳：纯策略负例和真实OCR负样本。
- OCR冷启动/错误/时间不匹配不能制造结束边界：unknown和取消测试。
- 手动seek/暂停/换片期间自动跳转不能争抢：真实播放器回归。
- HLS取帧可能失败：普通HLS实测并保留失败状态。
- 全屏隐藏、字幕和广告柔化继续正常：既有回归及集成构建。

## Tasks

- [x] 1. 先写AdSkipPolicyTests：品牌+促销的主画面连续帧、字幕/角标/品牌单独/unknown/gap/90秒上限/无闭合、暂停和忽略区间。记录red后实现AdSkipPolicy.swift，再验证green。
- [x] 2. 编写真实OCR帧及独立MP4/HLS取帧夹具，然后实现AdFrameAnalyzer.swift和AdSkipController.swift；单任务、限额、超时及晚到结果隔离，不影响主播放器。
- [x] 3. PlaybackController接入扫描、自动seek、撤销及手动回看保护；PlaybackPreferences保存开关并兼容旧设置。PlayerView增加菜单和已跳过提示，拖动时暂停自动跳转。
- [x] 4. 运行完整核心测试和真实AVPlayer跳过/撤销/换片/字幕回归、既有响应与控制栏隐藏回归；独立审查修复实质问题。
- [x] 5. 构建v0.2.8，隔离原生UI检查，验证签名与ZIP完整性，更新README/验收记录，保留用户当前播放进程。
