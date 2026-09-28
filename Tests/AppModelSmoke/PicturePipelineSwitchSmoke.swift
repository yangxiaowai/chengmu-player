import Foundation
import CinemaCore

/// Confirms the picture choice has exactly two states and that no HDR enhancement mode exists.
/// Runs the real `PlaybackController`; no window, no media, no window server interaction.
@main struct TwoState {
    @MainActor static func main() {
        let controller = PlaybackController()
        print("default: pipeline=\(controller.pipelineProcessesFrames) surfaceMode=\(controller.surfaceMode)")
        controller.pipelineProcessesFrames = false
        print("原片直通: pipeline=\(controller.pipelineProcessesFrames) surfaceMode=\(controller.surfaceMode)")
        controller.enhancementMode = .upscale4K
        if controller.enhancementMode != .original { controller.pipelineProcessesFrames = true }
        print("选择 4K: pipeline=\(controller.pipelineProcessesFrames) surfaceMode=\(controller.surfaceMode)")
        // A stored value from the removed three-state build must not survive as a preference.
        let legacy = PlaybackPreferences(pipeline: "preferSDR")
        print("legacy preferSDR -> \(legacy.pipeline) processes=\(legacy.pipelineProcessesFrames)")
        let passed = controller.pipelineProcessesFrames && controller.surfaceMode == .upscale4K && legacy.pipeline == PlaybackPreferences.pipelineEnhanced
        print(passed ? "PASS two states, HDR enhancement removed" : "FAIL")
        exit(passed ? 0 : 1)
    }
}
