# Findings

- 现有SourceAccessReport.elapsedMS是搜索/详情/清单/分片等流程总耗时，不是网络延时。
- MediaQualityController已提供并发2、URL共享、缓存、取消/令牌和播放挂起，可在共享inspection内先测TTFB再读取画质。
- AVFoundation画质读取不提供统一URLSession首字节时间，需一个有界的轻量GET；复用协调器，避免同URL重复测速。
- 响应失败与画质失败需分开：媒体可能响应正常但元数据不全，或测速超时但系统播放器仍可读取。
- 起点82cf53b，工作区干净，当前0.4.2/build25。

- 口径调整：首个正文块会受Foundation缓冲影响；改为有效HTTP响应头到达时间，收到后取消，不等待正文。协议模拟先用于格式/错误检查，真实本地HTTP用于计时、超时、正文停止和取消边界。

- 最终使用HEAD：GET在本机URLSession可能等待正文才交付响应回调；HEAD明确无正文、可比较连接与服务器响应。HEAD被403/405/501拒绝仅说明无法测速，不阻止画质读取或播放。
