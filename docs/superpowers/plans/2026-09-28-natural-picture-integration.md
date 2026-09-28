# 自然画质与统一发布实施计划

**Goal:** 整合单一应用入口，减少增强噪声，提供可核对的原片对照与实际状态。

**Architecture:** 保留 AVFoundation/Metal 架构及旧数据格式。降噪改动位于 EnhancementPipeline，画质选择与对照状态集中在 PlaybackController，两个界面共用该接口。发布先构建完整暂存 bundle，核验后备份并替换主入口。

**Spec:** `docs/design/player-integration-v0.3.1.md`

- [x] 质量基线：新增独立真实 GPU 噪声/边缘夹具，先保存旧算法失败报告及对照图。
- [x] 画质处理：移除双重锐化，以降噪与无过冲缩放处理 SDR；用同一夹具确认噪声下降、字幕边缘与亮度保留，再测帧耗时和 HDR 路由。
- [x] 统一选择：`selectEnhancementMode(_:)` 供所有入口调用；新增非持久化 `isComparingOriginal` / `toggleOriginalComparison()`，换片清除；核心默认偏好和真实控制器烟测覆盖关闭后恢复、原片对照与持久设置隔离。
- [x] 交互：播放控制栏增加紧凑对照入口，画质菜单和工作室用 `selectedPictureMode` 与真实 metrics 展示选择和实际输出；保留窄窗口与原有常用动作。
- [x] 单入口发布：v0.3.1/build 13，统一 `dist/映川.app`；备份旧应用，运行中拒绝替换，保持数据目录及 bundle id。
- [x] 验收：核心测试、画质像素比较、原片开关与 HDR 路由回归、Release/签名/ZIP 解包检查，记录原生布局验收因锁屏受阻的限制后提交。

- [ ] 原生新增按钮、1040 点窄窗与全屏目视/物理指针复验：Mac 锁屏，UI 工具无法解锁；代码与独立 QA 应用已构建，未将此项宣称通过。
