import Foundation
import AVFoundation
import CinemaCore
@main struct AudioPolicyCheck {
    @MainActor static func main() {
        let player = PlaybackController()
        player.open(url: URL(fileURLWithPath: "/tmp/cinema-audio-policy-nonexistent.mp4"), title: "Isolated settings check", episode: "")
        player.pause()
        let item = player.player.currentItem!
        let passed = item.allowedAudioSpatializationFormats == .multichannel && item.appliesPerFrameHDRDisplayMetadata && item.audioMix == nil
        print("Expected multichannel-only spatialization with per-frame HDR metadata, no audio mix; actual flags=\(item.allowedAudioSpatializationFormats.rawValue), metadata=\(item.appliesPerFrameHDRDisplayMetadata), passed=\(passed)")
        exit(passed ? 0 : 1)
    }
}
