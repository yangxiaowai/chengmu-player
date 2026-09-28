# 自然画质与播放器交互改进

调研日期：2026-09-28。范围：继续使用映川现有 SwiftUI / AVPlayer / Metal 架构，保留 v0.3 播放界面与旧版片库、选集、字幕、广告功能。以下是公开一手资料对本轮设计的启发，未复制这些项目的实现代码。

## 1. 原片是可随时回到的参照

[mpv 的滤镜命令](https://mpv.io/manual/stable/#filter-commands)支持运行时添加、移除、启停滤镜，并在更改后反馈滤镜状态。[IINA 的 FilterWindowController](https://github.com/iina/iina/blob/develop/iina/FilterWindowController.swift)在滤镜操作成功后才发出屏幕提示。

映川采用独立实现：底栏的半圆按钮临时显示原片，再点恢复所选模式；对照不写入偏好，也不换片或重建播放时钟。画质菜单和画质工作室共用选择入口。菜单中的勾选表示保存的选择，底栏状态表示当前实际呈现；两个含义不混用。本轮不增加瞬时提示计时器，减少与自动隐藏、字幕、广告撤销之间的状态竞争。

## 2. 画质增强不应等于更强的锐化

[mpv 的 sharpen / deband 参数说明](https://mpv.io/manual/stable/#options-sharpen)明确说明正向锐化会增加振铃与锯齿；去色带的 grain 参数还会加入噪声。提高处理强度不意味着更好的主观观感。

映川本轮将自然降噪与缩放分别说明，4K 标注为输出尺寸，不描述为恢复原生 4K 细节。默认值和旧设置迁移由画质策略负责；界面保留原片选项及对照入口，方便用户以肤色、暗部颗粒、字幕边缘和运动画面判断处理是否适合当前片源。Apple AI 是否可用及实际输出以设备和片源运行结果为准。

## 3. 所选功能与真实播放状态分开

[IINA 的 SidebarVideoPane](https://github.com/iina/iina/blob/develop/iina/SidebarVideoPane.swift)根据 HDR 是否可用显示相关控件，并用当前状态更新开关。[Jellyfin 的兼容说明](https://jellyfin.org/docs/general/clients/codec-support/)区分直接播放、封装或音频转换与视频转码，强调依片源和客户端能力选择实际路径。

映川画质菜单、底栏、画质工作室和视听适配页统一读取播放器的实际状态：所选模式、正在呈现的模式、回退原因、已知的源尺寸和输出尺寸。只在尺寸大于零时显示，避免将待探测状态写成 0×0；HDR 原生直通和性能回退不亮起增强图标。临时原片对照有明确标记，也能从菜单结束。

## 4. 保留播放区空间与熟悉的位置

[IINA 的主窗口实现](https://github.com/iina/iina/blob/develop/iina/MainWindowController.swift)将屏幕控制、提示、进度预览和侧栏分开管理。映川继续保留 v0.3 的视频铺满、渐隐浮栏和折叠选集；新增对照按钮沿用 42 点点击区域和中文辅助功能说明。

展开选集后，底栏不再重复显示“下一集”，该功能仍在侧栏中；腾出的空间用于对照按钮。选集关闭和全屏时底栏仍显示下一集。状态说明采用单行截断，完整内容在画质菜单和视听适配页可读，避免压缩播放按钮或让 1040 点窗口中的控制条溢出。状态文字不拦截画布点击。

## 许可与复用边界

- [IINA LICENSE](https://github.com/iina/iina/blob/develop/LICENSE)：GPLv3。
- [Jellyfin Desktop LICENSE](https://github.com/jellyfin/jellyfin-desktop/blob/master/LICENSE)：仓库提供 GPLv2 许可证。
- [mpv Copyright](https://github.com/mpv-player/mpv/blob/master/Copyright)：默认 GPLv2+；无 GPL-only 文件的特定构建可采用 LGPLv2.1+，还需核对具体文件和依赖的许可。

本轮借鉴交互和技术原则，使用本项目的独立实现。如果以后直接复制源码、链接或分发这些组件，应按对应版本、具体文件和构建依赖处理版权声明、源代码及其他许可义务。

## 验证范围

此文记录调研和设计依据，不代表已完成运行验收。最终构建、对照切换不改变播放位置与偏好的测试、自然降噪样本验证，以及 1040 点窗口 / 全屏检查，以本轮验收记录为准。
