# v0.2.6 播放器体验与稳定性增量

用户要求参照成熟播放器优化，明确播放操作、找片选集换源、卡顿缓冲三个方向都要覆盖。沿当前原生 AVFoundation 架构，不更换播放器内核或引入新的网络片源。

## 目标

1. 操作入口可发现：增加 Mac“播放”菜单、当前时间点击定位、精确时间输入；菜单状态与当前播放器一致，库页和编辑弹窗中不能误操作背景影片。精确跳转支持秒、分:秒、时:分:秒，非法及超出范围必须有明确提示。选择倍速/字幕/音轨时可看到当前项。
2. 剧集与换源：长列表打开时定位当前集，增加上一集；首末集、缺集保持保护。换源显示阶段并可取消，取消保留原画面与候选；异步旧结果不得切集。切线路/换源保留提交时最新的播放意图。
3. 稳定性：依据实际状态统一准备、缓冲、暂停、错误和结束处理；复现后修复暂停被误标缓冲、失败残留播放意图、旧结束事件触发下一集等边界。保留现有合理缓冲参数，不用放大超时或盲目重试掩盖问题。

## 实现边界

根代理负责 PlayerView、CinemaApp、精确时间核心校验和命令/弹窗界面。剧集代理负责 AppModel、独立 PlayerEpisodePanel 与相关回归。稳定性代理负责 PlaybackController 与状态回归。无代理共享写同一个文件。

原有全屏自动隐藏、预览独立解码、字幕保护和GPU处理保持。原始画质、输出4K和AI能力继续区分；这次不承诺所有来源无需VPN、全格式或永不卡顿。

## 验收

核心时间解析与边界测试；换源取消/迟到结果/暂停恢复及集目边界回归；真实本地媒体上的状态与旧通知回归；最终构建原生 UI 验证播放菜单、精确跳转、当前选项、上一集状态、选集定位及取消入口。最后 Release、签名、压缩包完整性核验。

## 一手参考

- VLC 的 Playback 文档说明 Jump to Specific Time 菜单：https://docs.videolan.me/vlc-user/desktop/3.0/en/basic/playback.html
- IINA Input API 建议通过 Menu 提供快捷键，避免独立输入监听造成不一致：https://docs.iina.io/interfaces/IINA.API.Input
- AVPlayer 在 waitingToPlayAtSpecifiedRate 时才应读取 waiting reason：https://developer.apple.com/documentation/avfoundation/avplayer/reasonforwaitingtoplay

参考用于行为取舍，当前新增实现不复制第三方播放器二进制或项目代码。
