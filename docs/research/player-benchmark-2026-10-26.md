# 成熟播放器对标：个人 Mac 观影体验

核对日期：2026-10-26（Asia/Shanghai）。范围：IINA、mpv、Swiftfin，以及 Stremio 的公开需求库。仅核对维护方 README/文档和公开 issue 原文；未安装或实播这些产品。GitHub connector 读取失败后，以 `gh api` 和公开 raw 文件读取完成核对。未复制任何上游产品代码。

## 结论

澄幕已具备搜索、同片多来源聚合、来源/年份筛选、排序、待看、带集数与时间的历史、续播、手动字幕导入、音轨选择、倍速和画质检测。应优先改善“再次打开就按习惯看”和“继续观看只显示当前想接着看的内容”，再扩充发现功能。不能把公开 issue 的存在解释成普遍需求，也不能把当前开发分支文档当成已经发布且实测可用的功能。

## 可核对证据（10 项）

| # | 项目与证据类型 | 原文可支持的具体事实 | 日期/状态边界 | 对澄幕的启示 |
|---|---|---|---|---|
| 1 | IINA：README 功能声明 | 声明支持智能本地字幕匹配、在线字幕搜索。 | README 最后修改提交 2026-10-15；当前分支声明，未实播。 | 字幕从反复导入转为可理解的自动选择；在线下载须另做服务接入。 |
| 2 | IINA：README 功能声明 | 声明有无限播放历史、视频缩略图、可定制键鼠/触控板/手势控制。 | 同上。 | 历史和日常控制是成熟度基线；澄幕已有固定快捷键与 200 条历史，不应把它们算作缺失。 |
| 3 | mpv：维护方选项文档 | `save-position-on-quit` 可保存位置；`resume-playback` 可恢复；`watch-later-options` 可保存字幕轨等变化；`resume-playback-check-mtime` 可避免同名但内容已变化的文件误续播。 | 文档最后修改提交 2026-10-24；保存与恢复条件有明确区别。 | 持久化位置之外，还需保存有意义的播放偏好并验证媒体身份。 |
| 4 | mpv：维护方选项文档 | `alang`/`slang` 为有优先顺序的语言列表；`sub-auto` 区分精确/模糊/全部匹配；`sub-visibility` 可隐藏字幕而保持选中与解码。 | 同上；不是 AVPlayer 的同名 API。 | 音轨/字幕语言偏好、关闭字幕与遗忘选择应分开。 |
| 5 | IINA：用户请求 #2856 | 请求快捷键切换字幕显示；多字幕时，循环字幕不能方便地实现开/关并回到原轨。 | 创建 2020-04-08；更新 2025-06-04；本次读取为 open。历史请求，不能据此断言当前发行版一定缺失。 | 一个保留所选轨的字幕开关，减少中断观影。 |
| 6 | Swiftfin：维护方播放文档 | 当前文档对比 MPV 与 AVPlayer：两者均列出音轨/字幕轨选择和倍速；第二字幕、音画/字幕偏移等存在引擎差异。 | 文档提交 2026-10-25；Swiftfin 是 iOS/tvOS Jellyfin 客户端，非 Mac 本地播放器直接替代品。 | 可以学习明确的能力边界；不因为一个界面选项就承诺底层实际支持。 |
| 7 | Swiftfin：维护方播放文档 | 文档说明直放还受容器、设备和 Playback Quality 设置影响；不支持的格式依赖服务器转码/重封装；HDR 转 SDR 的说明也有服务器与配置条件。 | 同上；只证明 Swiftfin 的公开设计，不能直接移植其兼容性表到澄幕/macOS。 | 保留真实源信息、实际播放/输出信息与增强目标的区分；提供具体失败原因与可行下一步。 |
| 8 | Stremio：用户请求 #1635 | 用户报告看完电影或最后一集后条目移出继续观看，并请求“始终保留”的设置。 | 创建 2026-01-23；更新 2026-10-23；open。行为是报告者陈述，非本次实播确认。 | 完成内容展示策略需要可调；隐藏已看应为视图筛选，不能等同删除历史。 |
| 9 | Stremio：用户请求 #1469 | 用户描述选择 New 后 Genre 被 Year 替换，不能组合“最新排序 + 类型筛选”。 | 创建 2025-11-04；更新 2026-01-08；open。 | 筛选维度与排序保持独立，可组合、可重置；澄幕已有年份/来源与排序组合，应保留这一优势。 |
| 10 | Stremio：用户请求 #1420 | macOS 用户请求类型多选与 Best Rated，并描述需要去别处找特定类别影片。 | 创建 2025-09-29；更新 2026-02-11；open。 | 可在可靠元数据存在时扩充类型多选；不能把未知评分伪装成零分，或把来源文字当实测画质。 |

证据链接：

- [1–2：IINA README，固定提交](https://github.com/iina/iina/blob/09e92e11dc47964ba005a7c89c9362c7ffdc5851/README.md#features)
- [3：mpv 播放状态选项，固定提交](https://github.com/mpv-player/mpv/blob/691a86bfb8d0976d2debf9fcc2b51bce2392fd8d/DOCS/man/options.rst#L1141)
- [4：mpv 语言优先级，固定提交](https://github.com/mpv-player/mpv/blob/691a86bfb8d0976d2debf9fcc2b51bce2392fd8d/DOCS/man/options.rst#L7)；[字幕自动匹配/显示](https://github.com/mpv-player/mpv/blob/691a86bfb8d0976d2debf9fcc2b51bce2392fd8d/DOCS/man/options.rst#L2913)
- [5：IINA #2856 Add Subtitle Toggle](https://github.com/iina/iina/issues/2856)
- [6–7：Swiftfin Player Differences，固定提交](https://github.com/jellyfin/Swiftfin/blob/a9998844070efce42098af5a5d2ab22ce28c0ef5/Documentation/players.md)
- [8：Stremio #1635 Option to always keep items in continue watching](https://github.com/Stremio/stremio-features/issues/1635)
- [9：Stremio #1469 Content sorting](https://github.com/Stremio/stremio-features/issues/1469)
- [10：Stremio #1420 Filters - Possibility to multi-select + add Best Rated filter](https://github.com/Stremio/stremio-features/issues/1420)

## 建议优先级（与现有代码初步核对）

1. **P1 字幕显示开关及字幕偏好。** 先做保留所选内嵌/外挂字幕的开关，菜单/快捷键与可见状态同步；再考虑字幕字号、背景、语言优先级。现有 `PlaybackPreferences` 未看到字幕相关持久化字段，`PlaybackController` 已有手动选轨和外挂字幕。不要把关闭字幕实现为销毁外挂字幕或永久忘记已选轨。依据 #4–5。
2. **P1 继续观看与完整历史分开呈现。** 保留完整记录，提供“未看完/全部”筛选、明确完成标识；继续观看可隐藏已完成条目，用户仍能查看与重新播放。当前历史卡已显示集数、进度和时间，因此重点是完成策略与可逆操作。完成阈值应是澄幕自身明确规则，不能声称从来源得到统一行业标准。依据 #2–3、#8。
3. **P2 按习惯恢复播放。** 保存播放习惯已有基础（音量、速度、画质等）；补充安全的音轨/字幕偏好时，匹配语言/稳定标识，不能跨片恢复轨道数组索引。恢复位置继续验证片源/集数身份。依据 #3–4。源码初读已看到澄幕严格匹配 URL 与集名，此项为增强既有机制。
4. **P2 保持可组合的筛选，按元数据逐步扩充。** 当前来源、年份、排序已经能同时使用；先提供清晰的已生效筛选/一键重置，类型多选或评分排序只在来源元数据可靠时加入。无评分、未知年份、尚未检测画质分别展示未知状态。依据 #9–10。
5. **P2 继续完善可理解的播放能力说明。** 在失败/不兼容状态中解释容器、编码或来源可达性，并提供可行重试/换源操作；当前已具备 SourceAccess/quality probe/inspector，优先收敛文案与证据，不引入第二引擎。不要把 4K 增强目标或系统输出模式说成源视频真实分辨率、HDR/Dolby Vision 实际生效证明。依据 #6–7。

## 检索和验证边界

- 公开 GitHub issue 是可追溯的定性需求材料，不是抽样调查。未统计人数、热度或需求占比；没有用少量 issue 声称“多数用户”。
- 所列 open 是 2026-10-26 读取快照，未来可能变化。较早 issue 只用来说明场景，不能证明今天的产品仍存在同一缺陷。
- README 与固定提交文档能证明维护方声明，不证明 App Store/稳定版交付状态、所有设备支持或体验质量。
- 对澄幕仅做源码初读，没有在本调研中构建或运行 UI；实现与验证由主任务继续完成。
