# Streaming Restoration Implementation Plan

> **For agentic workers:** Use superpowers:executing-plans for root integration; independent native/model/film experiments have explicit file ownership.

**Goal:** 用经本机实测的因果时域处理改善流式影片观感，保留原片对照与失败回退。

**Architecture:** TemporalRestorer 单独管理 VT 会话与历史；EnhancementPipeline 在 SDR worker 中调用并可接 AppleScaler；VideoSurface 将 revision 交给管线。偏好与两个画质入口复用现有模式机制。实验模型不作为发行运行依赖。

**Tech Stack:** Swift / AVFoundation / Core Image / VideoToolbox / Metal；研究使用隔离 Python Core ML 工具。

**Spec:** `docs/design/streaming-restoration-v0.3.2.md`

## Global Constraints

macOS 15 应用下限；新时域功能 macOS 26+。无未来帧、单帧在途、HDR 原生、旧偏好保留、完成后计时。原片默认不变。

## Review Focus

换片和 seek 不能混用历史；同亮度彩色切镜不能留下上一场景；暂停首帧不能声称使用了历史；AI 无倍率不阻止时域降噪；局部柔化必须最后执行且不污染框外/字幕。

## Tasks

- [x] 研究与探针：官方论文/仓库/许可证；实际 Core ML 权重转换与完成耗时，VT 格式/过去帧/复位初测。
- [x] `TemporalRestorer.swift`：独立会话、颜色转换、history/reset/cut 检测；`validate-temporal-restoration.sh` 验证受控噪声、运动、字幕、seek、色彩及完成耗时。
- [x] 偏好/管线：先写新模式偏好往返失败用例；增加 temporal/restoration，传 streamID、首帧状态、实际倍率/无倍率状态；SettingsViews 更新说明图标。独立管线测试覆盖 reset/可用倍率/HDR。
- [x] 真人对照：`validate-restoration-film.sh` 比原图/旧自然降噪/新时域输出；等尺度、逐帧对齐，真实视频结论与合成结果分列。
- [x] 兼容与发布：更新独立验证脚本源码列表，运行核心测试、HDR路由、原片切换、局部柔化；fresh review；v0.3.2 build14 构建/归档旧版/签名/资源检查，记录可复现证据和已知限制。

## Decisions / evidence ledger

- 用户已授权持续优化与综合改善，直接实施；不会要求重复确认设计。
- EfRLFN 固定720p约105 ms、不作为实时功能发布；保留实验供后续针对计算结构优化。
- 现有 development 分支继续工作；不移动 checkout、不改已有片库数据。

- 验收完成：核心154、原生86、管线33、headless播放10、控制器18、HDR24均通过；详细范围见 `docs/验收记录-v0.3.2.md`。
- 物理UI复验因Mac锁屏未完成，不作为发布通过项。真人结果小幅混合收益，不改变原片默认；未接超出预算的EfRLFN。
