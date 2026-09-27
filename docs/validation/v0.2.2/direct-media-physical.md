# 当前网络媒体源分层探测

检测时间：2026-09-27T05:33:54.285993+00:00

本次为显式物理接口探针：curl 以 `--interface en0 -4` 绑定 socket，并在每次请求的 verbose 诊断中核实绑定成功。DNS 通过 TLS 校验的 [阿里公共 DNS](https://www.alidns.com) `/resolve` 查询取得，DNS 自身也绑定相同物理接口，并用其官方 IPv4 223.5.5.5 启动解析。API、HLS、分片及每次重定向均用 `--resolve` 指定独立解析结果，没有使用系统合成 DNS，也没有修改系统代理、VPN 或路由配置。

本次网络背景：explicit-physical-socket-binding-with-independent-doh。

| 来源 | 代表样本 | 搜索与详情 | HLS / 片段前缀 |
|---|---|---|---|
| 电影天堂目录 | 怪奇物语第一季 | 通过 | 读取 2 个片段前缀，共 426,268 字节 |
| 非凡目录 | 怪奇物语第一季 | 失败（详情：curl exit 28; HTTP 0） | 未通过或未执行 |
| 如意目录 | 琅琊榜 | 失败（搜索：curl exit 35; HTTP 0） | 未通过或未执行 |
| 魔都目录 | 怪奇物语第一季 | 通过 | 读取 2 个片段前缀，共 155,664 字节 |
| 无尽目录 | 流浪地球 | 失败（搜索：curl exit 28; HTTP 0） | 未通过或未执行 |

检测最多并发 3 个请求，每个请求最多 12 秒，目录和清单上限 4 MiB，每个样本最多读取 2 个片段、每段 256 KiB。所有媒体字节仅在内存中存在，没有保存媒体文件或密钥。

本次只验证目录内容、HLS 清单及片段前缀可取，不包含视频解码、声音、整集连续播放、原生 4K、影片画面身份核对或中国大陆无 VPN 认证。样本结果不能推广到全库。

复现：`python3 scripts/probe-direct-media.py`；如在关闭 VPN 后重测，可增加 `--network-context user-reported-vpn-off` 并保存到新输出文件，保留前次证据。

物理接口成功说明这些特定请求在当前设备上按接口约束访问；本次没有记录公网出口 IP，也未独立核验网络所在地区。它不能证明全国各地、各运营商、所有影片或后续时间都可用。

物理模式复现：`python3 scripts/probe-direct-media.py --physical-interface en0`；默认另存 `direct-media-physical.json/.md`。
