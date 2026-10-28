# 开源播放器参考：缓冲、预览与资源释放

本次对照 [mpv 缓冲选项](https://github.com/mpv-player/mpv/blob/master/DOCS/man/options.rst)、[VLC 预取实现](https://github.com/videolan/vlc/blob/master/modules/stream_filter/prefetch.c) 与 [IINA 播放器核心](https://github.com/iina/iina/blob/develop/iina/PlayerCore.swift)。澄幕使用 AVPlayer，不能直接套用这些播放器的缓存参数，也不能把系统偏好值当成实际缓存量或起播保证。

- 借鉴缓冲等待和中断恢复的思路，继续由系统决定媒体缓冲；实际已缓冲时长来自播放器，下载速度使用播放器可提供的历史观测值。
- 借鉴播放器分离后台任务和用户交互的原则，对缩略图请求采用有限缓存、取消和影片身份校验。IINA 的本地缩略图实现并不证明远程 HLS 预览一定可用。
- 借鉴中断与回收思路，在快速切换影片、取消待处理请求和清理过期回调方面进行独立压力测试。测试结果与尚未覆盖的格式、路由记录于本版验证报告。

这些参考是设计和验证依据，不代表引入了上述项目的播放器内核或其完整实现。
