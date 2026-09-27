# 更高画质与备份源核查

核查日期：2026-09-27；结果时点：2026-09-27T04:01:24.693303+00:00。只读研究，未修改产品代码、未安装依赖。

## 结论

本次找到可用的 HTTPS 非凡 CMS 备份入口，三剧首季首集以及《怪奇物语》第五季首集的 HLS 和首分片均可读取、FFprobe 成功。所测样本最高为 1920×1080/1920×1082，没有取得实际 3840×2160 的样本，因此没有新增原生 4K 证据。该结论只覆盖下面列出的公开配置和访问时点，不能推断全网不存在 4K。

备份在接口域名、媒体主机及剧集清单上与 dytt 有差异，可以提供另一条播放候选；没有证明供应商或存储基础设施彼此独立，也未视觉核实正片身份、授权、完整性或实际 App 播放。FFprobe 宽高仅证明该传输样本的编码尺寸，不证明原始拍摄/母版分辨率或画质优于主源。

## 来源与方式

- [LibreTV 公开配置](https://github.com/dreamjackson/LibreTV/blob/main/js/config.js)：原列 `http://ffzy5.tv/api.php/provide/vod`。
- [MoonTV 公开配置](https://github.com/zlinoliver/moontv/blob/main/config.json)：提供如意、非凡、极速、魔都等接口。
- [LunaTV 当前精简配置](https://github.com/hafrey1/LunaTV-config/blob/main/jin18.json)：提供新的猫眼、量子、光速、红牛、豪华接口；是发现入口，不把仓库自述健康状态当作实际播放证明。
- [XPTV 公开配置](https://github.com/fangkuia/XPTV/blob/main/all.json)和[4k-av 原始适配代码](https://github.com/Yswag/xptv-extensions/blob/main/js/4kav.js)：只取明文站点和搜索路由，未执行适配器；其 `https://4kmp.com/s?q=…` 三剧访问均 HTTP 403，未尝试登录或绕过。

先阅读现有 `source-report.json` 的九个失败接口，本次没有重新查询相同失败 endpoint；`cj.lzcaiji.com` 是当前配置明确列出的另一个主机，区别于之前失败的 `cj.lziapi.com`。不把更换主机当作同一接口已修复。公开 HTTPS/HTTP，无账号、cookies、DRM 操作；最大并行3、请求超时10–12秒；清单/JSON每响应最多2 MiB；单个首分片请求Range 0–2097151并实际只读最多2 MiB（低于8 MiB上限），内存喂给现有FFprobe，媒体不落盘、不读取完整剧集。加密清单/需要初始化分片的格式跳过，未取密钥。

## 可直接复核的非凡 HTTPS 入口

实际验证 endpoint：`https://ffzy5.tv/api.php/provide/vod`。`ac=list&wd=` 三剧查询 HTTP200，正文可解析 JSON，但 MIME 为 `text/html;charset=utf-8`；`ac=detail&ids=` 三剧首季返回标准 `vod_id/vod_name/vod_year/vod_pic/vod_play_from/vod_play_url` 字段。不是只测试 LibreTV 使用的 `ac=videolist`。HTTPS详情的首集URL与先前HTTP发现所测HLS一致。

`vod_play_from = feifan$$$ffm3u8`：`feifan` 是 `/share/` 网页；直读 HLS 是 `ffm3u8` 对应第二块。不得用第一块HTML当媒体。机器证据见 [backup-source-probe.json](backup-source-probe.json)。

| 剧集 | 季序1–5的ID | 季目录条数 | 总计 |
|---|---|---|---|
| 怪奇物语 | 24151, 24152, 24153, 24154, 89681 | 8, 9, 8, 9, 8 | 42 |
| 绝命毒师 | 35495, 35496, 35497, 35498, 35499 | 7, 13, 13, 13, 16 | 62 |
| 火线 | 39350, 39351, 39352, 48031, 48109 | 13, 12, 12, 13, 10 | 60 |

共164条目录（42+62+60），各季条数与主源目录记录匹配。目录数量匹配不证明所有分集正确或完整。这里只采样4个首集，没有对164条逐集探测。

## 首分片实测

表中全部成功样本：H.264视频、AAC音频、`yuv420p`，FFprobe exit0。只读元数据，没有新增解码/视觉检查。没有观察到可确认HDR的transfer/primaries元数据。清单多个有统一800000带宽和1080×608声明，与实际尺寸不符，不能把声明当分辨率。

| 接口 | 剧集样本 | 实际编码尺寸 | 首分片读取字节 | 分片最终主机 |
|---|---|---|---|---|
| ruyi | 怪奇物语第一季 第1集 | 1080×606 | 267524 | cdn7.ryplay7.com |
| ruyi | 绝命毒师第一季 第1集 | 1920×1082 | 808400 | cdn7.ryplay7.com |
| ffzy | 怪奇物语第五季 第1集 | 1920×1080 | 1632216 | svip.feifei-play.com |
| ffzy | 怪奇物语第一季 第1集 | 1920×960 | 503464 | vip.ffzy-play10.com |
| ffzy | 绝命毒师第一季 第1集 | 1916×1080 | 823816 | vip.ffzy-online3.com |
| ffzy | 火线第一季 第1集 | 1280×720 | 859160 | vip.ffzy-online3.com |
| mdzy | 怪奇物语第一季 第1集 | 1024×576 | 119004 | play.modujx12.com |
| mdzy | 绝命毒师第一季 第1集 | 1920×1080 | 27448 | play.modujx12.com |
| mdzy | 火线第一季 第1集 | 1280×718 | 590696 | play.modujx12.com |

主源先前首季首集编码尺寸为怪奇1920×1080、毒师1916×1080、火线1920×1080。非凡备份的怪奇首季1920×960和火线1280×720没有尺寸优势；同尺寸毒师不代表相同字节或同品质。各成功样本首分片SHA-256互不相同；主源以 `vip.dytt-music.com` 为清单入口，非凡媒体取自上表不同域名，但这只支持入口不同，不能证明运维/版权/母版独立。

## 其他搜索与受限结果

初轮11个新增配置接口×3查询共33次；后续5个当前配置接口×3查询15次。宽泛“火线”会被其他影片挤占首页，所以对如意/非凡/极速/魔都又各查“火线第一季”，避免将首页没出现误判为全站没有。未翻遍每个站点全部结果。

| 接口ID/地址 | 三查询结果（怪奇/毒师/火线或火线第一季） |
|---|---|
| `https://cj.rycjapi.com/api.php/provide/vod` | JSON 10项 / JSON 7项 / JSON 20项 |
| `https://tyyszy.com/api.php/provide/vod` | JSONDecodeError Expecting value: line 1 column 1 (char 0) / JSONDecodeError Expecting value: line 1 column 1 (char 0) / JSONDecodeError Expecting value: line 1 column 1 (char 0) |
| `http://ffzy5.tv/api.php/provide/vod` | JSON 7项 / JSON 5项 / JSON 20项 |
| `https://www.iqiyizyapi.com/api.php/provide/vod` | JSON 9项 / HTTPError HTTP Error 503: Service Temporarily Unavailable / HTTPError HTTP Error 503: Service Temporarily Unavailable |
| `https://jszyapi.com/api.php/provide/vod` | JSON 9项 / JSON 10项 / JSON 20项 |
| `https://dbzy.tv/api.php/provide/vod` | JSON 0项 / JSON 0项 / JSON 0项 |
| `https://mozhuazy.com/api.php/provide/vod` | URLError <urlopen error [SSL: UNEXPECTED_EOF_WHILE_READING] EOF occurred in vio / URLError <urlopen error [SSL: UNEXPECTED_EOF_WHILE_READING] EOF occurred in vio / URLError <urlopen error [SSL: UNEXPECTED_EOF_WHILE_READING] EOF occurred in vio |
| `https://www.mdzyapi.com/api.php/provide/vod` | JSON 7项 / JSON 6项 / JSON 20项 |
| `https://m3u8.apiyhzy.com/api.php/provide/vod` | HTTPError HTTP Error 403: Forbidden / HTTPError HTTP Error 403: Forbidden / HTTPError HTTP Error 403: Forbidden |
| `https://wwzy.tv/api.php/provide/vod` | JSONDecodeError Expecting value: line 1 column 1 (char 0) / JSONDecodeError Expecting value: line 1 column 1 (char 0) / JSONDecodeError Expecting value: line 1 column 1 (char 0) |
| `https://api.apibdzy.com/api.php/provide/vod` | HTTPError HTTP Error 403: Forbidden / HTTPError HTTP Error 403: Forbidden / HTTPError HTTP Error 403: Forbidden |
| `https://api.maoyanapi.top/api.php/provide/vod` | JSON 3项 / JSON 2项 / JSON 0项 |
| `https://cj.lzcaiji.com/api.php/provide/vod` | JSON 13项 / JSON 11项 / JSON 4项 |
| `https://api.guangsuapi.com/api.php/provide/vod` | JSON 9项 / JSON 10项 / JSON 0项 |
| `https://www.hongniuzy2.com/api.php/provide/vod` | JSON 9项 / JSON 10项 / JSON 0项 |
| `https://hhzyapi.com/api.php/provide/vod` | JSON 9项 / JSON 10项 / JSON 0项 |

如意怪奇第五季媒体HTTP403；魔都怪奇第五季首分片RemoteDisconnected（HLS声明1920×1080只算声明）；极速所选三份HLS含加密标记，本次不取密钥、不作播放结论。新版量子 `https://cj.lzcaiji.com/api.php/provide/vod` 搜索返回三剧目录，但选中三剧首季及怪奇第五季详情请求均HTTP404，未取得HLS。猫眼毒师结果只有电影/无关短剧，其他返回剧集目录的接口本次没有做媒体验证，均不能列成已可播或4K。

附成功样本精确请求与散列（非凡完整机器记录另在JSON）：

### ruyi · 怪奇物语第一季 · ID 26019

- 详情：[API请求](https://cj.rycjapi.com/api.php/provide/vod?ac=detail&ids=26019)；目录 8 条，线路 `rym3u8`。
- HLS：[实际清单](https://cdn7.ryplay7.com/20241027/5998_f0eb5aa5/index.m3u8)；最终媒体清单：[URL](https://cdn7.ryplay7.com/20241027/5998_f0eb5aa5/2000k/hls/index.m3u8)。
- 首分片：[URL](https://cdn7.ryplay7.com/20241027/5998_f0eb5aa5/2000k/hls/c5cc5b26db3403fd3c68c36bb4b4468f.ts)，HTTP206；Range返回HTTP200也只读到既定上限。
- 媒体清单SHA-256：`4d99d361a55c26209ecee84e116c7b88bbb1fcd141a792fd5299621584cabc1b`。
- 本次读取的首分片字节SHA-256：`a9feb3496b0f287ede2f727477455de807a636545c26a3f91fb121fcf4fdef14`（仅这些读取字节，不能当完整影片哈希）。

### ruyi · 绝命毒师第一季 · ID 61113

- 详情：[API请求](https://cj.rycjapi.com/api.php/provide/vod?ac=detail&ids=61113)；目录 7 条，线路 `rym3u8`。
- HLS：[实际清单](https://cdn7.ryplay7.com/20251015/16478_117222c5/index.m3u8)；最终媒体清单：[URL](https://cdn7.ryplay7.com/20251015/16478_117222c5/2000k/hls/index.m3u8)。
- 首分片：[URL](https://cdn7.ryplay7.com/20251015/16478_117222c5/2000k/hls/61162d0d562651ea04bf7dc7eb7a6626.ts)，HTTP206；Range返回HTTP200也只读到既定上限。
- 媒体清单SHA-256：`9cc692dee111519edab0384c47159ddbc24d38f59694e1ddf76f0c29db794082`。
- 本次读取的首分片字节SHA-256：`37ae69a4c937ae58ddc4b408513d1a122b398dbd15a46fa60949745af9245528`（仅这些读取字节，不能当完整影片哈希）。

### ffzy · 怪奇物语第五季 · ID 89681

- 详情：[API请求](http://ffzy5.tv/api.php/provide/vod?ac=detail&ids=89681)；目录 8 条，线路 `ffm3u8`。
- HLS：[实际清单](https://svip.feifei-play.com/20251127/32060_abeef011/index.m3u8)；最终媒体清单：[URL](https://svip.feifei-play.com/20251127/32060_abeef011/2000k/hls/mixed.m3u8)。
- 首分片：[URL](https://svip.feifei-play.com/20251127/32060_abeef011/2000k/hls/48736a4193c14ed7657bd48d5d47cab2.ts)，HTTP206；Range返回HTTP200也只读到既定上限。
- 媒体清单SHA-256：`4f6479cebf10cd1b919f5ba5d249e5dd27a36f0ac3d6999f5d6bdac44d8cefc5`。
- 本次读取的首分片字节SHA-256：`43bd01c1e1468c41c48dbbe9924ffc6b613544e68ba70f244400f736361c7587`（仅这些读取字节，不能当完整影片哈希）。

### ffzy · 怪奇物语第一季 · ID 24151

- 详情：[API请求](http://ffzy5.tv/api.php/provide/vod?ac=detail&ids=24151)；目录 8 条，线路 `ffm3u8`。
- HLS：[实际清单](https://vip.ffzy-play10.com/20221220/3857_0a7bf8a2/index.m3u8)；最终媒体清单：[URL](https://vip.ffzy-play10.com/20221220/3857_0a7bf8a2/2000k/hls/mixed.m3u8)。
- 首分片：[URL](https://vip.ffzy-play10.com/20221220/3857_0a7bf8a2/2000k/hls/37f6dc6245171133cfec0676b278c06a.ts)，HTTP206；Range返回HTTP200也只读到既定上限。
- 媒体清单SHA-256：`42bb7cfdbada1c4cf1189b7a4beb306e28d586f5863fc3450b74c60258c0bf81`。
- 本次读取的首分片字节SHA-256：`1a2ffdd8692f110a613ec5460b1a84a82afc63d578edbe192734f27dcf6b245d`（仅这些读取字节，不能当完整影片哈希）。

### ffzy · 绝命毒师第一季 · ID 35495

- 详情：[API请求](http://ffzy5.tv/api.php/provide/vod?ac=detail&ids=35495)；目录 7 条，线路 `ffm3u8`。
- HLS：[实际清单](https://vip.ffzy-online3.com/20230207/12246_1746a5f4/index.m3u8)；最终媒体清单：[URL](https://vip.ffzy-online3.com/20230207/12246_1746a5f4/2000k/hls/mixed.m3u8)。
- 首分片：[URL](https://vip.ffzy-online3.com/20230207/12246_1746a5f4/2000k/hls/1761ebc5a7ccb0d40bd9beb2d2efb7dd.ts)，HTTP206；Range返回HTTP200也只读到既定上限。
- 媒体清单SHA-256：`58b795acf23fc49a1b1315302bc0248383ca940a59a33eeb76563f2d7c46ad14`。
- 本次读取的首分片字节SHA-256：`e3d0183a2da4a69b00b49eaa4badea473ca554a81b14595d4110a794f2443197`（仅这些读取字节，不能当完整影片哈希）。

### ffzy · 火线第一季 · ID 39350

- 详情：[API请求](http://ffzy5.tv/api.php/provide/vod?ac=detail&ids=39350)；目录 13 条，线路 `ffm3u8`。
- HLS：[实际清单](https://vip.ffzy-online3.com/20230224/16629_f2ac5d3e/index.m3u8)；最终媒体清单：[URL](https://vip.ffzy-online3.com/20230224/16629_f2ac5d3e/2000k/hls/mixed.m3u8)。
- 首分片：[URL](https://vip.ffzy-online3.com/20230224/16629_f2ac5d3e/2000k/hls/8af898d7fbfbd52707b313e081f61752.ts)，HTTP206；Range返回HTTP200也只读到既定上限。
- 媒体清单SHA-256：`7f8ed5d74aa6135d252570d3aef61fcbf7415cafbc71c0798739e326373d9d98`。
- 本次读取的首分片字节SHA-256：`e9fbd77651db05672d3bece353b424817da01ab436cb7d4eb8abff7961824a98`（仅这些读取字节，不能当完整影片哈希）。

### mdzy · 怪奇物语第一季 · ID 10734

- 详情：[API请求](https://www.mdzyapi.com/api.php/provide/vod?ac=detail&ids=10734)；目录 9 条，线路 `modum3u8`。
- HLS：[实际清单](https://play.modujx12.com/20240701/gLgDbkaF/index.m3u8)；最终媒体清单：[URL](https://play.modujx12.com/20240701/gLgDbkaF/2000kb/hls/index.m3u8)。
- 首分片：[URL](https://play.modujx12.com/20240701/gLgDbkaF/2000kb/hls/fBtI279J.ts)，HTTP206；Range返回HTTP200也只读到既定上限。
- 媒体清单SHA-256：`b0931edb696ca46c10c78cfda00e8065cb8c4167c97a0f0774cf5a95a0c10932`。
- 本次读取的首分片字节SHA-256：`ba7f5df983cee27fe8663d116741072ba3f9ed567cb77b621347e45194ce70f0`（仅这些读取字节，不能当完整影片哈希）。

### mdzy · 绝命毒师第一季 · ID 12430

- 详情：[API请求](https://www.mdzyapi.com/api.php/provide/vod?ac=detail&ids=12430)；目录 8 条，线路 `modum3u8`。
- HLS：[实际清单](https://play.modujx12.com/20240705/FOo82mCK/index.m3u8)；最终媒体清单：[URL](https://play.modujx12.com/20240705/FOo82mCK/2000kb/hls/index.m3u8)。
- 首分片：[URL](https://play.modujx12.com/20240705/FOo82mCK/2000kb/hls/S7WqkpjM.ts)，HTTP206；Range返回HTTP200也只读到既定上限。
- 媒体清单SHA-256：`c9a800da212d0ffcf904e70df0cdf158f0892d7897536e68944b0bcc65a4380f`。
- 本次读取的首分片字节SHA-256：`bb997331206e1728931915af13ba9ca1aa7b349c90d17300424f9194900df67c`（仅这些读取字节，不能当完整影片哈希）。

### mdzy · 火线第一季 · ID 11808

- 详情：[API请求](https://www.mdzyapi.com/api.php/provide/vod?ac=detail&ids=11808)；目录 14 条，线路 `modum3u8`。
- HLS：[实际清单](https://play.modujx12.com/20240704/vuTCApIU/index.m3u8)；最终媒体清单：[URL](https://play.modujx12.com/20240704/vuTCApIU/2000kb/hls/index.m3u8)。
- 首分片：[URL](https://play.modujx12.com/20240704/vuTCApIU/2000kb/hls/aXyV2uOl.ts)，HTTP206；Range返回HTTP200也只读到既定上限。
- 媒体清单SHA-256：`63e82d6a1a52579a9a5ec5407e3036aec02e2a84f006ef52b7ff690620529344`。
- 本次读取的首分片字节SHA-256：`ec5e1ceb7d8531c100537e3736de750ee30af9d4d62694900deae46d974a58ef`（仅这些读取字节，不能当完整影片哈希）。
