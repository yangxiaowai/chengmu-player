# 日常观影体验 Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development or superpowers:executing-plans to implement this plan task-by-task.

**Goal:** 改进找片相关性、字幕舒适设置和未看完记录，发布v0.4.1/build24。
**Architecture:** CinemaCore承载纯筛选/排序与验证后的偏好数据；现有AppModel接线，SwiftUI只展示状态。AVPlayer和媒体身份规则保留，不新增网络账户服务。
**Tech Stack:** Swift5、SwiftUI、AVFoundation、macOS15+；Python仅conda searchformoney。
**Spec:** ../specs/2026-10-26-player-needs-design.md

## Global Constraints

- 深色蓝色消费界面，不加入抽样/验收等开发文案。
- 未分类保留；显式搜索解说/预告不能被默认排序规则淹没。
- 隐藏字幕保留文件/选轨；不跨片复用轨道数组索引、外挂文件或偏移。
- 历史筛选不能删除数据；未知/非有限时长不判完成。
- 同步GitHub；安装器不覆盖运行中的应用。

## Review Focus

- 中文/英文季数、全半角、同名衍生内容与未知类别，排序稳定可逆。
- 来源/年份/内容同时筛选时卡片只包含匹配来源，保留原身份ID。
- 暂停/重试/切集时字幕隐藏意图与当前外挂偏移不丢失或串片。
- 字幕大小/上移值非有限输入、长多行字幕与控制栏避让。
- 最新集已完成时不重新冒出旧集；所有记录仍可查看。

### Task 1: 搜索核心规则

**Files:** Create Sources/CinemaCore/CatalogDiscoveryPolicy.swift; Tests/CinemaCoreTests/CatalogDiscoveryPolicyTests.swift。
**Interfaces:** CatalogContentFilter(all,feature,commentary,trailer,shortDrama)，title/id；CatalogDiscoveryPolicy.matches(_:filter:)、rank(_:query:) -> [MediaGroup]。
- [x] 先写准确片名/季数、显式解说、未知类别与稳定分页排序用例并运行失败。
- [x] 实现保守分类、匹配和纯相关性排序，保留原对象与组ID。
- [x] 独立测试通过；主任务接入AppModel/CatalogViews，验证来源+年份+类别+排序组合及重置。

### Task 2: 字幕显示与舒适度

**Files:** Create SubtitlePreferences.swift/tests；修改PlaybackController、PlayerView、PlaybackCommands/Dialogs；独立控制器回归驱动。
**Interfaces:** PlaybackController.subtitlesVisible、subtitleFontSize、subtitleBackgroundEnabled、subtitleVerticalOffset，toggleSubtitleVisibility()。
- [x] 先写偏好迁移/钳制和外挂隐藏→显示、导入错误不丢原字幕、重试/换片用例并运行失败。
- [x] 单独存储字幕偏好；显示切换不清除现有cues/所选轨；新片不承接旧轨道索引/偏移。
- [x] 原生菜单、字幕排版与快捷键接线，实际控制器回归通过。

### Task 3: 记录视图与集成

**Files:** LibraryStore.swift/tests；AppModel.swift、CatalogViews.swift、Tests/AppModelSmoke。
- [x] 测试有效95%完成阈值及未知时长，最新完成集/旧未完集的顺序。
- [x] 添加未看完/全部筛选与完成标记，不修改或删除历史数据。
- [x] 核心/字幕/模型接线、原生渲染与播放隐藏/稳定性/保活回归；独立代码审阅。
- [x] 提交推送并验证GitHub发行远端；发行记录、签名/归档/哈希和正常退出后的安装已完成。
