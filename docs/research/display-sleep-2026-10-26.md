# 播放时保持屏幕常亮：成熟播放器参考与本机修复

用户反馈播放时显示器自动变暗/休眠。本轮检查确认：PlaybackController 没有申请显示器保活；本机 AVFoundation SDK 的 AVPlayer.h 说明 `preventsDisplaySleepDuringVideoPlayback` 在 macOS 默认 NO。应用还存在 AVPlayerLayer 与 Metal 两种呈现，保活应由统一播放控制器拥有。

## 参考的一手实现

- [IINA SleepPreventer.swift（固定提交）](https://github.com/iina/iina/blob/96f605f6d8c4a3ed7d5d0afac644d8681f766757/iina/SleepPreventer.swift)：主线程统一检查播放器状态；持有一份 `ProcessInfo` activity，重复请求不增加 token，停止后配对结束；有用户设置及音频场景策略。源码注释也记录了系统电源管理异常的历史问题，不能只设置布尔值就宣称系统已接受请求。
- [mpv mac/common.swift（固定提交）](https://github.com/mpv-player/mpv/blob/baa3e11d42cb7978da634a8a6a3a55fe074d01be/video/out/mac/common.swift)：通过 `IOPMAssertionCreateWithName` 和 `PreventUserIdleDisplaySleep` 申请保活，保存 assertion ID，恢复休眠时释放。该做法适合自绘视频输出。
- [Apple AVPlayer 属性](https://developer.apple.com/documentation/avfoundation/avplayer/preventsdisplaysleepduringvideoplayback)、[IOPMAssertionCreateWithName](https://developer.apple.com/documentation/iokit/1557134-iopmassertioncreatewithname)、[显示器空闲休眠类型](https://developer.apple.com/documentation/iokit/kiopmassertiontypepreventuseridledisplaysleep)。本机 SDK 同时核对了接口、macOS 默认值及错误返回。

本项目借鉴生命周期与资源所有权方案，未引入这些项目的二进制、依赖或复制其播放器实现。

## 采用的行为

由主线程的独立对象拥有一份显示器空闲休眠 assertion，使用系统返回码检测申请/释放失败，并在播放菜单显示错误。控制器的播放意图跨越准备、短时缓冲和拖动；暂停、片尾、失败会同步清除意图并释放，避免依赖可能延迟的 KVO 更新。对象析构有额外释放，应用退出时明确暂停并取消睡眠定时。

“播放时保持屏幕常亮”默认开启，旧偏好缺字段时也开启；关闭后即时释放并记住选择，暂停中开启不会申请。原片/增强/画质设置共用控制器，切换模式不创建新的电源策略。系统亮度设置和显示器休眠超时没有被改写，手动锁屏与合盖继续由系统处理。

## 验证方法

先在旧代码运行回归：真实 AVPlayer 已播放本地标记视频，但 `IOPMCopyAssertionsByProcess` 中没有本项目的显示器保活。新代码运行同样的检查，并覆盖开关、暂停后迟到回调、恢复、片尾、坏文件和拥有者析构。

测试只筛选当前 PID、类型 `PreventUserIdleDisplaySleep`、名称 `Chengmu video playback`、level=on 的系统记录，因此其他应用的保活不会让检查误通过。它证明系统已登记请求与释放；没有修改系统超时或强制休眠，也不等于实际屏幕长时间观察。缓冲检查为本地播放时注入 stalled 通知，不称为真实网络断流验收。
