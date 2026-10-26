import SwiftUI
import CinemaCore

/// Consumer controls shared by the settings page and the player popover.
struct QualityControlPanel: View {
    @ObservedObject var playback: PlaybackController
    @ObservedObject var performance: QualityPerformanceController
    var compact = false
    var allows60FPS = false

    var body: some View {
        VStack(alignment: .leading, spacing: compact ? 18 : 24) {
            sourceSection
            settingsSection
            comparisonSection
            performanceSection
        }.foregroundStyle(CinemaStyle.primary).frame(maxWidth: .infinity, alignment: .leading)
    }

    private var sourceSection: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack(alignment: .center, spacing: 14) {
                Image(systemName: "play.rectangle").font(.system(size: 25, weight: .light))
                    .foregroundStyle(CinemaStyle.accent).frame(width: 42, height: 42)
                    .background(CinemaStyle.accentSoft, in: RoundedRectangle(cornerRadius: 10))
                VStack(alignment: .leading, spacing: 5) {
                    Text("当前影片").font(.system(size: 11)).foregroundStyle(CinemaStyle.secondary)
                    Text(playback.title.isEmpty ? "还没有打开影片" : playback.title).font(.system(size: 15, weight: .semibold)).lineLimit(1)
                }
                Spacer(minLength: 0)
                Text(playback.title.isEmpty ? "未播放" : (playback.pictureIsEnhanced ? "增强中" : "原片播放"))
                    .font(.system(size: 10, weight: .medium)).foregroundStyle(playback.pictureIsEnhanced ? CinemaStyle.accent : CinemaStyle.secondary)
                    .padding(.horizontal, 10).padding(.vertical, 6).background(CinemaStyle.panel, in: Capsule())
            }
            Text(playback.sourceFormatLabel.replacingOccurrences(of: "（轨道）", with: "").replacingOccurrences(of: " fps", with: " 帧/秒")).font(.system(size: 12)).foregroundStyle(CinemaStyle.secondary)
                .fixedSize(horizontal: false, vertical: true)
            if case .nativeOnly(let reason) = playback.videoPermission {
                CinemaNotice(icon: "info.circle", text: reason)
            } else if let reason = playback.metrics?.fallbackReason {
                CinemaNotice(icon: "info.circle", text: reason)
            }
            DisclosureGroup {
                VStack(alignment: .leading, spacing: 5) {
                    Text(playback.pictureStatusTitle)
                    if let metrics = playback.metrics, metrics.outputWidth > 0, metrics.outputHeight > 0 {
                        Text("输出画面 \(metrics.outputWidth)×\(metrics.outputHeight)")
                    }
                    Text(playback.outputTimingLabel)
                }.font(.system(size: 11)).foregroundStyle(CinemaStyle.secondary).padding(.top, 6)
            } label: { Text("画面详情").font(.system(size: 11)).foregroundStyle(CinemaStyle.tertiary) }
        }.padding(compact ? 16 : 22).background(CinemaStyle.backgroundRaised, in: RoundedRectangle(cornerRadius: 12))
    }

    private var settingsSection: some View {
        VStack(alignment: .leading, spacing: 18) {
            sectionHeading("画面风格", subtitle: "从自然清晰，到更细致的修复")
            LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 8), count: compact ? 2 : 4), spacing: 8) {
                ForEach(EnhancementMode.allCases) { mode in
                    Button { playback.selectEnhancementMode(mode) } label: {
                        VStack(alignment: .leading, spacing: 8) {
                            HStack {
                                Image(systemName: modeIcon(mode)).font(.system(size: 16, weight: .medium))
                                Spacer(minLength: 0)
                                if playback.selectedPictureMode == mode { Image(systemName: "checkmark.circle.fill").font(.system(size: 12)) }
                            }
                            Text(modeName(mode)).font(.system(size: 12, weight: .semibold))
                            Text(modeSubtitle(mode)).font(.system(size: 10)).foregroundStyle(CinemaStyle.secondary).lineLimit(1)
                        }.foregroundStyle(playback.selectedPictureMode == mode ? CinemaStyle.accent : CinemaStyle.primary)
                            .padding(13).frame(maxWidth: .infinity, minHeight: 86, alignment: .leading)
                            .background(playback.selectedPictureMode == mode ? CinemaStyle.accentSoft : CinemaStyle.backgroundRaised, in: RoundedRectangle(cornerRadius: 10))
                            .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(playback.selectedPictureMode == mode ? CinemaStyle.accent.opacity(0.6) : CinemaStyle.border, lineWidth: 1))
                            .contentShape(Rectangle())
                    }.buttonStyle(.plain).help(mode.detail)
                        .accessibilityAddTraits(playback.selectedPictureMode == mode ? .isSelected : [])
                }
            }
            Text(playback.selectedPictureMode.detail).font(.system(size: 11)).foregroundStyle(CinemaStyle.secondary).fixedSize(horizontal: false, vertical: true)
            VStack(alignment: .leading, spacing: 16) {
                settingRow("目标清晰度") {
                    Menu {
                        ForEach(EnhancementResolution.allCases) { resolution in
                            Button { playback.targetResolution = resolution } label: {
                                if playback.targetResolution == resolution { Label(resolution.title, systemImage: "checkmark") }
                                else { Text(resolution.title) }
                            }
                        }
                    } label: { menuLabel(playback.targetResolution.title) }.menuStyle(.borderlessButton).fixedSize()
                        .disabled(playback.selectedPictureMode == .original)
                }
                Rectangle().fill(CinemaStyle.border).frame(height: 1)
                settingRow("流畅度") {
                    HStack(spacing: 7) {
                        choice("原始帧率", selected: playback.targetFrameRate == .source) { playback.targetFrameRate = .source }
                        choice("60 帧", selected: playback.targetFrameRate == .fps60) { playback.targetFrameRate = .fps60 }.disabled(!allows60FPS)
                    }.disabled(playback.selectedPictureMode == .original)
                }
                if playback.targetFrameRate == .fps60 && selectedOutputExceeds1080p {
                    Text("60 帧增强支持 1080P 以内的画面，请降低目标清晰度。")
                        .font(.system(size: 11)).foregroundStyle(CinemaStyle.accent)
                }
                HStack(spacing: 8) {
                    Text("想要更流畅？").foregroundStyle(CinemaStyle.secondary)
                    Button("试试 1080P · 60 帧") {
                        playback.targetResolution = .fullHD; playback.targetFrameRate = .fps60; playback.selectEnhancementMode(.clarity)
                    }.buttonStyle(.plain).foregroundStyle(CinemaStyle.accent).disabled(!allows60FPS)
                    Spacer(minLength: 0)
                }.font(.system(size: 11))
                Text(allows60FPS ? "60 帧为实验功能，性能不足时会跟随原始帧率。提高分辨率不能还原原片中不存在的细节。" : "当前设备不支持运动插帧，帧率将跟随片源。更高清晰度会增加处理负担。")
                    .font(.system(size: 10)).foregroundStyle(CinemaStyle.tertiary).fixedSize(horizontal: false, vertical: true)
            }.padding(18).background(CinemaStyle.backgroundRaised, in: RoundedRectangle(cornerRadius: 12))
        }.disabled(performance.isRunning)
    }

    private var comparisonSection: some View {
        VStack(alignment: .leading, spacing: 16) {
            sectionHeading("看见区别", subtitle: "保留你喜欢的画面，不必只追求更高参数")
            HStack(spacing: 12) {
                Button { playback.toggleOriginalComparison() } label: {
                    Label(playback.isComparingOriginal ? "返回增强画面" : "对比原片", systemImage: "circle.lefthalf.filled")
                        .font(.system(size: 12, weight: .medium)).padding(.horizontal, 14).frame(height: 38)
                        .background(CinemaStyle.panel, in: RoundedRectangle(cornerRadius: 8))
                        .contentShape(Rectangle())
                }.buttonStyle(.plain).disabled(!playback.canCompareOriginal && !playback.isComparingOriginal)
                Spacer(minLength: 0)
                Toggle("分屏对比", isOn: $playback.isSplitComparison).toggleStyle(.switch).controlSize(.small).font(.system(size: 12))
                    .disabled(!playback.pictureIsEnhanced && !playback.isSplitComparison)
            }
        }.padding(18).background(CinemaStyle.backgroundRaised, in: RoundedRectangle(cornerRadius: 12)).disabled(performance.isRunning)
    }

    private var performanceSection: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack(spacing: 12) {
                VStack(alignment: .leading, spacing: 6) {
                    Text("这台 Mac，能跑多高？").font(.system(size: 15, weight: .semibold))
                    Text(performance.isRunning ? "正在评估当前设置…" : "用短时性能评估，帮助选择适合的画质")
                        .font(.system(size: 11)).foregroundStyle(CinemaStyle.secondary)
                }
                Spacer(minLength: 0)
                if performance.isRunning {
                    Button(performance.isCancelling ? "正在停止" : "停止") { playback.cancelPerformanceTest() }
                        .disabled(performance.isCancelling).buttonStyle(.bordered)
                } else {
                    Button { playback.startPerformanceTest() } label: {
                        Text(performance.report == nil ? "检测性能" : "再次检测").font(.system(size: 12, weight: .semibold)).padding(.horizontal, 14).frame(height: 38)
                            .foregroundStyle(.white).background(CinemaStyle.accent, in: RoundedRectangle(cornerRadius: 8))
                    }.buttonStyle(.plain).help("检测会暂时暂停播放，结束后恢复。使用内置测试画面，不修改影片。")
                }
            }
            if performance.isRunning { ProgressView(value: performance.progress).tint(CinemaStyle.accent).accessibilityLabel("性能检测进度") }
            if let error = performance.error { CinemaNotice(icon: "info.circle", text: error) }
            if let report = performance.report { performanceResult(report) }
            Text("短时检测仅供选项参考，实际流畅度会随影片与设备负载变化。HDR 与杜比视界由系统原生播放。")
                .font(.system(size: 10)).foregroundStyle(CinemaStyle.tertiary).fixedSize(horizontal: false, vertical: true)
        }.padding(18).background(CinemaStyle.backgroundRaised, in: RoundedRectangle(cornerRadius: 12))
    }

    private func performanceResult(_ report: QualityPerformanceReport) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            Label(report.spatialFitsBudget ? "当前设置在本次检测中有处理余量" : "建议降低清晰度或使用原始帧率", systemImage: report.spatialFitsBudget ? "checkmark.circle.fill" : "info.circle")
                .font(.system(size: 12, weight: .medium)).foregroundStyle(report.spatialFitsBudget ? CinemaStyle.positive : CinemaStyle.accent)
            Text(report.configurationLabel).font(.system(size: 11)).foregroundStyle(CinemaStyle.secondary)
            if report.mode != (playback.selectedPictureMode == .original ? .restoration : playback.selectedPictureMode) || report.resolution != playback.targetResolution || report.requestedFrameRate != playback.targetFrameRate {
                Text("设置已更改，重新检测可更新建议。").font(.system(size: 11)).foregroundStyle(CinemaStyle.accent)
            }
            DisclosureGroup {
                VStack(alignment: .leading, spacing: 5) {
                    Text(report.sourceLabel + " → \(report.outputSize.width)×\(report.outputSize.height)")
                    Text("95% 的帧在 \(String(format: "%.1f", report.p95MS)) ms 内完成处理；每源帧预算 \(String(format: "%.1f", report.frameBudgetMS)) ms")
                    Text("平均 \(String(format: "%.1f", report.meanMS)) ms · 超时 \(report.overBudgetFrames)/\(report.completedFrames) 帧")
                    Text(report.frameRateNote)
                    Text(report.algorithm)
                    Text(report.deviceName + " · " + report.testedAt.formatted(date: .abbreviated, time: .shortened))
                }.font(.system(size: 10)).foregroundStyle(CinemaStyle.secondary).fixedSize(horizontal: false, vertical: true).padding(.top, 6)
            } label: { Text("性能详情").font(.system(size: 11)).foregroundStyle(CinemaStyle.tertiary) }
        }
    }

    private func modeName(_ mode: EnhancementMode) -> String {
        switch mode {
        case .original: return "原片"
        case .clarity: return "自然清晰"
        case .temporal: return "柔和降噪"
        case .gentleRestoration: return "轻度修复"
        case .restoration: return "细致修复"
        case .compression: return "压缩改善"
        case .upscale4K: return "平滑放大"
        case .appleAI: return "AI 超分"
        }
    }
    private func modeSubtitle(_ mode: EnhancementMode) -> String {
        switch mode {
        case .original: return "忠于原始画面"
        case .clarity: return "减少噪点 · 自然质感"
        case .temporal: return "结合相邻画面降噪"
        case .gentleRestoration: return "保留更多细节"
        case .restoration: return "降噪与放大结合"
        case .compression: return "减轻残留噪点 · 实验"
        case .upscale4K: return "舒适观看大画面"
        case .appleAI: return "依设备能力启用"
        }
    }
    private func modeIcon(_ mode: EnhancementMode) -> String {
        switch mode {
        case .original: return "film"
        case .clarity: return "sun.max"
        case .temporal: return "square.stack.3d.up"
        case .gentleRestoration: return "leaf"
        case .restoration: return "sparkles"
        case .compression: return "slider.horizontal.3"
        case .upscale4K: return "arrow.up.left.and.arrow.down.right"
        case .appleAI: return "cpu"
        }
    }
    private var selectedOutputExceeds1080p: Bool {
        let width = playback.metrics?.sourceWidth ?? 1280, height = playback.metrics?.sourceHeight ?? 720
        let size = playback.targetResolution.target(width: max(1, width), height: max(1, height), automatic4K: playback.selectedPictureMode.automaticallyTargets4K)
        return max(size.width, size.height) > 1920 || size.width * size.height > 1920 * 1080
    }
    private func sectionHeading(_ title: String, subtitle: String) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title).font(.system(size: 15, weight: .semibold))
            Text(subtitle).font(.system(size: 11)).foregroundStyle(CinemaStyle.secondary)
        }
    }
    private func settingRow<Content: View>(_ title: String, @ViewBuilder content: () -> Content) -> some View {
        HStack(spacing: 12) { Text(title).font(.system(size: 12)).foregroundStyle(CinemaStyle.secondary); Spacer(minLength: 0); content() }
    }
    private func menuLabel(_ value: String) -> some View {
        HStack(spacing: 10) { Text(value); Image(systemName: "chevron.down").font(.system(size: 9)) }.font(.system(size: 12)).padding(.horizontal, 12).frame(height: 34).background(CinemaStyle.panel, in: RoundedRectangle(cornerRadius: 7))
    }
    private func choice(_ title: String, selected: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(title).font(.system(size: 11, weight: .medium)).foregroundStyle(selected ? CinemaStyle.accent : CinemaStyle.secondary)
                .padding(.horizontal, 11).frame(height: 32).background(selected ? CinemaStyle.accentSoft : CinemaStyle.panel, in: RoundedRectangle(cornerRadius: 7)).contentShape(Rectangle())
        }.buttonStyle(.plain).accessibilityAddTraits(selected ? .isSelected : [])
    }
}
