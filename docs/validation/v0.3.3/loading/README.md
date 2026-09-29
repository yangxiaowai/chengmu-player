# 2026-09-29 加载问题诊断

诊断起点为 `ff37724`（v0.3.2）。本目录保存媒体服务子任务的证据，不代表完整界面验收。本轮没有修改用户档案、VPN、系统代理或网络配置；归档没有重新联网或运行 GPU 测试。

## 结论与范围

- 当前全局“影视内容全部加载失败”未复现，不能把某一源的局部错误称为全局根因。v0.3.1 → v0.3.2 的 `SourceService`、`MediaModels`、`SourceAccessProbe`、`AppModel` 联网逻辑没有变更。
- 使用实际 `SourceService`，系统代理模式和禁用 HTTP 代理模式各自对 5 个内置源检索《怪奇物语第一季》，均有结果。两种模式分别检查非凡、电影天堂、魔都的详情和 HLS，均成功。只读取目录/清单，不是完整影片播放验证；禁用 HTTP 代理也不等于排除了系统 VPN。见 `source-service.jsonl`。
- 以首页实际 5 个关键词顺序检索，共返回 128 个来源版本：8 / 30 / 39 / 31 / 20。其中 24/25 次来源查询成功，另一次是如意空结果格式兼容问题。来源版本数不是去重作品数。见 `homepage-catalog.jsonl`。
- 使用真实 `PlaybackController`、`MediaExperienceInspector` 和 AVPlayer，原片模式、静音、独立 `--validate` 进程验证非凡与魔都首集起播，每例最多观察 30 秒。非凡约 5.18 秒就绪、播放推进 20.04 秒、取得 194 次解码帧（1920×960）；魔都约 2.62 秒就绪、推进 19.96 秒、195 次解码帧（1024×576）。没有控制器或 item 错误。没有运行视频增强、保存媒体或帧文件，也没有验证可见画面、声音、音画同步、整集可靠性或原生 UI。

## 保留的测试汇总错误

`network-playback-original.json` 和 `.log` 保留原始总结果 `passed=false` / 退出码 1：临时脚本从旧三例测试裁为两例时，末尾仍硬编码 `report.cases.count == 3`，导致汇总错误。两条 case 各自的真实 `passed` 均为 `true`，测量值未更改。

`network-playback-summary.json` 是依据原始记录形成的解释性汇总，不是重跑结果。归档的 `network-playback.swift` 已改用 `report.cases.count == cases.count`，同时删除播放 URL 日志字段；它用于之后复现，不宣称该修正版已重新执行。原始 JSON 仅移除了两项播放 URL，保留测量值与错误总状态。

## 如意空结果修复

如意对首页关键词“火线第”实际返回 HTTP 200、`code=1,total=0,pagecount=0,list=null`。原解析器强制 `list` 为数组，将合法无结果误报为“来源返回了无效的目录数据”。原始公开 API 响应结构见 `ruyi-empty-observed-response.json`。

修复只接受**显式成功且总数和页数均为零**的 `null` 列表；缺字段、错误状态、非零结果等仍拒绝。它不解决或解释全部影视内容加载失败。

- `ruyi-empty-red.json`：旧 Core 接受 0/2 个合法空结果；6/6 个坏响应仍拒绝。
- `ruyi-empty-green.json`：修复 Core 接受 2/2；6/6 个坏响应仍拒绝。
- `ruyi-empty-live-fixed.json`：修复后的实际 API 调用返回 0 条、无后续页、无错误。
- `core-tests.log`：独立 Core-only 快照包的 156 项测试、19 个测试套件全部通过，包括新加的 2 项回归测试。不是全 App 构建或界面测试。日志中本机工作区/用户名路径已脱敏；现有 CLT Framework 搜索路径警告保留。

## 复现入口

`source-service.swift`、`homepage-catalog.swift`、`ruyi-empty-regression.swift`、`ruyi-empty-live-fixed.swift` 可分别链接对应版本的 `CinemaCore`。例如从仓库根目录：

```sh
swiftc -parse-as-library -target arm64-apple-macos15.0 \
  -I .build/out/Products/Release -L .build/out/Products/Release -lCinemaCore \
  docs/validation/v0.3.3/loading/source-service.swift -o .build/loading-source-check
.build/loading-source-check
```

执行实际媒体探针需先完成联网技能前置检查。下列编译只链接现有 Core，不触发 App/SwiftPM 全量构建；`--validate` 防止写入日常播放偏好：

```sh
swiftc -parse-as-library -target arm64-apple-macos15.0 \
  -I .build/out/Products/Release -L .build/out/Products/Release -lCinemaCore \
  Sources/CinemaApp/PlaybackController.swift Sources/CinemaApp/EnhancementPipeline.swift \
  Sources/CinemaApp/TemporalRestorer.swift Sources/CinemaApp/MediaExperienceInspector.swift \
  Sources/CinemaApp/VideoProcessingPolicy.swift Sources/CinemaApp/AdSkipController.swift \
  Sources/CinemaApp/AdFrameAnalyzer.swift docs/validation/v0.3.3/loading/network-playback.swift \
  -o .build/loading-player-check
.build/loading-player-check --validate --report "$PWD/.build/loading-player-check.json"
```

播放器复现程序选择原片模式；编译增强类型依赖不代表运行 GPU 增强。重跑时应在外部设置 90 秒进程上限，并将结果另存，不覆盖本目录历史证据。

本目录不含播放 URL、账户、密码、Cookie、个人档案或公网出口 IP；API 端点仅以主机名出现在测量证据中，复现代码中的示例地址为 `catalog.example`。
