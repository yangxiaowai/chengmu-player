import Foundation
import AVFoundation
import CinemaCore

/// Real controller with an isolated preference domain. No window or remote media is opened.
@main struct PictureSwitchSmoke {
    @MainActor static func main() throws {
        let suite = "CinemaPictureSwitch.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let store = PlaybackPreferencesStore(defaults: defaults, arguments: ["PictureSwitch"])
        let controller = PlaybackController(preferencesStore: store)
        var passed = true
        func check(_ value: Bool, _ message: String) {
            print("\(value ? "PASS" : "FAIL") \(message)")
            passed = passed && value
        }
        check(controller.selectedPictureMode == .original, "new profile uses native original")
        controller.selectEnhancementMode(.upscale4K)
        check(controller.pipelineProcessesFrames && controller.surfaceMode == .upscale4K, "mode choice restores processing from original")
        controller.pipelineProcessesFrames = false
        controller.selectEnhancementMode(.clarity)
        check(controller.pipelineProcessesFrames && controller.surfaceMode == .clarity, "quality studio choice restores processing after switch off")
        check(!controller.pictureIsEnhanced && !controller.canCompareOriginal, "selection without a rendered frame is not reported as enhanced")
        let item = AVPlayerItem(asset: AVMutableComposition())
        controller.player.replaceCurrentItem(with: item)
        controller.position = 42
        controller.subtitleText = "测试字幕"
        let intent = controller.playbackIntentID
        var metrics = EnhancementMetrics()
        metrics.mode = EnhancementMode.clarity.title
        metrics.isEnhancedOutput = true
        metrics.sourceWidth = 1920; metrics.sourceHeight = 1080
        metrics.outputWidth = 1920; metrics.outputHeight = 1080
        controller.metrics = metrics
        check(controller.pictureIsEnhanced && controller.canCompareOriginal, "completed enhancement enables comparison")
        controller.selectEnhancementMode(.clarity)
        check(controller.pictureIsEnhanced, "reselecting same paused mode keeps real output status")
        let saved = store.load()
        controller.toggleOriginalComparison()
        check(controller.isComparingOriginal && controller.surfaceMode == .original && controller.selectedPictureMode == .clarity,
              "comparison presents original while retaining selected enhancement")
        check(store.load() == saved, "comparison never changes persisted preferences")
        check(controller.player.currentItem === item && controller.position == 42 && controller.subtitleText == "测试字幕" && controller.playbackIntentID == intent,
              "comparison preserves item position subtitles and play intent")
        controller.toggleOriginalComparison()
        check(!controller.isComparingOriginal && controller.surfaceMode == .clarity && store.load() == saved,
              "leaving comparison restores selected processing without changing preferences")
        metrics.fallbackReason = "帧预算不足"; metrics.isEnhancedOutput = false
        controller.metrics = metrics
        check(!controller.pictureIsEnhanced && !controller.canCompareOriginal && controller.pictureStatusDetail == "帧预算不足",
              "fallback status reports native presentation and its actual reason")
        controller.selectEnhancementMode(.original)
        controller.pipelineProcessesFrames = true
        check(controller.surfaceMode == .clarity, "turning enhancement back on after original selects gentle denoise")
        for mode in [EnhancementMode.temporal, .restoration] {
            controller.selectEnhancementMode(mode)
            check(controller.surfaceMode == mode && store.load().enhancement == mode.rawValue,
                  "\(mode.rawValue) selection reaches the surface and survives restart")
            metrics.mode = "原帧（时域参考建立中）"; metrics.fallbackReason = nil; metrics.isEnhancedOutput = true
            controller.metrics = metrics
            check(controller.pictureStatusTitle == metrics.mode, "priming reports actual frame state rather than requested repair")
            let modePreferences = store.load()
            controller.toggleOriginalComparison()
            controller.toggleOriginalComparison()
            check(controller.surfaceMode == mode && store.load() == modePreferences,
                  "\(mode.rawValue) comparison restores selection without overwriting settings")
        }
        controller.player.replaceCurrentItem(with: nil)
        exit(passed ? 0 : 1)
    }
}
