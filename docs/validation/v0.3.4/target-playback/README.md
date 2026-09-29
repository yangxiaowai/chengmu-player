# 播放时钟与 60fps 目标验证（2026-09-29）

最终隔离确认仍未证明本机可持续播放 1080p60 或 720p60。真实中间帧已生成，处理超预算时会明确提示并回退到片源帧率。主播放时钟的反复回跳已在本机最小对照中定位；修正输出对象生命周期后，以下完整播放器测量窗口都没有再次出现主时钟跳转。

全部使用本地合成的 1280×720、24fps、明确 BT.709 标记 H.264 与静音 AAC 片段、原生 NSWindow/MTKView。无远程媒体链接、账户或个人片库。GPU command 完成次数与 CAMetalDrawable 呈现回调分开记录：新增回调统计后的各轮回调均为 0，不能把处理完成帧率等同实际屏幕帧率，也未验证可听音画同步。早期报告没有回调字段，不应按 0 解释。

| 顺序 | JSON（同名对应 log） | 代码阶段与观测 |
| --- | --- | --- |
| 1 | `output-churn.json` | 仅 AVPlayer、原生 layer 和 output；不读帧、不运行增强，每 0.5 秒增删 output。9 次增删伴随 18 次 TimeJump，5 秒主时钟仅净推进 0.085 秒。证明本机反复增删 output 会扰动播放；不据此宣称未来时间读帧 API 普遍有错。 |
| 2 | `report-stable-output.json` | 单个 SDR item 复用一个稳定 output，暂停、原片切换及插帧进出不再反复增删。5 秒主时钟推进 5.00092 秒、测量期 0 TimeJump；该阶段预热仍失败，最终约 24 次完成/秒。 |
| 3 | `report-display-queue.json` | 加入独立显示 queue/context、回退 PTS 防倒退。13/15；5 秒完成 126 帧（25.20fps），真实插帧后因处理预算回退。测量初段 FRC batch 51.7–62.7ms，片源 24fps 的预算为 41.7ms。 |
| 4 | `report-720p.json` | 显式 720p60 首轮。12/15；生成 28 个中间帧后因未来帧未及时就绪回退，未维持预热门槛；测量约 23.99 次完成/秒。 |
| 5 | `report-1080p-fresh-motion-unplanned.json` | 新增真实插帧标记并仅由仍有效的插值帧解锁呈现之后，原计划测 720p，却遗漏环境参数，实际为默认 1080p。15/15、约 60.18 次完成/秒，但与另一个 helper 编译/执行交接时段未严格排除重叠。只留作诊断，不用于性能结论；报告内 `requestedTarget` 为 1080p，文件已据此更名。 |
| 6 | `report-720p-fresh-motion.json` | 正确显式 720p、独占窗口重测。12/15；生成 32 个中间帧后此次触发处理预算回退，约 23.99 次完成/秒。不能把此轮与前一轮 starvation 当成同一失败层。 |
| 7 | `report-1080p-final.json` | 最新代码显式 1080p、独占窗口最终确认。13/15；123 次完成/5.0034 秒（24.58fps），累计生成 38 个中间帧后预算回退。主时钟推进 5.0035 秒、0 TimeJump、PTS 单调；尺寸、暂停同帧对照、暂停 seek、原片切换保持位置及 4K60 明确回退均通过。意外通过轮没有稳定复现。 |

各轮均保留原始 JSON/log，未改写失败。最终两项 1080p 失败为“5 秒至少 250 次唯一 PTS 完成”和“全为 60Hz 时间格点”；720p 还未通过 25 秒内稳定预热。门槛未下调。早期稳定 output 报告的“PTS 单调”断言同时含样本数大于 200 的条件；后续已把数量门槛与单调性分开，评估旧报告时需读原始 PTS，不能将单项失败直接当作时间倒退。

复现入口是仓库中的 `scripts/validate-target-playback.sh`，每次在临时目录 fresh 编译并生成夹具，不使用 SwiftPM 共用产物或个人设置：

```sh
# 默认仍为 1080p；两档使用相同的帧率、预热及时间单调性门槛。
TARGET_PLAYBACK_RESOLUTION=1080 bash scripts/validate-target-playback.sh .build/target-playback/recheck-1080.json
TARGET_PLAYBACK_RESOLUTION=720 bash scripts/validate-target-playback.sh .build/target-playback/recheck-720.json
TARGET_PLAYBACK_CHURN_DIAGNOSTIC=1 bash scripts/validate-target-playback.sh .build/target-playback/recheck-output-churn.json
```

这些短测试不保证其他片源、长时间运行或其他 Mac 的性能。`archive-manifest.json` 记录逐文件 SHA-256、字节数及 URL/个人路径/常见凭证字段扫描结果；原始报告没有网络媒体资源。
