# 社交平台播放器需求核对

日期：2026-10-26。只进行公开读取，没有登录、发帖、点赞、关注或提交用户信息。下述材料是定性线索，不是代表性调查，也不能证明某款播放器现在仍有旧问题。

## 指定平台覆盖

- 小红书：通过真实浏览器打开 `https://www.xiaohongshu.com/explore`，在可见搜索框输入“视频播放器 字幕”。页面明确显示“登录后查看搜索结果”。未读取搜索帖子或评论，不把自动补全词当作用户需求证据。
- X：打开 `https://x.com/search?q=IINA%20subtitles&src=typed_query`，重定向到登录流程。没有读到可引用的帖子。搜索引擎返回的 X 帮助中心是官方产品文档，不冒充用户反馈。
- Instagram：打开 `https://www.instagram.com/`，可见登录入口，没有读取到用户讨论。
- 三个平台的公开索引搜索没有取得足够可核实的直接帖子，因此本轮不能宣称完成它们的用户需求调查。后续有可访问的原帖或已登录环境时补充；不绕过访问限制。

## 可公开读取的社区原帖

| 原帖 | 本次读到的具体场景 | 证据边界与产品取舍 |
|---|---|---|
| [r/macapps：IINA - Free and Open-Source Audio/Video Player](https://www.reddit.com/r/macapps/comments/1fl7ctb/iina_free_and_opensource_audiovideo_player/) | 作者重视字幕语言、大小与时间调整；评论提到连续播放、恢复进度及文件偏好，也有字幕自动加载和偏好反复设置的个人反馈。 | 历史讨论、个人陈述；不据此判定当前 IINA 存在缺陷。澄幕已有连续播放/音量/倍速持久化，本轮补字幕舒适度与可理解的开关。 |
| [r/macbookpro：VLC vs IINA](https://www.reddit.com/r/macbookpro/comments/1ikrt6q/macbook_pro_users_which_media_player_do_you/) | 发帖者直接提到可手动调整字幕大小；评论重视首页显示上次观看位置与原生简洁界面。 | 不采用其中关于续航、HDR、格式兼容性的个人比较作为性能结论。澄幕改善字幕样式及未看完记录视图。 |
| [r/macapps：YouTube-like transcript/subtitle-video sync](https://www.reddit.com/r/macapps/comments/100vibs/any_video_player_app_with_youtubelike/) | 请求读取已有 SRT 时间轴，点击字幕行跳转。 | 特定学习/检索场景，有少量附和，不能说普遍需求。列入后续字幕时间轴计划，本轮不虚报实现。 |

## 综合决策

结合 [GitHub 对标](player-benchmark-2026-10-26.md) 和澄幕现有代码，优先完成：字幕开关保留轨道/外挂文件、字号/背景偏好；继续观看可逆筛选；更清晰的组合筛选与相关性排序。搜索噪声还来自澄幕真实首页中解说、预告与同名衍生内容混排，是项目本身的代码/界面观察，不伪称来自小红书、X 或 Instagram。

未在本轮引入账户绑定、云端字幕上传、第二播放引擎或社交同步。画质目标与实际源参数仍分开；不把社区主观称赞当作4K/杜比输出证据。
