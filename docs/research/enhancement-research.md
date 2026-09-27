# 影视播放器画质增强可行性调研

核实日期：2026-09-27。范围：公开论文、官方文档和官方代码；没有安装工具、下载模型、处理或上传用户视频，也没有访问另一台主机。主代理只读核验本机为 Apple M4 / 16GB / macOS 27.0，内置屏幕 3024×1964。以下速度、画质和完整媒体保留均未实测。

需求更新：用户后来明确要求流式增强、边看边处理，取代本稿最初的离线主流程。最新建议及本机Apple低延迟超分能力见[流式增强研究](streaming-enhancement-notes.md)与[综合需求v0.2](../需求与可行性评审.md)。下文离线模型、导出及重封装保留为技术背景，不能替代流式播放验收。

## 结论与目标定义

当前建议采用“先找更好的同版本片源，再在观看时流式增强”的顺序。无需等待整集处理；保留原片和随时切回能力。不能把“所有视频输出3840×2160”解释为“所有视频恢复原生4K细节”：严重失焦、压缩、截断或原始拍摄分辨率不足的信息，算法无法保证重建为真实内容。模型可能合成看似清晰但不正确的纹理、人脸或文字。

产品应区分三类：

| 标记 | 含义 | 判断边界 |
|---|---|---|
| 原生/官方4K版本 | 有可靠发行或母版证据的4K资源 | 3840×2160文件本身不能证明拍摄/母版原生4K；“4K发行、母版来源未确认”应单独表示 |
| AI超分至4K | 低分辨率输入经模型重建为4K画面，可直接显示或另行编码 | 可以改善观看感受，不能当作原生细节证明 |
| 缩放至4K | Lanczos、bicubic等插值达到4K尺寸 | 新增采样点，不代表新增真实信息 |

帧插值提高帧率，与空间4K超分是不同任务。V1不默认改变原帧率。非16:9电影应保持宽高比；可输出3840宽的有效画面或加边到3840×2160，不能拉伸。当前内置屏幕不能以像素一一对应方式同时展示完整UHD画面，验收需要100%局部观察；完整4K观感若重要，再在4K显示设备复验。

上述信息损失边界也与[Anime4K作者对重新编码和信息损失的说明](https://github.com/bloc97/Anime4K)一致；算法效果依赖内容，此处对产品标记和验收的安排是工程建议。

## 路线比较

| 方案 | 已核实的能力 | 时间一致性与限制 | 本项目建议 |
|---|---|---|---|
| 高清版本匹配 | 不改造画面，保留更好发行版本原有细节 | 必须核对年份、集数、剪辑版、时长、语言与字幕；高分辨率低码率仍可能较差 | 最高优先级；仅接入用户可访问和可使用的来源，不承诺所有作品存在4K版 |
| FFmpeg | 解复用、滤镜、缩放、编码、音轨/字幕/章节重封装 | 滤镜不是通用AI修复；默认流选择不能保留所有媒体流 | 作为探测、预处理和媒体保留底座 |
| mpv GPU shader | 播放过程中缩放、锐化、色彩管理，可加载GLSL shader | shader并不自动拥有多帧信息；重度shader会影响播放 | V1提供温和且可关闭的播放增强，实际后端需验证 |
| Real-ESRGAN / ncnn Vulkan | 通用及动画模型、分块推理；可作为逐帧基线 | 独立帧处理可能闪烁、纹理跳动；tile可能有接缝 | 可研究常驻模型接入流式管线；本机实时速度未知，10秒比较后需持续播放验收 |
| BasicVSR++ | 双向多帧传播与光流引导可变形对齐 | 利用相邻帧，但不保证严重退化、快运动或切镜无伪影 | 后续研究路线，非M4即装即用承诺 |
| RealBasicVSR | 面向真实退化，在传播前清理噪声和伪影 | 清理与细节存在取舍；序列分段边界要验收 | 后续与逐帧基线比较，适合有独立GPU环境后评估 |
| Video2X 6 | FFmpeg管线，ncnn/Vulkan，超分或插帧，多个模型/shader | 框架不使单帧模型自动获得时间一致性 | 可用于Windows/Linux另机处理；不能作为M4现成方案 |
| NVIDIA RTX Video | RTX Tensor Core实时超分和SDR到HDR功能 | 输入、应用、GPU及驱动有适用限制；与DLSS不同 | 本机Apple GPU不适用；不纳入Mac V1 |

### Real-ESRGAN：本机候选，但需要验证发行包和模型

[官方仓库](https://github.com/xinntao/Real-ESRGAN)提供通用、动画、x2/x4模型及tile选项；Python `outscale`会在模型输出后再次用Lanczos缩放，因此任意倍率不全是模型倍率。训练采用合成退化，效果不能推定到所有片源。[论文](https://arxiv.org/abs/2107.10833)给出方法及退化建模依据。

截至调研，[ncnn Vulkan官方v0.2.0发行资产](https://github.com/xinntao/Real-ESRGAN-ncnn-vulkan/releases/expanded_assets/v0.2.0)可见 `realesrgan-ncnn-vulkan-v0.2.0-macos.zip`，资产时间为2022-04-24，大小8.14MB。[release工作流](https://github.com/xinntao/Real-ESRGAN-ncnn-vulkan/blob/master/.github/workflows/release.yml)分别构建x86_64、arm64再合成universal二进制，使用静态MoltenVK。MoltenVK把Vulkan的一部分映射到Apple Metal，见[Khronos官方说明](https://github.com/KhronosGroup/MoltenVK)。所以Mac路径是Vulkan经MoltenVK进入Metal，不是直接CUDA。

重要细节：该工作流复制models的步骤被注释，而旧主仓库README称portable包包含模型。没有下载资产检查内容，不能确认此v0.2.0包实际自带哪些权重；必须对最终选用包、模型格式、哈希和来源逐项核验。静态MoltenVK构建通常不需要用户另装整套Vulkan SDK，但这是从构建方式作出的推断，不是macOS27/M4运行证明。旧SDK、设备枚举、应用隔离属性和模型匹配都需要短片原型验证。

Python路线同样不能自动等于MPS支持：[上游设备选择代码](https://raw.githubusercontent.com/xinntao/Real-ESRGAN/master/realesrgan/utils.py)默认选择CUDA或CPU，可传device；需显式适配MPS及算子/精度。Apple确实提供[PyTorch Metal/MPS支持](https://developer.apple.com/metal/pytorch/)，但平台能力不能代替具体模型支持证据。

### BasicVSR++ / RealBasicVSR：时间信息更充分，部署成本更高

[BasicVSR++论文](https://arxiv.org/abs/2104.13371)使用二阶传播及光流引导可变形对齐。[官方代码](https://github.com/ckkelvinchan/BasicVSR_PlusPlus)基于MMEditing、mmcv-full，提供超分、压缩增强等checkpoint入口；[backbone源码](https://raw.githubusercontent.com/ckkelvinchan/BasicVSR_PlusPlus/master/mmedit/models/backbones/sr_backbones/basicvsr_pp.py)包含CUDA缓存路径。不能把更改device一行视为完整Metal移植。

[RealBasicVSR论文](https://arxiv.org/abs/2111.12704)说明严重退化会被长程传播放大，并通过传播前清理降低噪声和伪影。[仓库](https://github.com/ckkelvinchan/RealBasicVSR)给出x4权重的Dropbox、Drive、OneDrive入口、`max-seq-len`分段参数和旧PyTorch/CUDA安装例子。旧依赖要另行固定兼容组合。两者都需验收切镜、遮挡、快速运动及分段接续；多帧方法不是零闪烁保证。模型文件可离线运行，但本次未访问下载链接、未获取权重。

### Video2X：不要误读macOS容器描述

[官方README](https://github.com/k4yt3x/video2x)列出的原生平台是Windows/Linux，处理使用ncnn和Vulkan；预编译CPU要求AVX2，不适用于Apple ARM直接运行。当前[latest release](https://github.com/k4yt3x/video2x/releases/latest)指向6.4.0。

README另称容器可在Linux/macOS部署，但[容器文档](https://docs.video2x.org/running/container.html)要求Vulkan GPU，示例是AMD、NVIDIA、Intel设备透传，没有给出Apple GPU/Metal加速路径。不能据此承诺Docker Desktop在M4上有可用GPU超分。V1采用Mac原生独立处理器评估更稳妥；Video2X保留给用户未来明确指定的Windows/Linux GPU机器，不上传云端、不自动连接已有远程主机。

### mpv与NVIDIA

[mpv官方手册](https://mpv.io/manual/stable/)说明GLSL hooks可进入渲染管线；`macvk`是通过Metal surface转译的实验后端。需要确认播放器实际嵌入方式与打包mpv支持的后端。动漫专用Anime4K为MIT，作者明确其主要针对原生1080p动漫，低清老片和严重退化不是其优化目标；不要作为真人影视通用修复开关。

[NVIDIA官方RTX Video FAQ](https://nvidia.custhelp.com/app/answers/detail/a_id/5448)当前列出Windows10/11 64-bit和RTX GPU，支持Chrome/Edge/Firefox及相应VLC版本；SDR到HDR需要HDR10显示器，部分DRM视频不可用。FAQ还记载2025更新支持HDR视频超分。页面存在“原分辨率去伪影”和“仅上采样启用”的描述差异，应以具体驱动实际状态指标验证。SDK入口本次重定向至AI for Media，未拿到完整现行SDK平台矩阵/EULA，不能据此宣称Linux SDK或macOS支持。Video Codec SDK支持Linux不等于RTX Video应用功能支持Linux。Mac M4没有RTX Tensor Core，故不适用该路线。

## 许可证和权重来源

| 组件 | 公开许可证 | 集成边界 |
|---|---|---|
| [Real-ESRGAN](https://github.com/xinntao/Real-ESRGAN/blob/master/LICENSE) | BSD-3-Clause | 保留版权/许可证；具体权重发行资产另记录来源 |
| [Real-ESRGAN-ncnn-vulkan](https://github.com/xinntao/Real-ESRGAN-ncnn-vulkan/blob/master/LICENSE) | MIT（上游Video2X NOTICE/依赖表同样列明） | wrapper许可证不能替代模型及其他依赖条件 |
| [BasicVSR++](https://github.com/ckkelvinchan/BasicVSR_PlusPlus/blob/master/LICENSE)、[RealBasicVSR](https://github.com/ckkelvinchan/RealBasicVSR/blob/master/LICENSE) | Apache-2.0 | 保留NOTICE及许可证；权重、数据集下载许可仍分别检查 |
| [Video2X](https://github.com/k4yt3x/video2x/blob/master/LICENSE) | AGPLv3 | 自用工具可作为独立处理候选；未来分发或网络服务需按实际组合复核义务 |
| [FFmpeg](https://ffmpeg.org/legal.html) | LGPL2.1+；启用GPL组件则整体GPL | 查看实际构建配置；不得笼统称所有FFmpeg均LGPL |
| [mpv](https://github.com/mpv-player/mpv/blob/master/Copyright) | 默认GPLv2+，部分配置可LGPLv2.1+ | 以最终构建及依赖组合为准 |
| [Anime4K](https://github.com/bloc97/Anime4K/blob/master/LICENSE) | MIT | 单独保留shader来源及许可 |
| NVIDIA RTX Video | 专有SDK/驱动条款 | 权重不等同可自由提取分发的开源checkpoint；本次未获取现行SDK EULA |

这是一份技术许可清单，不是对发行合规的法律结论。实施时应保存具体版本、下载URL、模型名、SHA256、license/notice及参数；代码许可证不能自动证明外部权重或影片资源的许可。

## 离线导出的音轨、字幕、帧时间与HDR保持（背景）

若未来另做增强副本导出，建议流程为探测原文件 → 分离视频处理 → 重新编码增强视频 → 将原音轨、软字幕、章节及字体附件重封装 → 对照原文件验收。MKV通常适合作为保留多流的增强副本容器，但仍需逐格式验证。此流程不作为当前边看边增强的前置步骤；流式播放应直接维持原时间轴与独立字幕绘制。

[FFmpeg流选择文档](https://ffmpeg.org/ffmpeg.html#Stream-selection)明确自动模式通常只选择每类一个流，附件与data不自动选择；须显式map并对可保留的音轨/字幕使用stream copy。[metadata/chapter文档](https://ffmpeg.org/ffmpeg.html#Advanced-options)提供映射方式。元数据复制不等于帧side data、HDR动态元数据或所有编码内嵌信息自动完整保留。

工程验收建议：

- 所有音轨数量、语言、声道、默认标志、起始时间保持；stream copy路径可比对解复用后音频包哈希。确认片头、中段、片尾无音画漂移。
- 软字幕保持独立渲染，防止AI扭曲字形；ASS字体附件、样式、时轴和默认/forced标志保留。烧录字幕已属于画面，要纳入模型伪影检查。
- CFR保留有理帧率与帧数；VFR必须保留逐帧PTS，不能从图片序列按平均fps拼回后宣称时间保持。切10秒不能假设全部关键帧刚好对齐。
- 旋转、SAR/DAR、裁剪、章节、多个视频流均需显式策略；编码兼容失败时不能静默丢流。
- AI样片优先普通SDR。HDR10/HLG/杜比视界先走原片播放/高清版本路线。若后续处理HDR，需要明确线性光/模型输入域、位深、色域、PQ/HLG转换和重编码方案；16-bit图片支持不能证明HDR端到端支持。
- [FFmpeg zscale与tonemap](https://ffmpeg.org/ffmpeg-filters.html#zscale)支持缩放和色彩转换，tonemap要求线性浮点域。SDR到HDR是另一个视觉变换，不能自动称为保留原HDR；Dolby Vision/HDR10+动态元数据重编码支持必须单独验证。

## 原离线10秒比较方法（背景，尚未执行；不证明实时能力）

先选可用于测试的5类各10秒片段：真人近景/头发文字、快速运动、暗部噪声、平移细纹、动漫；另含切镜与烧录字幕。SDR测试先覆盖480p、720p、1080p不同输入，不能只用单张截图判电影效果。每个片段固定模型版本、倍率、tile、精度、输出编码器和码率/质量参数。用户没有现成影片，不能把提供本地样本作为软件自动找源的前置条件；开放技术样本不替代三剧内容验收。

比较四条路径：原片正常缩放、FFmpeg/Lanczos基线、mpv温和播放增强、Real-ESRGAN离线结果。1080p优先试x2到UHD，720p x4可能先得到更大画面再缩回UHD，必须把这类额外计算记入耗时。模型与输入选择最终以视觉结果为准。BasicVSR/RealBasicVSR另设后续对比，不把科研benchmark成绩换算为本机fps。

记录：启动/模型加载时间、解码/推理/编码/总wall time、有效处理fps、峰值统一内存及swap、CPU/GPU占用、最高临时空间、最终大小、失败日志。先预热一遍，再至少重复3次；使用最大/中位耗时区间，检查后台负载。10秒结果可以粗估全片，但只能标“估算”，长片温控、切镜、不同码率和I/O会改变速度。不提供未实测的“M4每秒几帧”或“2小时电影几分钟完成”。

验收以正常播放A/B为主，100%局部放大为辅：不新增明显闪烁、tile接缝、光晕、蜡感人脸、文字变形、纹理爬动或运动拖影；颜色/黑位不偏移，音画同步及字幕保持；至少在目标观看距离觉得更好才保存为推荐版本。有可信高分辨率参考时再计算PSNR/SSIM或VMAF，并说明对齐/编码条件；没有参考不能用无参考“清晰度分数”证明恢复真实细节。输出尺寸通过只代表尺寸达标。

内存与磁盘控制建议：单任务串行、流式/小批次处理，tile降低峰值内存；磁盘预算包括可恢复工作缓存。16GB是系统/图形共用，不等于独享16GB显存。10秒全帧PNG临时文件规模不能线性扩大到全片不检查；任务需有取消、异常退出、空间不足与保留原片策略。

## 推荐V1与后续边界

V1最新方向：保留原片；显示源分辨率、编码/HDR和增强模式；优先匹配高清同版本资源；实际支持边看边增强和播放中的A/B切换。Apple低延迟API、轻量GPU效果与常驻模型须比较实际可用范围，ncnn只是候选之一；10秒画质筛选后还需至少30分钟持续播放验证。首版增强以SDR和实测通过的组合为范围，HDR原片播放可用性单独验证。离线导出可作为后续扩展，不能替代流式要求。最新本机限制与性能门槛见[流式增强研究](streaming-enhancement-notes.md)。

后续：多帧RealBasicVSR、GPU另机离线处理、HDR端到端超分、更多字幕/附件组合。只有用户明确指定另一台机器及访问方式后才做该环境核验；自用本地文件不走云端上传。RTX Video为未来Windows RTX播放器可选功能。插帧属于单独偏好，不与4K超分默认捆绑。

最终可承诺的是“寻找可用高清版本，并对可处理的片源提供可比较、可退回的增强结果”，不能承诺“所有影片变成真实4K”。
