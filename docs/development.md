# 开发与验证

[返回产品首页](../README.md) · [使用指南](user-guide.md)

本文面向开发与问题排查。验证日志记录实际边界，不能将合成帧测试、短媒体检查与完整影片播放混为一谈。

## 构建和测试

开发机需要macOS15+和Swift工具链；Apple AI需要macOS26+及运行时能力支持。项目没有第三方 Swift 包依赖。构建脚本调用 Python；按本项目约定，所有 Python 命令在 conda 的 `searchformoney` 环境运行。普通用户下载发行包即可，不需要开发环境。

```bash
conda run -n searchformoney --no-capture-output bash scripts/swift.sh test
conda run -n searchformoney --no-capture-output bash scripts/build-app.sh release
```

`scripts/swift.sh`会在`.build`中准备匹配的SwiftPM公开接口，解决此开发机CLT中残留的旧版private接口；不会修改系统工具链。构建脚本先在 `.build` 中组装并验证应用，再安装到 `dist/澄幕.app`，将旧版移至 `dist/历史版本/`。若检测到旧版仍在运行，则保留暂存应用并输出重新安装命令，正常退出后可继续安装。最终.app只依赖macOS系统框架，不需要用户安装Python、FFmpeg或其他播放器。FFmpeg仅用于开发期媒体核验。

各版本的验证范围见验收记录；核心测试、GPU合成帧比较、原生窗口交互和完整影片观看分别记录。

诊断命令（运行播放测试时静音）：

```bash
dist/澄幕.app/Contents/MacOS/Cinema --benchmark
dist/澄幕.app/Contents/MacOS/Cinema --validate --seconds 1800 --title 怪奇物语 --mode clarity --report docs/validation/playback-report.json
```

首条处理合成帧，不能替代网络播放验证。第二条实际检索、内嵌播放并记录AVPlayer/GPU指标；不会完整验证剧情身份或主观画质。


## 当前证据与未解决范围

详细记录见`docs/validation`，本轮时域修复与模型评估见[v0.3.2验收记录](验收记录-v0.3.2.md)，此前版本整合、降噪调整与原片对照见[v0.3.1验收记录](验收记录-v0.3.1.md)，播放页重设计见[v0.3.0验收记录](验收记录-v0.3.0.md)，杜比适配与共享帧广告识别见[v0.2.9验收记录](验收记录-v0.2.9.md)，此前本地自动跳广告见[v0.2.8验收记录](验收记录-v0.2.8.md)，自动隐藏修复见[v0.2.7验收记录](验收记录-v0.2.7.md)，操作、选集换源和稳定性见[v0.2.6验收记录](验收记录-v0.2.6.md)，进度预览与按钮响应见[v0.2.4验收记录](验收记录-v0.2.4.md)，点击与广告柔化见[v0.2.3验收记录](验收记录-v0.2.3.md)，媒体连接改动见[v0.2.2验收记录](验收记录-v0.2.2.md)，v0.2.1全屏改动见[全屏验收记录](验收记录-v0.2.1.md)，媒体与画质证据见[v0.2记录](验收记录-v0.2.md)，v0.1历史证据见`docs/验收记录.md`。清单可达、短样本解码、实际应用播放、整集观看是不同证据。

- v0.2新增如意、魔都、无尽：分类浏览与第2页、搜索第2页均经过实际服务核验；12个电影/国产剧/美剧/动画短样本中10个通过2秒解码，其余失败细节保留。见[来源扩充报告](validation/v0.2/source-expansion.md)。这不代表完整观看、全站稳定或所有作品唯一可用。
- v0.1的电影天堂目录（dytt）和非凡目录（ffzy）保留。前者完成三剧164集基础清单检查及每季首、中、末集共45个短解码样本，后者已核验三剧目录、详情及部分媒体样本；两个目录不代表独立基础设施，也不代表两边所有剧集均已完整观看。证据见[主来源报告](validation/source-report.json)、[代表样本报告](validation/representative-decode.json)和[备用来源报告](validation/backup-source-probe.json)。
- 该目录随时可能变化；影片供应许可未核验。官方平台网页不是通用媒体链接，本程序不登录会员账号、不提取浏览器凭证或绕过DRM。
- 核心播放采用AVFoundation。HLS、MP4等是否可播取决于实际编码；尚未集成libmpv，不能承诺MKV、所有音频编码和全格式字幕。
- 没有验证到三剧的原生 4K 来源；GPU 缩放是否改善观感取决于片源和观看条件，不能称为原生 4K 或 AI 4K。
- HDR 增强（把 SDR 转成 HDR 或改写杜比动态元数据）、多设备同步、完整 ASS 排版和通用 1080p→4K AI 模型尚未实现；本轮做的是按片源识别并保留原生杜比/HDR，不是转换。
- 未在实际杜比母版上核对动态元数据呈现、屏幕 EDR 效果或扬声器 Atmos 听感；官方 Apple 样本本轮只完成声明与变体读取，静音无窗口探测在 20 秒内未推进播放，因此不声称已播放杜比内容。
- 依赖子流的 `dec3` 布局在不同编码器间字段宽度不一致，本机一律保守判为未知，不排除会漏掉部分真实 Atmos 流。


## 目录与参考

`Sources/CinemaCore`保存来源/清单/历史/字幕逻辑；`Sources/CinemaApp`保存界面、媒体控制和GPU渲染。设计及实施步骤位于`docs/superpowers`，前期研究位于`docs/research`。

体验和工程参考包括[mpv](https://github.com/mpv-player/mpv)、[IINA](https://github.com/iina/iina)、[Jellyfin](https://github.com/jellyfin/jellyfin)、[LibreTV](https://github.com/LibreSpark/LibreTV)和MoonTV系项目。当前产品代码为本项目实现，没有直接打包这些项目的播放器二进制或模型权重；片源配置线索及核验范围另见研究报告。
