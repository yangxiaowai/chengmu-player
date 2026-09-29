import SwiftUI
import CinemaCore

/// Shared by the studio and the player's popover. Requested settings and actual output stay separate.
struct QualityControlPanel: View {
    @ObservedObject var playback: PlaybackController
    @ObservedObject var performance: QualityPerformanceController
    var compact = false
    /// Hardware support enables the experimental target; it does not prove sustained playback.
    var allows60FPS = false

    var body: some View {
        VStack(alignment: .leading, spacing: compact ? 16 : 22) {
            sourceSection
            settingsSection
            comparisonSection
            performanceSection
        }
        .foregroundStyle(CinemaStyle.primary)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var sourceSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .top, spacing: 12) {
                Image(systemName: "film.stack").font(.system(size: compact ? 20 : 27, weight: .light))
                    .foregroundStyle(CinemaStyle.accent).frame(width: compact ? 26 : 36)
                VStack(alignment: .leading, spacing: 6) {
                    eyebrow("当前片源")
                    Text(playback.sourceFormatLabel)
                        .font(.system(size: compact ? 13 : 17, weight: .medium, design: .monospaced))
                        .fixedSize(horizontal: false, vertical: true).textSelection(.enabled)
                }
                Spacer(minLength: 0)
            }
            Rectangle().fill(CinemaStyle.border).frame(height: 1)
            HStack(alignment: .top, spacing: 10) {
                Image(systemName: playback.pictureIsEnhanced ? "sparkles" : "play.rectangle")
                    .foregroundStyle(CinemaStyle.accent).frame(width: 18)
                VStack(alignment: .leading, spacing: 5) {
                    Text(playback.pictureStatusTitle).font(.system(size: 12, weight: .semibold))
                    if let metrics = playback.metrics, metrics.outputWidth > 0, metrics.outputHeight > 0 {
                        Text("实际输出 \(metrics.outputWidth)×\(metrics.outputHeight)")
                            .font(.system(size: 11, design: .monospaced)).foregroundStyle(CinemaStyle.secondary)
                    }
                    Text(playback.outputTimingLabel).font(.system(size: 11)).foregroundStyle(CinemaStyle.secondary)
                    if case .nativeOnly(let reason) = playback.videoPermission {
                        Text(reason).font(.system(size: 11)).foregroundStyle(CinemaStyle.accent)
                    } else if let reason = playback.metrics?.fallbackReason {
                        Text(reason).font(.system(size: 11)).foregroundStyle(CinemaStyle.accent)
                    }
                }.fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(compact ? 14 : 20)
        .background(CinemaStyle.backgroundRaised, in: RoundedRectangle(cornerRadius: CinemaStyle.radius))
        .overlay(RoundedRectangle(cornerRadius: CinemaStyle.radius).strokeBorder(CinemaStyle.borderStrong, lineWidth: 1))
    }

    private var settingsSection: some View {
        VStack(alignment: .leading, spacing: 14) {
            eyebrow("画面与流畅度")
            settingRow("处理模式") {
                Picker("处理模式", selection: Binding(get: { playback.selectedPictureMode }, set: { playback.selectEnhancementMode($0) })) {
                    ForEach(EnhancementMode.allCases) { mode in Text(mode.title).tag(mode) }
                }.labelsHidden().pickerStyle(.menu)
            }
            Text(playback.selectedPictureMode.detail)
                .font(.system(size: 11)).foregroundStyle(CinemaStyle.secondary)
                .fixedSize(horizontal: false, vertical: true)
            settingRow("目标分辨率") {
                Picker("目标分辨率", selection: $playback.targetResolution) {
                    ForEach(EnhancementResolution.allCases) { resolution in Text(resolution.title).tag(resolution) }
                }.labelsHidden().pickerStyle(.menu)
                    .disabled(playback.selectedPictureMode == .original)
            }
            settingRow("目标帧率") {
                Picker("目标帧率", selection: $playback.targetFrameRate) {
                    Text(EnhancementFrameRate.source.title).tag(EnhancementFrameRate.source)
                    Text("60 fps目标（实验，可能回退）").tag(EnhancementFrameRate.fps60).disabled(!allows60FPS)
                }.labelsHidden().pickerStyle(.menu)
                    .disabled(playback.selectedPictureMode == .original)
            }
            if playback.targetFrameRate == .fps60 && selectedOutputExceeds1080p {
                CinemaNotice(icon: "exclamationmark.circle", text: "当前目标超过 1080p，不支持 60 fps 插帧；4K60 不会启用。可尝试下方 1080p60，或跟随片源帧率。")
            }
            Button {
                playback.targetResolution = .fullHD
                playback.targetFrameRate = .fps60
                playback.selectEnhancementMode(.clarity)
            } label: {
                HStack(spacing: 8) {
                    Image(systemName: "hare")
                    Text("尝试1080p60（自然降噪）")
                    Spacer(minLength: 0)
                    Text("实验").font(.system(size: 10, weight: .medium)).foregroundStyle(CinemaStyle.accent)
                }.font(.system(size: 11, weight: .medium)).padding(.vertical, 4)
            }.buttonStyle(.bordered).disabled(!allows60FPS)
            Text(allows60FPS
                 ? "60 fps 是实验目标，可能回退。本机自检不等于稳定播放；性能不足时保留修复、跟随片源帧率。当前仅支持 1080p 以内，实际状态见上方。"
                 : "当前系统或设备不支持运动插帧，需要 macOS 26 或更新版本及兼容硬件。分辨率保持画面比例，帧率跟随片源。")
                .font(.system(size: 11)).foregroundStyle(CinemaStyle.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }.disabled(performance.isRunning)
    }

    private var comparisonSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                eyebrow("原片与修复")
                Spacer()
                if playback.isComparingOriginal {
                    Text("正在看原片").font(.system(size: 10, weight: .semibold)).foregroundStyle(CinemaStyle.accent)
                }
            }
            HStack(spacing: 10) {
                Button { playback.toggleOriginalComparison() } label: {
                    Label(playback.isComparingOriginal ? "返回修复画面" : "临时查看原片", systemImage: "circle.lefthalf.filled")
                        .font(.system(size: 12))
                }.buttonStyle(.bordered)
                    .disabled(!playback.canCompareOriginal && !playback.isComparingOriginal)
                Spacer(minLength: 0)
                Toggle("同帧分屏", isOn: $playback.isSplitComparison).toggleStyle(.switch)
                    .font(.system(size: 12)).fixedSize()
                    .disabled(!playback.pictureIsEnhanced && !playback.isSplitComparison)
            }
            Text(playback.isSplitComparison ? "同一时刻的原片与处理画面并排呈现，适合检查纹理、噪点与字幕。" : "对照不会改变所选模式。增强画面就绪后，可以开启同帧分屏。")
                .font(.system(size: 11)).foregroundStyle(CinemaStyle.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(.vertical, 14)
        .overlay(alignment: .top) { Rectangle().fill(CinemaStyle.border).frame(height: 1) }
        .overlay(alignment: .bottom) { Rectangle().fill(CinemaStyle.border).frame(height: 1) }
        .disabled(performance.isRunning)
    }

    private var performanceSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 10) {
                VStack(alignment: .leading, spacing: 5) {
                    eyebrow("本机处理能力")
                    Text(performance.isRunning ? performance.status : (playback.selectedPictureMode == .original ? "原片模式下，以流式修复检测所选目标" : "用固定样本检验当前设置"))
                        .font(.system(size: 11)).foregroundStyle(CinemaStyle.secondary)
                }
                Spacer(minLength: 0)
                if performance.isRunning {
                    Button(performance.isCancelling ? "停止中…" : "取消") { playback.cancelPerformanceTest() }
                        .disabled(performance.isCancelling).buttonStyle(.bordered)
                } else {
                    Button { playback.startPerformanceTest() } label: {
                        Label(performance.report == nil ? "开始自检" : "重新检测", systemImage: "speedometer")
                    }.buttonStyle(.borderedProminent).tint(CinemaStyle.accent)
                        .help("检测时暂时暂停播放，使用固定运动与噪声样本；结束后按播放意图恢复。")
                }
            }
            if performance.isRunning {
                ProgressView(value: performance.progress).tint(CinemaStyle.accent)
                    .accessibilityLabel("本机画质检测进度")
            }
            if let error = performance.error {
                CinemaNotice(icon: "exclamationmark.circle", text: error)
            }
            if let report = performance.report { performanceResult(report) }
            else if !performance.isRunning && performance.error == nil {
                Text(performance.status == "检测已取消" ? "检测已取消，没有生成性能结论。" : "尚无检测结果。检测使用合成 SDR 图像，不读取电影文件；未识别片源尺寸时使用 1280×720。")
                    .font(.system(size: 11)).foregroundStyle(CinemaStyle.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Text("本机自检不等于稳定播放。自检统计完整处理耗时，不代表显示帧率或音画同步；性能不足时保留修复、跟随片源帧率。HDR 与杜比视界继续由系统原生呈现。")
                .font(.system(size: 10)).foregroundStyle(CinemaStyle.tertiary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private func performanceResult(_ report: QualityPerformanceReport) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 8) {
                Image(systemName: report.spatialFitsBudget ? "checkmark.circle" : "info.circle")
                Text(report.verdict).font(.system(size: 12, weight: .medium))
            }.foregroundStyle(report.spatialFitsBudget ? CinemaStyle.positive : CinemaStyle.accent)
            HStack(alignment: .firstTextBaseline, spacing: compact ? 16 : 28) {
                performanceValue("P95 完成耗时", value: String(format: "%.1f", report.p95MS), unit: "ms", primary: true)
                performanceValue("每源帧预算", value: String(format: "%.1f", report.frameBudgetMS), unit: "ms")
                performanceValue("P95 余量", value: String(format: "%+.1f", report.headroomMS), unit: "ms")
            }
            VStack(alignment: .leading, spacing: 5) {
                Text(report.configurationLabel).font(.system(size: 11, weight: .medium))
                Text(report.sourceLabel + " → \(report.outputSize.width)×\(report.outputSize.height)")
                Text("平均 \(String(format: "%.1f", report.meanMS)) ms · 超预算 \(report.overBudgetFrames)/\(report.completedFrames) 个源帧间隔")
                Text("预热 \(report.warmupFrames) 帧 · 首帧处理 \(String(format: "%.1f", report.firstFrameMS)) ms")
                if report.includesFrameInterpolation {
                    Text("采样 \(String(format: "%.2f", report.sampledMediaSeconds)) 秒媒体时间，输出 \(report.completedOutputFrames) 个 60 Hz 格点，其中 \(report.interpolatedFrames) 帧为运动插帧。")
                }
                Text(report.frameRateNote)
                Text(report.algorithm)
                Text(report.deviceName + " · " + report.testedAt.formatted(date: .abbreviated, time: .shortened))
            }.font(.system(size: 10)).foregroundStyle(CinemaStyle.secondary)
                .fixedSize(horizontal: false, vertical: true)
            if report.mode != (playback.selectedPictureMode == .original ? .restoration : playback.selectedPictureMode) || report.resolution != playback.targetResolution || report.requestedFrameRate != playback.targetFrameRate {
                Text("上次结果对应上方所列配置；当前选项已改变，请重新检测。")
                    .font(.system(size: 10)).foregroundStyle(CinemaStyle.accent)
            }
        }
        .padding(14)
        .background(CinemaStyle.backgroundRaised, in: RoundedRectangle(cornerRadius: CinemaStyle.radius))
        .overlay(RoundedRectangle(cornerRadius: CinemaStyle.radius).strokeBorder(CinemaStyle.border, lineWidth: 1))
    }

    private func performanceValue(_ title: String, value: String, unit: String, primary: Bool = false) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            Text(title).font(.system(size: 10)).foregroundStyle(CinemaStyle.secondary)
            HStack(alignment: .firstTextBaseline, spacing: 3) {
                Text(value).font(.system(size: primary ? (compact ? 24 : 30) : (compact ? 18 : 23), weight: .medium, design: .rounded)).monospacedDigit()
                Text(unit).font(.system(size: 10)).foregroundStyle(CinemaStyle.tertiary)
            }
        }.frame(maxWidth: .infinity, alignment: .leading)
    }

    private var selectedOutputExceeds1080p: Bool {
        let width = playback.metrics?.sourceWidth ?? 1280, height = playback.metrics?.sourceHeight ?? 720
        let size = playback.targetResolution.target(width: max(1, width), height: max(1, height),
                                                    automatic4K: playback.selectedPictureMode.automaticallyTargets4K)
        return max(size.width, size.height) > 1920 || size.width * size.height > 1920 * 1080
    }
    private func eyebrow(_ text: String) -> some View {
        Text(text).font(.system(size: 11, weight: .semibold)).tracking(0.8).foregroundStyle(CinemaStyle.secondary)
    }
    private func settingRow<Content: View>(_ title: String, @ViewBuilder content: () -> Content) -> some View {
        HStack(spacing: 16) {
            Text(title).font(.system(size: 12)).frame(width: compact ? 82 : 112, alignment: .leading)
            content().frame(maxWidth: .infinity, alignment: .trailing)
        }
    }
}
