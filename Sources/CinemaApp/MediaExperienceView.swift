import SwiftUI
import CinemaCore

/// Layered explanation of what the source offers, what is selected, what this Mac can do and what
/// the player actually decided. Every layer says which evidence it came from, and unverifiable
/// parts are named instead of implied.
struct MediaExperienceView: View {
    @ObservedObject var experience: MediaExperienceInspector
    @ObservedObject var playback: PlaybackController
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            Divider().overlay(CinemaStyle.border)
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    controlSection
                    sourceSection
                    videoSection
                    audioSection
                    deviceSection
                    limitationSection
                }.padding(22)
            }
        }
        .frame(width: 560, height: 620)
        .background(CinemaStyle.background)
        .foregroundStyle(Color.white.opacity(0.93))
    }

    private var header: some View {
        HStack(alignment: .firstTextBaseline) {
            VStack(alignment: .leading, spacing: 4) {
                Text("视听适配").font(.system(size: 17, weight: .semibold))
                Text("按片源、所选轨道、系统能力和实际决策分层说明，不代表获得杜比认证")
                    .font(.system(size: 11)).foregroundStyle(CinemaStyle.secondary)
            }
            Spacer()
            Button("完成") { dismiss() }.keyboardShortcut(.defaultAction)
        }.padding(20)
    }

    private var controlSection: some View {
        CinemaCard(title: "画面与声音开关", icon: "switch.2") {
            Picker("画面模式", selection: Binding(get: { playback.selectedPictureMode }, set: { playback.selectEnhancementMode($0) })) {
                ForEach(EnhancementMode.allCases) { mode in Text(mode.title).tag(mode) }
            }
            .font(.system(size: 11)).pickerStyle(.menu)
            Text("选择原片后使用系统画面。增强只对适合处理的片源生效；下方显示实际输出，所选模式不会保证改变当前画面。")
                .font(.system(size: 10)).foregroundStyle(CinemaStyle.secondary)
            if playback.canCompareOriginal || playback.isComparingOriginal {
                Button(playback.isComparingOriginal ? "结束原片对照" : "临时查看原片") { playback.toggleOriginalComparison() }
                    .font(.system(size: 11))
            }
            Divider().overlay(CinemaStyle.border)
            HStack(alignment: .top, spacing: 8) {
                Image(systemName: "lock.fill").font(.system(size: 10)).foregroundStyle(CinemaStyle.tertiary).padding(.top, 1)
                VStack(alignment: .leading, spacing: 3) {
                    Text("杜比视界 / HDR：不做增强，固定原生直通").font(.system(size: 11, weight: .medium))
                    Text("HDR 增强已关闭。改写像素会让杜比视界的逐帧动态元数据失效，所以杜比与 HDR 片源一律交给系统原生呈现，实时增强只作用于 SDR 片源。")
                        .font(.system(size: 10)).foregroundStyle(CinemaStyle.secondary)
                }
            }
            Divider().overlay(CinemaStyle.border)
            Toggle("保持原声布局（不请求空间化）", isOn: Binding(get: { playback.keepsOriginalAudioLayout }, set: { playback.keepsOriginalAudioLayout = $0 }))
                .font(.system(size: 11)).toggleStyle(.switch)
        }
    }

    private var sourceSection: some View {
        CinemaCard(title: "片源声明", icon: "doc.text.magnifyingglass") {
            CinemaKeyValue("主清单版本", experience.status.declaredVariants > 0 ? "\(experience.status.declaredVariants) 个" : experience.status.declarationNote ?? "未知")
            CinemaKeyValue("杜比视界声明", experience.status.declaredDolbyVision ? "有" : "未声明", accent: experience.status.declaredDolbyVision)
            CinemaKeyValue("HDR 声明", experience.status.declaredHDR ? "有" : "未声明", accent: experience.status.declaredHDR)
            CinemaKeyValue("全景声声明", experience.status.declaredAtmos ? "有（CHANNELS 含 JOC）" : "未声明", accent: experience.status.declaredAtmos)
            Text("清单里存在某个版本，只说明来源提供它，不代表系统正在播放它。")
                .font(.system(size: 10)).foregroundStyle(CinemaStyle.secondary)
        }
    }

    private var videoSection: some View {
        CinemaCard(title: "当前画面", icon: "sparkles.tv") {
            CinemaKeyValue("所选视频轨道", experience.status.videoDetail)
            CinemaKeyValue("杜比视界", experience.status.videoIsDolbyVision ? "识别到" : "未识别到", accent: experience.status.videoIsDolbyVision)
            CinemaKeyValue("片源判定", experience.status.nativePlayback ? "杜比/HDR → 系统原生层" : "SDR → 允许实时增强")
            CinemaKeyValue("所选模式", playback.selectedPictureMode.title)
            CinemaKeyValue("正在呈现", playback.pictureStatusTitle, accent: playback.pictureIsEnhanced)
            Text(playback.pictureStatusDetail).font(.system(size: 10)).foregroundStyle(CinemaStyle.secondary)
            if let metrics = playback.metrics, metrics.sourceWidth > 0, metrics.sourceHeight > 0,
               metrics.outputWidth > 0, metrics.outputHeight > 0 {
                CinemaKeyValue("实际画面", "\(metrics.sourceWidth)×\(metrics.sourceHeight) → \(metrics.outputWidth)×\(metrics.outputHeight)")
                CinemaKeyValue("处理模式", metrics.mode)
                if let reason = metrics.fallbackReason { CinemaKeyValue("回退原因", reason, accent: true) }
            }
            if !experience.status.variantEvents.isEmpty {
                ForEach(Array(experience.status.variantEvents.enumerated()), id: \.offset) { _, event in
                    CinemaKeyValue("变体事件", event)
                }
            }
        }
    }

    private var audioSection: some View {
        CinemaCard(title: "当前声音", icon: "hifispeaker.2") {
            CinemaKeyValue("所选音轨", experience.status.audioDetail)
            CinemaKeyValue("全景声", experience.status.audioIsAtmos ? "识别到对象音频" : "未识别到", accent: experience.status.audioIsAtmos)
            CinemaKeyValue("输出请求", experience.status.audioSpatialization)
            Text("切换只影响输出请求，不会改变音轨语言、片源或播放意图；普通立体声不会被标为全景声。")
                .font(.system(size: 10)).foregroundStyle(CinemaStyle.secondary)
        }
    }

    private var deviceSection: some View {
        CinemaCard(title: "本机能力", icon: "laptopcomputer") {
            CinemaKeyValue("系统与屏幕", experience.status.deviceDetail)
            Text("这些是设备能力查询结果，不证明当前影片正在以 HDR 或全景声输出。")
                .font(.system(size: 10)).foregroundStyle(CinemaStyle.secondary)
        }
    }

    private var limitationSection: some View {
        CinemaCard(title: "未验证范围", icon: "exclamationmark.triangle") {
            ForEach(experience.status.limitations, id: \.self) { value in
                HStack(alignment: .top, spacing: 7) {
                    Circle().fill(CinemaStyle.accent.opacity(0.75)).frame(width: 4, height: 4).padding(.top, 5)
                    Text(value).font(.system(size: 10)).foregroundStyle(CinemaStyle.secondary)
                }
            }
        }
    }
}
