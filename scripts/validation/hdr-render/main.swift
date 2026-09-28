import Foundation
import AppKit
import AVFoundation
import CoreVideo
import CinemaCore

@main struct HDRRendererSmoke {
 @MainActor static func main() async throws {
  setbuf(stdout, nil)
  _ = NSApplication.shared
  let folder = URL(fileURLWithPath: CommandLine.arguments[1])
  let reportURL = URL(fileURLWithPath: CommandLine.arguments[2])
  var checks: [[String:Any]] = []
  func check(_ name:String, _ passed:Bool, _ detail:String = "") { checks.append(["name":name,"passed":passed,"detail":detail]); print(passed ? "PASS" : "FAIL",name,detail) }
  let item = AVPlayerItem(url: folder.appendingPathComponent("sdr709.mp4"))
  let player = AVPlayer(playerItem: item); player.isMuted = true
  let view = CinemaVideoView(frame: CGRect(x:0,y:0,width:640,height:360))
  var latest = EnhancementMetrics()
  view.configure(player:player,mode:.clarity,generation:UUID(),onMetrics:{latest=$0})
#if !HDR_RENDER_BASELINE
  check("unknown_item_never_attaches_conversion_output", item.outputs.compactMap{$0 as? AVPlayerItemVideoOutput}.isEmpty)
#endif
#if HDR_RENDER_BASELINE
  // Recorded pre-fix behaviour: the surface attached its conversion output for every item before
  // the source was assessed, and offered no way to keep Dolby/HDR material on the native layer.
  player.playImmediately(atRate:1)
  try await Task.sleep(nanoseconds:350_000_000)
  let outputs = item.outputs.compactMap{$0 as? AVPlayerItemVideoOutput}
  var actual = CMTime.invalid
  let format = outputs.first?.copyPixelBuffer(forItemTime:player.currentTime(),itemTimeForDisplay:&actual).map(CVPixelBufferGetPixelFormatType)
  check("source_assessment_can_refuse_the_conversion_output", outputs.isEmpty, "outputs=\(outputs.count) observed=\(String(describing:format))")
#else
  view.configure(player:player,mode:.clarity,generation:UUID(),permission:.inspectSDRFrames,assessedItem:item,onMetrics:{latest=$0})
  player.playImmediately(atRate:1)
  let sdrDeadline = Date().addingTimeInterval(6)
  while latest.processedFrames == 0, Date() < sdrDeadline { try await Task.sleep(nanoseconds:30_000_000) }
  check("verified_sdr_still_runs_enhancement", latest.processedFrames > 0, "frames=\(latest.processedFrames) reason=\(latest.fallbackReason ?? "none")")
  check("sdr_output_is_ten_bit", view.diagnosticState.lastPixelFormat == kCVPixelFormatType_420YpCbCr10BiPlanarVideoRange)
  var untagged: CVPixelBuffer?
  _ = CVPixelBufferCreate(kCFAllocatorDefault, 32, 32, kCVPixelFormatType_32BGRA, nil, &untagged)
  if let untagged {
   CVBufferSetAttachment(untagged, kCVImageBufferColorPrimariesKey, "ColorPrimaries#2" as CFString, .shouldPropagate)
   CVBufferSetAttachment(untagged, kCVImageBufferTransferFunctionKey, "IEC_sRGB" as CFString, .shouldPropagate)
   let decision = ColorFrameGate.decision(for: untagged)
   check("unspecified_primaries_are_not_mislabeled_hdr", decision.blocksEnhancement && decision.reason?.contains("未确认") == true,
         "decision=\(decision)")
  } else { check("unspecified_primaries_are_not_mislabeled_hdr", false, "buffer creation failed") }
  let before = player.currentTime().seconds
  view.configure(player:player,mode:.upscale4K,generation:UUID(),permission:.nativeOnly("HDR 原生播放"),assessedItem:item,onMetrics:{latest=$0})
  check("permission_revocation_removes_output_and_shows_native_layer", item.outputs.compactMap{$0 as? AVPlayerItemVideoOutput}.isEmpty && view.diagnosticState.isNativeVisible)
  try await Task.sleep(nanoseconds:200_000_000)
  check("route_change_preserves_clock_and_player_item", player.currentItem === item && player.currentTime().seconds >= before && player.rate == 1)
  check("revocation_rejects_late_gpu_results", view.diagnosticState.isNativeVisible && !view.diagnosticState.hasEnhancedFrame)
  let other = AVPlayerItem(url: folder.appendingPathComponent("sdr709.mp4"))
  player.replaceCurrentItem(with:other)
  view.configure(player:player,mode:.clarity,generation:UUID(),permission:.inspectSDRFrames,assessedItem:item,onMetrics:{latest=$0})
  check("old_item_authorization_cannot_enable_new_item_output", other.outputs.compactMap{$0 as? AVPlayerItemVideoOutput}.isEmpty)
  player.pause(); view.stop()
  for name in ["pq", "hlg"] {
   let hdrItem = AVPlayerItem(url: folder.appendingPathComponent(name + ".mp4"))
   let hdrPlayer = AVPlayer(playerItem:hdrItem); hdrPlayer.isMuted = true
   let hdrView = CinemaVideoView(frame:CGRect(x:0,y:0,width:640,height:360))
   var hdrMetrics = EnhancementMetrics()
   let cleanup = AdCleanupSettings(enabled:true,regions:[NormalizedVideoRect(x:0.1,y:0.1,width:0.2,height:0.2)])
   hdrView.configure(player:hdrPlayer,mode:.upscale4K,generation:UUID(),cleanup:cleanup,permission:.nativeOnly("\(name.uppercased()) 原生播放"),assessedItem:hdrItem,onMetrics:{hdrMetrics=$0})
   hdrPlayer.playImmediately(atRate:1)
   try await Task.sleep(nanoseconds:500_000_000)
   check(name + "_native_from_first_frame_without_video_output",hdrItem.outputs.compactMap{$0 as? AVPlayerItemVideoOutput}.isEmpty && hdrView.diagnosticState.isNativeVisible && hdrMetrics.processedFrames == 0)
   // Preparation time differs per file, so wait for the first resolved presentation size
   // instead of asserting a fixed delay. The gate itself is unchanged by this wait.
   let sizeDeadline = Date().addingTimeInterval(5)
   while hdrMetrics.sourceWidth == 0, Date() < sizeDeadline { try await Task.sleep(nanoseconds:50_000_000) }
   check(name + "_reports_native_dimensions_and_cleanup_disabled",hdrMetrics.sourceWidth == 320 && hdrMetrics.cleanupAppliedRegions == 0 && hdrMetrics.cleanupReason != nil,"src=\(hdrMetrics.sourceWidth)x\(hdrMetrics.sourceHeight) reason=\(hdrMetrics.cleanupReason ?? "nil")")
   // Simulate absent inspector metadata: real HDR frames must trip the independent pixel gate.
   hdrView.configure(player:hdrPlayer,mode:.upscale4K,generation:UUID(),cleanup:cleanup,permission:.inspectSDRFrames,assessedItem:hdrItem,onMetrics:{hdrMetrics=$0})
   try await Task.sleep(nanoseconds:600_000_000)
   check(name + "_raw_frame_gate_blocks_before_sdr_processing",hdrView.diagnosticState.isNativeVisible && hdrMetrics.processedFrames == 0 && hdrView.diagnosticState.isHDRSticky)
   hdrPlayer.pause(); hdrView.stop()
  }
  // 切回原片 must drop the conversion output, and re-enabling must restore it, without rebuilding.
  do {
   let switchItem = AVPlayerItem(url: folder.appendingPathComponent("sdr709.mp4"))
   let switchPlayer = AVPlayer(playerItem:switchItem); switchPlayer.isMuted = true
   let switchView = CinemaVideoView(frame:CGRect(x:0,y:0,width:640,height:360))
   var switchMetrics = EnhancementMetrics()
   switchView.configure(player:switchPlayer,mode:.clarity,generation:UUID(),permission:.inspectSDRFrames,assessedItem:switchItem,onMetrics:{switchMetrics=$0})
   switchPlayer.playImmediately(atRate:1)
   let onDeadline = Date().addingTimeInterval(8)
   while switchMetrics.processedFrames == 0, Date() < onDeadline { try await Task.sleep(nanoseconds:50_000_000) }
   check("enhancement_runs_before_the_switch", switchMetrics.processedFrames > 0 && switchItem.outputs.compactMap{$0 as? AVPlayerItemVideoOutput}.count == 1,
         "frames=\(switchMetrics.processedFrames) outputs=\(switchItem.outputs.count)")
   switchView.configure(player:switchPlayer,mode:.original,generation:UUID(),permission:.inspectSDRFrames,assessedItem:switchItem,onMetrics:{switchMetrics=$0})
   try await Task.sleep(nanoseconds:250_000_000)
   switchPlayer.playImmediately(atRate:1)
   check("original_switch_detaches_the_conversion_output", switchItem.outputs.compactMap{$0 as? AVPlayerItemVideoOutput}.isEmpty && switchView.diagnosticState.isNativeVisible,
         "outputs=\(switchItem.outputs.count) native=\(switchView.diagnosticState.isNativeVisible)")
   let previousClock = switchPlayer.currentItem
   switchView.configure(player:switchPlayer,mode:.clarity,generation:UUID(),permission:.inspectSDRFrames,assessedItem:switchItem,onMetrics:{switchMetrics=$0})
   var restored = false
   let restoreDeadline = Date().addingTimeInterval(8)
   while !restored, Date() < restoreDeadline {
    if switchItem.outputs.compactMap({ $0 as? AVPlayerItemVideoOutput }).count == 1, switchMetrics.processedFrames > 0, switchView.diagnosticState.hasEnhancedFrame { restored = true }
    try await Task.sleep(nanoseconds:50_000_000)
   }
   // The player was paused by the harness earlier, so the switch is verified by the resumed item,
   // a re-attached conversion output and a new processed frame rather than by the raw clock.
   check("enhancement_switch_restores_processing_without_rebuilding", restored && switchPlayer.currentItem === previousClock && switchMetrics.processedFrames > 0,
         "restored=\(restored) sameItem=\(switchPlayer.currentItem === previousClock) frames=\(switchMetrics.processedFrames)")
   switchPlayer.pause(); switchView.stop()
  }
  if CommandLine.arguments.count > 3 {
   let hlsItem = AVPlayerItem(url:URL(string:CommandLine.arguments[3])!)
   let hlsPlayer = AVPlayer(playerItem:hlsItem); hlsPlayer.isMuted=true
   let hlsView=CinemaVideoView(frame:CGRect(x:0,y:0,width:640,height:360))
   var hlsMetrics=EnhancementMetrics()
   hlsView.configure(player:hlsPlayer,mode:.clarity,generation:UUID(),permission:.inspectSDRFrames,assessedItem:hlsItem,onMetrics:{hlsMetrics=$0})
   hlsPlayer.playImmediately(atRate:1)
   let deadline=Date().addingTimeInterval(8)
   while hlsMetrics.processedFrames == 0, Date()<deadline { try await Task.sleep(nanoseconds:50_000_000) }
   check("ordinary_sdr_hls_retains_enhancement",hlsMetrics.processedFrames>0,"frames=\(hlsMetrics.processedFrames) reason=\(hlsMetrics.fallbackReason ?? "none")")
   hlsPlayer.pause(); hlsView.stop()
  }
#endif
  player.pause(); view.stop()
  let passed = checks.allSatisfy{$0["passed"] as? Bool == true}
  try JSONSerialization.data(withJSONObject:["passed":passed,"checks":checks,"scope":"Headless real AVPlayer/CinemaVideoView; tagged synthetic SDR/PQ/HLG, not actual Dolby mastering or display output certification"],options:[.prettyPrinted,.sortedKeys]).write(to:reportURL)
  if !passed { exit(1) }
 }
}
