# 压缩抑噪：真实生产管线影片对照（2026-09-29）

结论：**新增 `.compression` 在这段影片上没有一致的空间质量收益。** 压缩和轻噪版本 RGB PSNR 小幅下降，重噪版本几乎持平；三组时间导数误差均小幅下降。数据适合说明可选模式的取舍，不支持“修复更清晰”或默认替换原流式修复。

| 输入退化 | 流式修复 PSNR dB | 压缩抑噪 PSNR dB | 差值 dB | 流式修复时序 RMSE | 压缩抑噪时序 RMSE |
|---|---:|---:|---:|---:|---:|
| compressed-film | 31.838950 | 31.824724 | -0.014226 | 2.613801 | 2.610488 |
| noisy-film | 32.716145 | 32.692215 | -0.023930 | 2.392411 | 2.389078 |
| heavy-noisy-film | 34.216818 | 34.217526 | +0.000708 | 2.334830 | 2.303805 |

PSNR 越高越好；时序 RMSE 越低越好，单位为8-bit等价码值。逐帧 PSNR 增加的帧数依次为31/96、37/96、37/96，没有筛掉负收益帧。全部模式每份输入均使用历史94/96帧，均在第0帧建立参考、第59帧切镜重置，历史计数一致。

## 试验边界

- 同一段 Tears of Steel 4秒影片的压缩、轻噪、重噪版本，均96帧、24fps，不是3部独立影片。原素材署名 `(CC) Blender Foundation | mango.blender.org`，CC BY 3.0。输入哈希及实际产品源文件哈希记录于JSON。
- 直接 AVAssetReader 解码 BGRA CVPixelBuffer；已知SDR本地夹具统一显式赋予BT.709原色、sRGB传输和sRGB颜色空间标签，clean和两种退化模式完全一致。此为测试的明确解释契约，不宣称原文件已有这些标签；绝对分数不要跨不同色彩解释的旧报告比较。
- 两个独立 `EnhancementPipeline`，同一个未重建的原始CV帧、同PTS、同stream ID，顺序处理全部96帧。每帧交替模式先后顺序，但每个会话只处理自身连续历史。没有把参考帧送入修复器，也没有提前解码下一退化帧。
- `.restoration` 对 `.compression`，分辨率都为 `.source`，480×200，不触发AI/最终放大。默认字幕保护设置与产品一致；未根据clean参考创建区域。
- 参考clean经CI Lanczos一次降至480×200，再用**相同RGB10A2输出格式**物化。两个候选均为实际产品RGB10A2输出；三路统一经 `CIImage(sRGB) → RGBAf(sRGB)`读回，不单独夹紧候选、不把一条支路先压成RGBA8。评分前没有额外8-bit量化。
- RGB空间误差覆盖全部像素、排除alpha。时序误差覆盖95对相邻帧，计算 `(候选[t]−候选[t−1])−(参考[t]−参考[t−1])`，不会将真实运动当噪声。
- 输出中记录生产完成耗时和加公共读回的墙钟耗时，仅作成本线索；这不是独立性能基准、实际AVPlayer播放、音画同步或持续实时证明。未运行720p或4K扩展。

本对照包含清理器的实际颜色/half存储往返成本，因此回答的是新增生产模式的整体效果。**没有执行storage-only identity清理对照，不能把上述负收益断言为算法本身或存储往返造成。** 本轮不据此继续扫参数，也不强行设定“候选必须胜出”的验收条件。

## 复现与产物

```sh
END_TO_END_FILM_COMPILE_ONLY=1 bash scripts/validate-end-to-end-film.sh
.build/repair-v036/end-to-end-film/check \
  docs/validation/v0.3.6/end-to-end-film.json .build/restoration-lab source
```

独立 `swiftc` 编译，不共享SwiftPM状态。编译器与实际运行退出0；JSON读回确认3组×2模式×96帧、95个时序对、全部样本数及历史重置完整。`end-to-end-film.frames/` 包含第24帧clean、原流式修复、新压缩抑噪各3张；`end-to-end-film-frame024-contact.png` 是同尺寸并排预览，仅辅助查阅。
