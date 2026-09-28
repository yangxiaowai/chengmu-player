# 内置屏幕与扬声器的杜比播放可行性

日期：2026-09-27。基于当前 v0.2.7 源码、当前设备的只读查询以及 Apple 官方资料。用户确认主要使用 Mac 自带屏幕与扬声器。将需求中的名称按 Dolby Vision（杜比视界）与 Dolby Atmos（杜比全景声）理解。本轮是可行性调研，没有修改播放器代码或宣布功能已通过播放验收。

## 结论

硬件与系统路线可行；现版播放器尚不能宣称完整杜比支持。应优先实现兼容杜比片源的识别、原生呈现与状态说明。普通片源的画质/音效增强另行处理，不能称为恢复原始杜比母版。

本机为 MacBook Pro Mac16,1、M4、16GB，内置 Liquid Retina XDR（3024×1964、120Hz），当前音频输出为 MacBook Pro Speakers。Apple 对应[机型规格](https://support.apple.com/zh-cn/121552)列明支持 Dolby Vision、HDR10+/HDR10、HLG 和 Dolby Atmos；内置扬声器播放 Atmos 音乐或视频支持空间音频。其扬声器呈现仍受机身和收听环境限制，不能等同多扬声器家庭影院。屏幕实际像素数也不是3840×2160。

只读查询 `AVPlayer.eligibleForHDRPlayback` 返回 true；屏幕 EDR potential=16、reference=0，首次current=1，留档复查时约1.2，原始留档结果见 `dolby-device-capability-2026-09-27.json`。当前EDR余量是动态值，这些查询不证明正在看的影片以 HDR/Dolby 输出。没有创建播放窗口、改变亮度/声音设置或读取用户正在播放的媒体。

## 当前源码与片源证据

| 部分 | 当前情况 | 需要补齐 |
| --- | --- | --- |
| 原片画面 | `VideoSurface.swift` 已使用 AVPlayerLayer | 根据原始轨道/清单识别 HDR/DV，选择可靠原生路径 |
| GPU增强 | `VideoSurface.swift:106` 请求32BGRA；`EnhancementPipeline.swift:62,118,121` 使用 sRGB 与8位纹理输出 | 现有管线不承担杜比/HDR增强；先保留原生画面 |
| HDR回退 | `EnhancementPipeline.swift:75` 检查解码后的 PQ/HLG 标签 | 在8位转换之前核验资产/轨道；解码后标签可能不足，当前保护不可当作已验证端到端HDR |
| 广告柔化 | 与GPU增强共用像素处理路径 | 杜比保真模式先禁用并说明原因，字幕独立叠加继续保留 |
| 音频 | AVPlayer原始音轨与音轨选择 | 增加真实编码/Atmos证据及所选轨道说明；E-AC-3本身不能证明Atmos |
| HLS检查 | `HLSProbe.swift` 已取分辨率、CODECS、码率 | 补VIDEO-RANGE、音频组、声道/JOC等声明，保留未知状态 |

重读已有 `docs/validation/representative-decode.json`：45个带像素格式的画面记录为 h264/yuv420p，另有8个h264重试记录；53个音频记录为AAC双声道。这是先前指定样本的保存证据，本轮没有重新探测整个来源目录。当前没有足够证据将《怪奇物语》《绝命毒师》《火线》的已接入版本标为Dolby Vision或Atmos。

## 可行实现路线

1. 区分“片源格式”“所选轨道”“设备能力”和“已验证呈现”。不以文件名、4K分辨率、HEVC或E-AC-3单一字段判定杜比，也不把硬件可用标记写成正在输出。
2. HDR/Dolby片源优先使用AVPlayer＋AVPlayerLayer，避免通过现有8位增强管线。Apple明确说明兼容素材和设备的[Dolby Vision 8.4原生播放与动态元数据处理](https://developer.apple.com/av-foundation/Incorporating-HDR-video-with-Dolby-Vision-into-your-apps.pdf)；其他profile、封装及网络播放组合分别验证，不能外推到所有蓝光/MKV版本。修改像素会影响动态元数据的有效性。
3. 原始Atmos音轨通过系统AVPlayer音频路线输出；Apple的[空间音频开发说明](https://developer.apple.com/videos/play/wwdc2021/10265/)和[macOS音频API说明](https://developer.apple.com/videos/play/wwdc2023/10233/)支持这条方向。不得将普通立体声空间化、一般多声道或系统报告的输出通道数当作Atmos实播证据。
4. 以已知格式测试素材验证实际选轨、色彩、高光、音画同步、字幕、全屏、切源和回退。最后再接入能获取到的真实影视版本；若没有相应片源，明确保留普通版本。
5. 普通SDR的降噪、锐化、4K缩放继续作为独立能力。SDR到HDR、对白增强、虚拟环绕可以作为后续独立效果，但不能承诺重建已经丢失的高光、颜色或原始声音对象。

## 平台限制与验收边界

当前macOS SDK的 `AVPlayer.availableHDRModes`、AVAudioSession部分空间音频/渲染模式查询不适用于macOS，不能直接照搬iOS示例。`eligibleForHDRPlayback` 的SDK注释明确否认其能证明当前片源、显示屏或输出已经是HDR。

Apple的[Mac HDR说明](https://support.apple.com/zh-cn/102205)确认内建显示屏支持杜比视界等格式；亮度、环境与电池优化设置仍可影响HDR体验。本轮未修改这些设置。

未进行实际杜比样片播放或听音验收，未新增杜比影视片源，未做SDR转HDR实现，也未验证现有增强与杜比动态元数据共存。Apple官方示例页本次网页提取未得到可用样片内容，没有将其记为已成功播放。
