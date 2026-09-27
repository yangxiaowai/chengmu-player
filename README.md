# 映川 · 个人影视播放器

Mac原生应用：检索网络影视目录、选择集数、在软件内播放，并在播放过程中使用GPU增强画面。源码与实际应用都在本目录。

## 启动

双击 `dist/映川.app`。当前安装包面向 Apple Silicon Mac，为本地签名版本。首次打开会检索《怪奇物语》《绝命毒师》《火线》的目录，点击海报、选择集数开始播放。也可以搜索其他作品，或从左下角导入影片/媒体链接。

- 播放：空格暂停/继续，左右键前后10秒，F全屏，M静音；支持进度拖动、倍速、选集和下一集。
- 字幕：播放控制区的字幕按钮可选择已有轨道，或导入UTF-8 SRT/VTT/ASS文本；外部字幕可调整时间。ASS文本会提取对白，不支持完整ASS样式/动画。
- 画质：播放页右下角切换“原片”“GPU清晰增强”“GPU增强至4K”“Apple AI超分”；显示实际源尺寸、输出尺寸和回退原因。
- 来源：内置“电影天堂目录”和“非凡目录”两个公开接口，在“媒体来源”中启停，也可以添加兼容的HTTPS CMS JSON接口。检索错误会显示。
- 换源：播放页打开右侧“选集”，点击“查找其他片源”，再选择显示来源名与季标题的候选。程序核对同季同集、检查媒体清单后在软件内切换，并在资源就绪后恢复进度。版本时长或剪辑可能不同，恢复位置受新时长限制，需核对画面并按需拖动；候选画质显示为未知，实际画质看播放信息。季数不明确、集名或编号不匹配时保留当前播放。
- 历史：本机保存每集进度与集目上下文，关闭再打开可继续观看；可明确清除。

## 画质模式的含义

| 模式 | 实际处理 |
| --- | --- |
| 原片 | 系统解码与原始画面 |
| GPU清晰增强 | Core Image/Metal去噪及温和锐化，保持源尺寸 |
| GPU增强至4K | 去噪、Lanczos等比例放大、锐化，实际生成最高UHD尺寸的画面；这是GPU修复/缩放，不是AI超分，也不证明原生4K细节 |
| Apple AI超分 | VideoToolbox实际神经网络处理，按设备和输入尺寸查询可用倍率；本机M4已测试720p×1.5到1080p，不支持的1080p输入会显示原因并回到原片 |

增强在播放中进行，不需要等待整集处理完，也不生成整集帧文件。软字幕最后绘制。默认流畅优先，持续超过帧预算或遇到未支持的HDR处理时明确回到原片。能处理4K像素不代表屏幕具备4K物理分辨率，也不代表还原了丢失细节。

## 构建和测试

开发机需要macOS15+和Swift工具链；Apple AI需要macOS26+及运行时能力支持。项目没有第三方包依赖。

```bash
bash scripts/swift.sh test
bash scripts/build-app.sh release
```

`scripts/swift.sh`会在`.build`中准备匹配的SwiftPM公开接口，解决此开发机CLT中残留的旧版private接口；不会修改系统工具链。最终.app只依赖macOS系统框架，不需要用户安装Python、FFmpeg或其他播放器。FFmpeg仅用于开发期媒体核验。

诊断命令（运行测试时静音）：

```bash
dist/映川.app/Contents/MacOS/Cinema --benchmark
dist/映川.app/Contents/MacOS/Cinema --validate --seconds 1800 --title 怪奇物语 --mode upscale4K --report docs/validation/playback-report.json
```

首条处理合成帧，不能替代网络播放验证。第二条实际检索、内嵌播放并记录AVPlayer/GPU指标；不会完整验证剧情身份或主观画质。

## 当前证据与未解决范围

详细记录见`docs/validation`，最终状态以`docs/验收记录.md`为准。清单可达、短样本解码、实际应用播放、整集观看是不同证据。

- 默认接入电影天堂目录（dytt）和非凡目录（ffzy）。前者完成三剧164集基础清单检查及每季首、中、末集共45个短解码样本，后者已核验三剧目录、详情及部分媒体样本；两个目录不代表独立基础设施，也不代表两边所有剧集均已完整观看。证据见[主来源报告](docs/validation/source-report.json)、[代表样本报告](docs/validation/representative-decode.json)和[备用来源报告](docs/validation/backup-source-probe.json)。
- 该目录随时可能变化；影片供应许可未核验。官方平台网页不是通用媒体链接，本程序不登录会员账号、不提取浏览器凭证或绕过DRM。
- 核心播放采用AVFoundation。HLS、MP4等是否可播取决于实际编码；尚未集成libmpv，不能承诺MKV、所有音频编码和全格式字幕。
- 没有验证到三剧的原生4K来源；目前GPU4K路径可以改善显示效果，不能称为原生4K或AI4K。
- HDR增强、多设备同步、完整ASS排版和通用1080p→4K AI模型尚未实现。

## 目录与参考

`Sources/CinemaCore`保存来源/清单/历史/字幕逻辑；`Sources/CinemaApp`保存界面、媒体控制和GPU渲染。设计及实施步骤位于`docs/superpowers`，前期研究位于`docs/research`。

体验和工程参考包括[mpv](https://github.com/mpv-player/mpv)、[IINA](https://github.com/iina/iina)、[Jellyfin](https://github.com/jellyfin/jellyfin)、[LibreTV](https://github.com/LibreSpark/LibreTV)和MoonTV系项目。当前产品代码为本项目实现，没有直接打包这些项目的播放器二进制或模型权重；片源配置线索及核验范围另见研究报告。
