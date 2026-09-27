# 大陆网络可达性核验

核验日期：2026-09-27。目标是筛选不依赖 VPN 的网络来源，并把目录、播放清单和实际媒体分片的可达性分别记录。这里只研究连接证据；不调整用户的代理、VPN、DNS 或路由设置。

## 证据边界

- 本轮主代理只读检查发现，当前 Mac 的系统 HTTP/HTTPS/SOCKS 代理启用，两个公开目标路由经过 `utun9`。因此已有的本机播放成功结果不能补写为“中国大陆无 VPN 播放通过”。
- `curl --noproxy '*'` 排除显式代理，但不移除系统隧道路由。curl 8.7.1 上游和 Apple 公开源码的 `bindlocal` 在 `SO_BINDTODEVICE` 可用时绑定设备，否则才退回本地 IP 地址绑定。**本机 macOS 27 SDK 的 `sys/socket.h:190` 已定义 `SO_BINDTODEVICE`，实际运行 `curl --interface en0 -v` 也输出设备绑定成功**，因此不能沿用“Mac curl 永远只绑定地址”的旧假设。[curl 参数说明](https://curl.se/libcurl/c/CURLOPT_INTERFACE.html)、[curl 8.7.1 源码](https://raw.githubusercontent.com/curl/curl/curl-8_7_1/lib/cf-socket.c)、[Apple curl 源码](https://raw.githubusercontent.com/apple-oss-distributions/curl/main/curl/lib/cf-socket.c)。
- 同一次有界测试中，系统 DNS 给魔都 API 返回 `198.18.0.31` 和 `2001:2::1e`，绑定 `en0` 后连接超时。这些合成/测试网段不是 ITDOG 运营商 DNS 观察到的源站地址；不能把这种失败当作真实源站大陆不可达。物理接口探针必须一起处理 DNS 路径，并保留证据。
- 本机 SDK 的 `netinet/in.h:432` / `netinet6/in6.h:506` 还定义 `IP_BOUND_IF` / `IPV6_BOUND_IF`；Apple XNU 源码说明接口范围路由约束，Network framework 也提供要求指定接口的参数。仍需记录 DNS、最终路径和测试地点，不能从“本地地址是 Wi-Fi 地址”或“服务器 IP 在中国”推断大陆家庭宽带均可访问。[Apple XNU IP 路由实现](https://raw.githubusercontent.com/apple-oss-distributions/xnu/main/bsd/netinet/ip_output.c)、[Apple 接口要求文档](https://developer.apple.com/documentation/network/nw_parameters_require_interface(_:_:))。

## 公开大陆节点实测

使用 [ITDOG HTTP 检测页面](https://www.itdog.cn/http/)，通过 CUA 创建独立后台浏览器页；选择中国电信、中国联通、中国移动，取消港澳台及海外；使用运营商 DNS、默认 GET 请求和自动 HTTP 版本。未登录、未付费、未解决验证码。测试输入的是公开目录 URL，不包含用户账号、令牌或个人媒体地址。

注意：首次打开页面显示的是旧示例数据，日期可追溯到 2021 年，未计入证据。以下结果均是明确填入当前目录 URL 并点击“快速测试”后取得的当次结果。节点地理位置和运营商是检测服务标注，未独立审计节点出口；这是第三方节点采样，不是全国全部宽带或本机家庭网络验收。

| 目录 | 当次节点数 | HTTP 200 | 其他结果 | 含义 |
| --- | ---: | ---: | --- | --- |
| 如意 `cj.rycjapi.com` | 271 | 1 | 267 失败，3 未返回 | 本次检测表现差，不列为已确认的稳定大陆来源 |
| 魔都 `www.mdzyapi.com` | 252 | 177 | 21 个 503，22 失败，32 未返回 | 多运营商节点取得目录 HTTP 响应，仍有明显线路差异 |
| 无尽 `api.wujinapi.com` | 270 | 264 | 6 失败 | 本轮三个目录中 HTTP 成功占比最高，尚未测该来源媒体 |

具体请求均为对应默认端点后加 `?ac=list&pg=1`。目录 URL 见 `Sources/CinemaCore/MediaModels.swift`。

魔都 HTTP 200 节点分布：电信 35/69、联通 65/87、移动 77/96。示例包括上海电信家庭节点 0.355 秒、山东济南联通 1.513 秒、上海移动家庭节点 1.847 秒。如意唯一 HTTP 200 样本为江西南昌移动家庭节点 2.078 秒。失败可能发生在解析、连接、TLS、服务拒绝或探针兼容环节，仅凭“失败”不归因为网络封锁。

逐运营商完整汇总（`--` 保守计为未返回，不计成功；节点总数由当次页面表格逐行统计）：

| 目录 | 运营商 | 总数 | HTTP 200 | HTTP 503 | 失败 | 未返回 |
| --- | --- | ---: | ---: | ---: | ---: | ---: |
| 如意 | 电信 | 88 | 0 | 0 | 88 | 0 |
| 如意 | 联通 | 87 | 0 | 0 | 84 | 3 |
| 如意 | 移动 | 96 | 1 | 0 | 95 | 0 |
| 魔都 | 电信 | 69 | 35 | 0 | 4 | 30 |
| 魔都 | 联通 | 87 | 65 | 15 | 7 | 0 |
| 魔都 | 移动 | 96 | 77 | 6 | 11 | 2 |
| 无尽 | 电信 | 87 | 86 | 0 | 1 | 0 |
| 无尽 | 联通 | 87 | 85 | 0 | 2 | 0 |
| 无尽 | 移动 | 96 | 93 | 0 | 3 | 0 |

这些目录测试只测指定 HTTP URL，HTTP 200 没有进一步验证响应正文是有效 JSON。因此可以记为“大陆节点目录 HTTP 有成功样本”，不能标记“该来源所有影片大陆免 VPN 可播”。

## 同一影片的播放清单和分片

选取魔都《怪奇物语第一季》目录 ID `10734`；地址由本轮本地目录和 HLS 解析实际取得，不是猜测地址。仅补这一组媒体，默认 GET、运营商 DNS、三大运营商选择不变：

- 子播放清单：`https://play.modujx12.com/20240701/gLgDbkaF/2000kb/hls/index.m3u8`
- 首个分片：`https://play.modujx12.com/20240701/gLgDbkaF/2000kb/hls/fBtI279J.ts`

| 资源 | 运营商 | 节点 | HTTP 200 | HTTP 206 | 失败 | 未返回 |
| --- | --- | ---: | ---: | ---: | ---: | ---: |
| 子清单 | 电信 | 87 | 83 | 0 | 4 | 0 |
| 子清单 | 联通 | 87 | 85 | 0 | 2 | 0 |
| 子清单 | 移动 | 96 | 90 | 0 | 6 | 0 |
| 首分片 | 电信 | 87 | 71 | 14 | 2 | 0 |
| 首分片 | 联通 | 87 | 78 | 7 | 2 | 0 |
| 首分片 | 移动 | 96 | 81 | 10 | 5 | 0 |

子清单总计 258/270 个 HTTP 200。分片总计 230 个 HTTP 200、31 个 HTTP 206、9 个失败；206 单独保留，未混称为完整资源下载。查看吉林四平电信家庭节点的 206 响应头，取得 `content-range: bytes 0-119003/119004`、`content-length: 119004`、`content-type: application/octet-stream`；公共 UI 没有展示探针完整请求头，不能断言是否自动发出了 Range 请求。

该结果支持“这个影片的子清单和首个分片，在大陆三运营商节点取得 HTTP 成功样本”。没有拿到这些节点的响应字节来验证 HLS/TS 内容或解码；未在远程节点另测入口主清单、后续分片、持续播放、全部集数或画面身份。第三方节点 HTTP 证据与本机媒体解码证据不能拼接成未经实测的完整大陆播放承诺。

当次逐运营商计数、准确 URL、URL 哈希和响应头摘录保存于 [节点采样记录](../validation/v0.2.2/mainland-public-node-samples.json)。

## 物理网卡探针可行性

在不改变任何系统设置的前提下，验证了单次进程显式绑定物理接口、禁用 HTTP 代理并绕过当前合成 DNS 的方案：

1. [AliDNS 官网](https://www.alidns.com/) 列出 `dns.alidns.com` 和公共 IPv4 `223.5.5.5` / `223.6.6.6`。[官方公共 DNS API 参考 PDF](https://static-aliyun-doc.oss-cn-hangzhou.aliyuncs.com/download%2Fpdf%2F171662%2FAPI_Reference_intl_en-US.pdf) 记录 `/resolve` 的 GET 参数 `name`、`type`。该 PDF 是历史公开接口文档；本轮另外进行了实际无账号请求验证，不将最新付费 HTTPDNS 鉴权 API 与公共接口混用。
2. `curl -q --noproxy '*' --proxy '' --interface en0 -4 --resolve 'dns.alidns.com:443:223.5.5.5'` 请求 `https://dns.alidns.com/resolve?name=www.mdzyapi.com&type=A`，TLS 校验成功、HTTP 200、DNS Status 0，返回 `104.21.61.161` 和 `172.67.212.38`。verbose 明确显示 `socket successfully bound to interface 'en0'`。
3. 对魔都目录使用同样物理接口和代理选项，再通过 `--resolve 'www.mdzyapi.com:443:104.21.61.161'` 保持原域名、SNI 和 TLS 验证，取得 HTTP 200、6346 字节、有效 JSON 20 条，耗时 1.733598 秒。连接 IP 与给定真实 DNS 结果相同。

这说明设备绑定和真实 DNS 可用于当前 Mac 的额外探测，不需关闭用户 VPN，也不需改系统 DNS。没有独立核验物理出口所在地；仅凭这次成功仍不认证“中国大陆无 VPN”。后续同协议复验五个来源由专用探针执行，旧报告和新报告分别保留。上述最小可行性证据见 [物理接口探针记录](../validation/v0.2.2/physical-interface-feasibility.json)。

后续五来源物理接口探针已完成：电影天堂和魔都的所选样本通过搜索、详情、HLS、分片检查；非凡搜索成功但详情连接超时，如意搜索 TLS 失败，无尽搜索超时。详见 [独立物理接口报告](../validation/v0.2.2/direct-media-physical.md) 和 [原始记录](../validation/v0.2.2/direct-media-physical.json)。这是一次有限网络样本，应优先其成功来源并保留可重测能力；第三方无尽目录测试较好而本机物理请求超时，正说明地区和链路之间存在差异。

## 应用中建议的判断

1. 分开显示“当前网络目录检测”“当前影片媒体检测”和“大陆节点采样”。记录时间和失败阶段，过期记录不充当实时保证。
2. 优先实际能取得目录、HLS 和媒体分片的来源；单片失败时切换同片的其他版本，保留用户手选的来源。
3. 在无系统代理、无可疑隧道且用户确认大陆网络的环境进行本机复验，才将结果描述为该次大陆网络直连通过；不将这一有限样本扩大到全国可用。
