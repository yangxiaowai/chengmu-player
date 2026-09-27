# v0.2 媒体目录扩充与分页核查

核查日期：2026-09-27。最终媒体采样窗口为 UTC 04:48:02–04:48:46；目录与媒体都可能随时变化。

## 结果与证据边界

新增默认来源 **如意、魔都、无尽**，与原电影天堂、非凡组成 5 个目录入口。三个新来源均取得真实 JSON 目录、分类、分页、单片详情、HLS 和 FFmpeg 实际短解码证据。电影、国产剧、美剧均有成功样本，动漫也已补充。最终一轮 12 个样本中，10 个满足“视频帧数大于零、输出时长至少 1.9 秒、解码进程正常结束”门槛；这 10 个实际输出均为 2 秒、stderr 为空。

这不证明全部目录条目可播放、影片身份或分集完整性，不证明来源授权，也不证明整集播放、拖动、声画同步或 App 原生播放。源之间的目录和媒体可能重叠，不能将各源 `total` 相加当作独立影片数量。分辨率取 FFprobe 传输样本的编码尺寸，并有单独解码；未将 HLS 的 `RESOLUTION` 模板声明当作实际尺寸，未取得原生 4K 证据。

机器记录：[最终采样](source-expansion.json)、[初轮记录](source-expansion-initial.json)、[候选批次一](source-expansion-candidates.json)、[候选批次二](source-expansion-candidates-2.json)。初轮与复测各自保留，不把一次成功覆盖后续失败。

## 默认来源与覆盖

| 来源 | HTTPS 目录入口 | 本次目录自报条目数 | 返回分类数 | 搜索“爱情”第 1、2 页 |
|---|---|---:|---:|---|
| 如意 | [CMS API](https://cj.rycjapi.com/api.php/provide/vod?ac=list&pg=1) | 86482 | 39 | 各 20 条，所测两页 ID 无交集 |
| 魔都 | [CMS API](https://www.mdzyapi.com/api.php/provide/vod?ac=list&pg=1) | 89328 | 42 | 各 20 条，所测两页 ID 无交集 |
| 无尽 | [CMS API](https://api.wujinapi.com/api.php/provide/vod?ac=list&pg=1) | 121078 | 63 | 各 20 条，所测两页 ID 无交集 |

这些站点的分类编号不能共用。下表是从各自 `class` 读取的本次值；产品使用实际返回的分类，不靠固定映射。

| 来源 | 科幻电影 | 国产剧 | 美剧 | 日本动漫 |
|---|---|---|---|---|
| 如意 | 科幻片 `9` | 国产剧 `13` | 欧美剧 `16` | 日韩动漫 `30` |
| 魔都 | 科幻片 `13` | 国产剧 `26` | 欧美剧 `29` | 日韩动漫 `2` |
| 无尽 | 科幻片 `9` | 国产剧 `13` | 美国剧 `16` | 日韩动漫 `30` |

最终采样中，四类 `ac=detail&t=<本源分类>&pg=1` 均返回 20 条和分页元数据。默认选择 `ac=detail` 搜索/浏览以获得海报、年份、简介；独立 `ac=detail&ids=` 确认播放详情。`ac=list` 的分类元数据与 `ac=detail` 目录可组合使用。

## 实际媒体样本

| 来源 | 实际目录条目与 ID | 结果 | FFprobe 编码尺寸 | FFmpeg 视频帧 |
|---|---|---|---|---:|
| 如意 | 琅琊榜 `11751` | 2 秒通过 | 1080×606 | 48 |
| 如意 | 怪奇物语第一季 `26019` | 2 秒通过 | 1080×606 | 46 |
| 如意 | 火影忍者 `39129` | 2 秒通过 | 1080×606 | 58 |
| 魔都 | 琅琊榜 `15824` | 2 秒通过 | 1920×1080 | 49 |
| 魔都 | 怪奇物语第一季 `10734` | 2 秒通过 | 1024×576 | 47 |
| 魔都 | 火影忍者 -博人传- 次世代继承者 `5353` | 2 秒通过 | 1920×1080 | 47 |
| 无尽 | 流浪地球 `25734` | 2 秒通过 | 1280×504 | 49 |
| 无尽 | 琅琊榜 `15884` | 2 秒通过 | 1280×720 | 49 |
| 无尽 | 怪奇物语第一季 `21427` | 2 秒通过 | 1440×720 | 49 |
| 无尽 | 火影忍者 `19664` | 2 秒通过 | 1280×720 | 49 |

以上成功样本均检测到 H.264 视频、AAC 音频。媒体未保存到文件；短解码仅输出到 null，未作画面身份检查。魔都动漫是搜索返回的《博人传》，已按实际名称记载，不能作为原版《火影忍者》可播证明。

保留的异常：

- 如意《流浪地球》`15971`：FFprobe 1920×756，解码 exit 0、48 帧，但时长没有取得有效数值，脚本保守记为 0 秒，未计入 2 秒通过。初轮报告保留 `out_time_us=N/A` 导致旧探针数值转换失败的记录；探针已修复为保留失败状态而不中断整批。
- 魔都《流浪地球》`20148`：初轮 1920×756、46 帧、2 秒通过；最终复测网络超时（curl 28），故没有列入最终成功表。
- 初轮魔都《琅琊榜》超时，最终复测通过；这说明单次目录/媒体成功不等于稳定性承诺。

## 未加入默认的候选

光速、红牛、豪华所测四类样本都带加密标签；猫眼的电影与动漫样本也带加密标签。探针选择不取密钥，因此本次没有它们的解码结论。**标准 HLS AES-128 不等同 DRM**；这里仅说明探针主动缩小验证范围，并非断言这些来源不能正常播放。暴风的选中媒体请求 HTTP 404；猫眼部分查询未找到目标类别条目。没有绕过 403、账号、验证码、DRM 或使用替代授权。

入口发现沿用 [既有来源调研](../higher-quality-source-research.md)，并参考 [LibreTV 公开接口讨论](https://github.com/LibreSpark/LibreTV/discussions/652)。公开列表只用于发现地址，以上结论以实际 CMS/HLS 请求和解码为准。

## 已实现的服务接口

`MediaTitle.category: String?` 保存 `type_name`，构造参数默认 nil；旧历史记录缺少该字段仍可解码。`SourceCategory` 保存 `providerID/id/name/parentID`；缺失父类或 `type_pid=0` 归为 nil。

`CatalogPage` 包含 `providerID/titles/categories/page/pageCount/total`，并提供 `hasMore`。解析兼容数字和数字字符串。请求页码必须大于零；若服务器忽略 `pg` 并返回其他页码，返回明确错误，防止重复第一页被当作新一页。空结果 `pagecount=0` 归一为一个空末页；缺少分页元数据时不猜测后续页。

```swift
search(query: String, providers: [SourceProvider] = defaults, page: Int = 1) async -> SearchResponse
searchPages(query: String, providers: [SourceProvider] = defaults,
            pages: [String: Int] = [:]) async -> [ProviderPageResult]
browse(provider: SourceProvider, categoryID: String? = nil,
       page: Int = 1) async throws -> CatalogPage
parsePage(data: Data, provider: SourceProvider,
          requestedPage: Int = 1) throws -> CatalogPage
```

`ProviderPageResult` 分别返回来源 ID、成功页或错误；结果顺序与启用的来源顺序一致。每个来源保存自己的成功页码，失败来源重试原页，不会因其他来源翻页而跳过内容。去除重复来源 ID、忽略禁用来源，保持最多 3 个同时请求。

`browse` 第一页若缺分类，串行补取 `ac=list` 的分类元数据。后续分类页可能不携带 `class`，调用者应保留已经取得的分类数组。可以用 `browse` 做目录健康检查，无需另一套端点；UI 应称“目录可达”，不能称“全部影片可播”。

## 复现与验证

读取并完成 web-access 技能前置检查后运行：

```bash
python3 scripts/probe-source-expansion.py
```

探针依赖已安装的 curl 8.4+、FFmpeg、FFprobe，不安装软件。每请求超时 12 秒、响应上限 2 MiB，最多 3 个联网 worker，每样本最多读取四个分片、总计上限 8 MiB；Range 请求被忽略时仍受 curl 大小上限约束。只保存 JSON 证据；媒体字节留在内存，FFmpeg/FFprobe 仅允许 pipe 协议，解码时不会再发联网请求。清单递归最多四层，跳过密钥、初始化分片和字节范围清单。散列只标识实际读到的清单/分片字节，不是整片散列。

应用实际服务接口集成复现：

```bash
swiftc Sources/CinemaCore/*.swift scripts/probe-catalog-service.swift -o /tmp/cinema-catalog-integration
/tmp/cinema-catalog-integration
```

[服务集成结果](catalog-service-integration.json)：三个新来源各读到 20 个首页条目、39/42/63 个分类；各自国产剧分类第 2 页均为 20 条；“爱情”搜索第 2 页三个来源均为 20 条、无错误。此检查只验证目录服务链路。

`bash scripts/swift.sh test` 已完成，47 个测试、8 个套件通过。新增 `CatalogPageTests` 的 6 个测试覆盖分类持久化、旧历史兼容、混合类型分页、来源分类身份、空末页、服务器忽略页码、非法元数据、禁用/重复来源以及逐来源错误。日志见 [source-service-tests.log](source-service-tests.log)。初始整包运行曾被并行开发尚未完成的 UI/播放类型阻断；上述 47 项通过是这些接口落盘后的完成运行。

补充回归：分类补取为可选元数据，HTTP错误或坏JSON不再丢弃已取得的影片列表；取消仍继续传播。URLProtocol回归现为10项，根代理最终完整测试55项/8套件通过，见 [final-tests.log](final-tests.log)。[默认浏览检查](default-browse-check.json)确认电影天堂和非凡首页也各取得20条，分类分别32/31个。
