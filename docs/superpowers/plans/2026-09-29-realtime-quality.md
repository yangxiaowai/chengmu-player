# Realtime Quality Implementation Plan

**Goal:** 用实测确定计算瓶颈，并提供不放大噪点的可选4K流式输出，同时诊断加载故障。
**Architecture:** 等价模型变换仅用于实验；生产新增DetailScaler，由EnhancementPipeline在时域/可用AI后调用，单Metal command得到最终纹理，再做既有广告柔化。目录解析兼容单独修复。
**Spec:** `docs/design/realtime-quality-v0.3.3.md`

- [x] 读取当前实现并对比版本；实际查询5源与首页种子，真实UI目录/详情可加载；分离未复现问题与如意合法空结果兼容。
- [x] EfRLFN设备选择与等价图实验：验证数值一致、真实完成时间及计划成本；不强制改为更慢的GPU。
- [x] DetailScaler独立shader：正向尺寸、零额外锐化、局部包络限幅与梯度一致性门控、融合最终颜色编码。先独立质量与时间验收。
- [x] 生产集成：流式修复不足4K时适配至目标尺寸；明确区分AI倍率和算法缩放；旧模式/原片/HDR保持原有路线。
- [x] 回归：核心、字幕/色彩像素、管线尺寸和复位、1080p真实AVPlayer播放、HDR/广告保护；独立复核、release签名与包验证、UI新档位状态核验。
- [x] 保存实测与局限。未达实时的重模型保留实验，不包装成可用播放功能。
