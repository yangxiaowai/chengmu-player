import Foundation
import AppKit
import AVFoundation
import CoreVideo
import MetalKit
import CinemaCore

@main struct HDRRendererSmoke {
 @MainActor static func main() async throws {
  setbuf(stdout, nil)
  _ = NSApplication.shared
  let folder = URL(fileURLWithPath: CommandLine.arguments[1])
  let reportURL = URL(fileURLWithPath: CommandLine.arguments[2])
  var checks: [[String:Any]] = []
  var compressionGeometrySamples: [[String:Any]] = []
  func check(_ name:String, _ passed:Bool, _ detail:String = "") { checks.append(["name":name,"passed":passed,"detail":detail]); print(passed ? "PASS" : "FAIL",name,detail) }
  let item = AVPlayerItem(url: folder.appendingPathComponent("sdr709.mp4"))
  let player = AVPlayer(playerItem: item); player.isMuted = true
  let view = CinemaVideoView(frame: CGRect(x:0,y:0,width:640,height:360))
  let display = view.subviews.compactMap { $0 as? MTKView }.first
  let renderSpace = try EnhancementPipeline().colorSpace
  check("drawable_color_tag_matches_pipeline_srgb_encoding", display?.colorspace == renderSpace,
        "drawable=\(String(describing: display?.colorspace?.name)) render=\(String(describing: renderSpace.name))")
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
   check("unspecified_primaries_with_explicit_sdr_are_compatible", !decision.blocksEnhancement && ColorFrameGate.inputImage(for: untagged) != nil && ColorFrameGate.assumptionNote(for: untagged)?.contains("709") == true,
         "decision=\(decision)")
   CVBufferSetAttachment(untagged, kCVImageBufferTransferFunctionKey, "TransferFunction#2" as CFString, .shouldPropagate)
   check("unknown_transfer_preserves_native", ColorFrameGate.decision(for: untagged).blocksEnhancement && ColorFrameGate.inputImage(for: untagged) == nil)
   CVBufferRemoveAttachment(untagged, kCVImageBufferTransferFunctionKey)
   check("missing_transfer_preserves_native", ColorFrameGate.decision(for: untagged).blocksEnhancement && ColorFrameGate.inputImage(for: untagged) == nil)
  } else { check("unspecified_primaries_with_explicit_sdr_are_compatible", false, "buffer creation failed") }
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
   let hdrGeneration = UUID()
   hdrView.configure(player:hdrPlayer,mode:.upscale4K,generation:hdrGeneration,cleanup:cleanup,permission:.inspectSDRFrames,assessedItem:hdrItem,onMetrics:{hdrMetrics=$0})
   try await Task.sleep(nanoseconds:600_000_000)
   check(name + "_raw_frame_gate_blocks_before_sdr_processing",hdrView.diagnosticState.isNativeVisible && hdrMetrics.processedFrames == 0 && hdrView.diagnosticState.isHDRSticky)
   hdrView.configure(player:hdrPlayer,mode:.clarity,generation:hdrGeneration,cleanup:cleanup,permission:.inspectSDRFrames,assessedItem:hdrItem,onMetrics:{hdrMetrics=$0})
   try await Task.sleep(nanoseconds:150_000_000)
   check(name + "_mode_switch_preserves_hdr_sticky",hdrView.diagnosticState.isNativeVisible && hdrMetrics.processedFrames == 0 && hdrView.diagnosticState.isHDRSticky && hdrItem.outputs.compactMap{$0 as? AVPlayerItemVideoOutput}.isEmpty)
   hdrPlayer.pause(); hdrView.stop()
  }
  // Changing the requested filter must recover a processing-only failure without a new item or
  // generation. The deliberately small 128x72 input is not supported by the local AI scaler.
  do {
   let recoveryURL = folder.appendingPathComponent("sdr-small.mp4")
   let resize = Process(); resize.executableURL = URL(fileURLWithPath:"/usr/bin/env")
   resize.arguments = ["ffmpeg", "-hide_banner", "-loglevel", "error", "-i", folder.appendingPathComponent("sdr709.mp4").path,
                       "-vf", "scale=128:72", "-c:v", "libx264", "-preset", "ultrafast", "-pix_fmt", "yuv420p", "-movflags", "+write_colr", "-y", recoveryURL.path]
   try resize.run(); resize.waitUntilExit()
   guard resize.terminationStatus == 0 else { throw NSError(domain:"HDRRendererSmoke.fixture",code:Int(resize.terminationStatus)) }
   let recoveryItem = AVPlayerItem(url:recoveryURL)
   let recoveryPlayer = AVPlayer(playerItem:recoveryItem); recoveryPlayer.isMuted = true
   let recoveryView = CinemaVideoView(frame:CGRect(x:0,y:0,width:640,height:360))
   let recoveryGeneration = UUID()
   var recoveryMetrics = EnhancementMetrics()
   recoveryView.configure(player:recoveryPlayer,mode:.appleAI,generation:recoveryGeneration,permission:.inspectSDRFrames,assessedItem:recoveryItem,onMetrics:{recoveryMetrics=$0})
   recoveryPlayer.playImmediately(atRate:1)
   let failureDeadline = Date().addingTimeInterval(6)
   while recoveryMetrics.fallbackReason?.contains("Apple AI") != true, Date() < failureDeadline { try await Task.sleep(nanoseconds:30_000_000) }
   check("unsupported_ai_falls_back_before_mode_recovery",recoveryMetrics.fallbackReason?.contains("Apple AI") == true && recoveryView.diagnosticState.isNativeVisible,
         "reason=\(recoveryMetrics.fallbackReason ?? "none")")
   recoveryView.configure(player:recoveryPlayer,mode:.clarity,generation:recoveryGeneration,permission:.inspectSDRFrames,assessedItem:recoveryItem,onMetrics:{recoveryMetrics=$0})
   let recoveryDeadline = Date().addingTimeInterval(5)
   while !recoveryView.diagnosticState.hasEnhancedFrame, Date() < recoveryDeadline { try await Task.sleep(nanoseconds:30_000_000) }
   check("processing_failure_recovers_after_mode_switch_with_same_generation",recoveryPlayer.currentItem === recoveryItem && recoveryMetrics.processedFrames > 0 && recoveryMetrics.fallbackReason == nil && recoveryView.diagnosticState.hasEnhancedFrame,
         "frames=\(recoveryMetrics.processedFrames) reason=\(recoveryMetrics.fallbackReason ?? "none")")
   recoveryView.configure(player:recoveryPlayer,mode:.upscale4K,generation:recoveryGeneration,permission:.nativeOnly("权限保留测试"),assessedItem:recoveryItem,onMetrics:{recoveryMetrics=$0})
   recoveryView.configure(player:recoveryPlayer,mode:.clarity,generation:recoveryGeneration,permission:.nativeOnly("权限保留测试"),assessedItem:recoveryItem,onMetrics:{recoveryMetrics=$0})
   try await Task.sleep(nanoseconds:150_000_000)
   check("mode_switch_preserves_native_only_permission",recoveryView.diagnosticState.isNativeVisible && !recoveryView.diagnosticState.hasEnhancedFrame && recoveryItem.outputs.compactMap{$0 as? AVPlayerItemVideoOutput}.isEmpty && recoveryMetrics.fallbackReason == "权限保留测试")
   recoveryPlayer.pause(); recoveryView.stop()
  }
  do {
   let noVideoItem = AVPlayerItem(asset:AVMutableComposition())
   let noVideoPlayer = AVPlayer(playerItem:noVideoItem)
   let noVideoView = CinemaVideoView(frame:CGRect(x:0,y:0,width:640,height:360))
   let noVideoGeneration = UUID()
   var noVideoMetrics = EnhancementMetrics()
   noVideoView.configure(player:noVideoPlayer,mode:.appleAI,generation:noVideoGeneration,permission:.inspectSDRFrames,assessedItem:noVideoItem,onMetrics:{noVideoMetrics=$0})
   let geometryDeadline = Date().addingTimeInterval(3)
   while noVideoMetrics.fallbackReason?.contains("方向") != true, Date() < geometryDeadline { try await Task.sleep(nanoseconds:30_000_000) }
   let geometryReason = noVideoMetrics.fallbackReason
   noVideoView.configure(player:noVideoPlayer,mode:.clarity,generation:noVideoGeneration,permission:.inspectSDRFrames,assessedItem:noVideoItem,onMetrics:{noVideoMetrics=$0})
   try await Task.sleep(nanoseconds:150_000_000)
   check("mode_switch_preserves_geometry_failure",geometryReason?.contains("方向") == true && noVideoMetrics.fallbackReason == geometryReason && noVideoView.diagnosticState.isNativeVisible && !noVideoView.diagnosticState.hasEnhancedFrame,
         "reason=\(noVideoMetrics.fallbackReason ?? "none")")
   noVideoView.stop()
  }
  // SDR comparison keeps one stable item-owned output: removing/re-adding it rewinds some
  // AVFoundation clocks. Enhancement stops, while HDR/native-only still removes every owned output.
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
   let stableOutput = switchItem.outputs.compactMap{$0 as? AVPlayerItemVideoOutput}.first
   let beforeComparison = switchPlayer.currentTime().seconds
   switchView.configure(player:switchPlayer,mode:.original,generation:UUID(),permission:.inspectSDRFrames,assessedItem:switchItem,onMetrics:{switchMetrics=$0})
   try await Task.sleep(nanoseconds:250_000_000)
   let comparisonOutputs = switchItem.outputs.compactMap{$0 as? AVPlayerItemVideoOutput}
   check("original_switch_keeps_one_stable_sdr_output_without_enhancement", stableOutput != nil && comparisonOutputs.count == 1 && comparisonOutputs.first === stableOutput && switchView.diagnosticState.isNativeVisible && !switchView.diagnosticState.hasEnhancedFrame && switchView.diagnosticMetrics.processedFrames == 0,
         "outputs=\(comparisonOutputs.count) native=\(switchView.diagnosticState.isNativeVisible) enhanced=\(switchView.diagnosticState.hasEnhancedFrame)")
   check("original_switch_preserves_media_clock", switchPlayer.currentTime().seconds >= beforeComparison - 0.002 && switchPlayer.currentItem === switchItem,
         "before=\(beforeComparison) after=\(switchPlayer.currentTime().seconds)")
   let previousClock = switchPlayer.currentItem
   switchView.configure(player:switchPlayer,mode:.clarity,generation:UUID(),permission:.inspectSDRFrames,assessedItem:switchItem,onMetrics:{switchMetrics=$0})
   var restored = false
   let restoreDeadline = Date().addingTimeInterval(8)
   while !restored, Date() < restoreDeadline {
    if switchItem.outputs.compactMap({ $0 as? AVPlayerItemVideoOutput }).count == 1, switchMetrics.processedFrames > 0, switchView.diagnosticState.hasEnhancedFrame { restored = true }
    try await Task.sleep(nanoseconds:50_000_000)
   }
   check("enhancement_switch_restores_processing_without_rebuilding", restored && switchPlayer.currentItem === previousClock && switchMetrics.processedFrames > 0 && switchItem.outputs.compactMap({$0 as? AVPlayerItemVideoOutput}).first === stableOutput,
         "restored=\(restored) sameItem=\(switchPlayer.currentItem === previousClock) frames=\(switchMetrics.processedFrames)")
   switchView.stop()
   check("view_stop_preserves_the_item_owned_sdr_output", stableOutput != nil && switchItem.outputs.compactMap({$0 as? AVPlayerItemVideoOutput}).count == 1 && switchItem.outputs.compactMap({$0 as? AVPlayerItemVideoOutput}).first === stableOutput)
   // The new view has not claimed the existing output. Native-only authorization must still
   // remove it synchronously rather than leaving an orphan SDR conversion on an HDR route.
   let revokedView = CinemaVideoView(frame:CGRect(x:0,y:0,width:640,height:360))
   var revokedMetrics = EnhancementMetrics()
   revokedView.configure(player:switchPlayer,mode:.clarity,generation:UUID(),permission:.nativeOnly("重建视图时保留 HDR 原生通路"),assessedItem:switchItem,onMetrics:{revokedMetrics=$0})
   check("recreated_native_only_view_removes_unclaimed_sdr_output_immediately", switchItem.outputs.compactMap({$0 as? AVPlayerItemVideoOutput}).isEmpty && revokedView.diagnosticState.isNativeVisible && !revokedView.diagnosticState.hasEnhancedFrame)
   try await Task.sleep(nanoseconds:200_000_000)
   check("recreated_native_only_view_never_submits_enhancement", switchItem.outputs.compactMap({$0 as? AVPlayerItemVideoOutput}).isEmpty && revokedMetrics.processedFrames == 0 && !revokedView.diagnosticState.hasEnhancedFrame)
   switchPlayer.pause(); revokedView.stop()
  }
  do {
   // Stop before the first main-actor suspension, while attachItem's asset-load task is queued.
   // The old view stays alive through the assertion, so a weak capture cannot hide a stale callback.
   let pendingItem = AVPlayerItem(url:folder.appendingPathComponent("sdr709.mp4"))
   let pendingPlayer = AVPlayer(playerItem:pendingItem); pendingPlayer.isMuted = true
   let stoppedView = CinemaVideoView(frame:CGRect(x:0,y:0,width:640,height:360))
   stoppedView.configure(player:pendingPlayer,mode:.clarity,generation:UUID(),permission:.inspectSDRFrames,assessedItem:pendingItem,onMetrics:{_ in})
   stoppedView.stop()
   let replacementView = CinemaVideoView(frame:CGRect(x:0,y:0,width:640,height:360))
   replacementView.configure(player:pendingPlayer,mode:.clarity,generation:UUID(),permission:.nativeOnly("停止后的加载任务不得恢复 SDR 输出"),assessedItem:pendingItem,onMetrics:{_ in})
   try await Task.sleep(nanoseconds:700_000_000)
   check("stopped_view_asset_load_cannot_reattach_output_after_native_revocation", pendingItem.outputs.compactMap({$0 as? AVPlayerItemVideoOutput}).isEmpty && !stoppedView.diagnosticState.hasEnhancedFrame && replacementView.diagnosticState.isNativeVisible,
         "outputs=\(pendingItem.outputs.count)")
   replacementView.stop()
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
  // Real encoded SDR clips, no injected buffers or private surface state. A malformed fixture,
  // a decoder that does not expose the tested geometry, or an unrelated fallback must fail.
  for sar in [1, 2] {
   let metadata = try JSONSerialization.jsonObject(with: Data(contentsOf: folder.appendingPathComponent("compression-sar\(sar).json"))) as? [String:Any]
   let stream = (metadata?["streams"] as? [[String:Any]])?.first ?? [:]
   check("compression_sar\(sar)_fixture_has_expected_encoded_geometry_and_sdr_tags",
         stream["width"] as? Int == 640 && stream["height"] as? Int == 360 &&
         stream["sample_aspect_ratio"] as? String == "\(sar):1" &&
         stream["color_primaries"] as? String == "bt709" &&
         stream["color_transfer"] as? String == "bt709" && stream["color_space"] as? String == "bt709",
         String(describing: stream))
  }
  let inactiveCleanup = AdCleanupSettings(enabled:false, protectedRegions:[
   AdCleanupSettings.defaultProtection, NormalizedVideoRect(x:0.1,y:0.1,width:0.2,height:0.15)
  ])
  func rejectsNonSquareGeometry(_ reason: String?) -> Bool {
   // AVFoundation may expose SAR as a buffer attachment or only as a mismatch between
   // the decoded raster and presentation size. Both are real, explicit mapping failures.
   reason?.contains("特殊像素比例") == true || reason?.contains("显示比例与处理画面不一致") == true
  }
  do {
   let compressionItem = AVPlayerItem(url:folder.appendingPathComponent("compression-sar1.mp4"))
   let compressionPlayer = AVPlayer(playerItem:compressionItem); compressionPlayer.isMuted = true
   let compressionView = CinemaVideoView(frame:CGRect(x:0,y:0,width:640,height:360))
   compressionView.configure(player:compressionPlayer,mode:.compression,generation:UUID(),cleanup:inactiveCleanup,
                             permission:.inspectSDRFrames,assessedItem:compressionItem,resolution:.source,frameRate:.source,onMetrics:{_ in})
   compressionPlayer.playImmediately(atRate:1)
   let deadline = Date().addingTimeInterval(12)
   while Date() < deadline {
    let metrics = compressionView.diagnosticMetrics
    if metrics.processedFrames >= 3 && compressionView.diagnosticState.hasEnhancedFrame { break }
    try await Task.sleep(nanoseconds:30_000_000)
   }
   let metrics = compressionView.diagnosticMetrics
   check("compression_square_pixels_process_with_softening_disabled",
         !inactiveCleanup.isActive && metrics.processedFrames >= 3 && metrics.fallbackReason == nil &&
         metrics.mode.contains("压缩抑噪") && metrics.outputWidth == 640 && metrics.outputHeight == 360 &&
         metrics.cleanupAppliedRegions == 0 && compressionView.diagnosticState.hasEnhancedFrame &&
         !compressionView.diagnosticState.isNativeVisible && !compressionView.diagnosticState.isHDRSticky,
         "frames=\(metrics.processedFrames) output=\(metrics.outputWidth)x\(metrics.outputHeight) mode=\(metrics.mode) reason=\(metrics.fallbackReason ?? "none")")
   compressionGeometrySamples.append(["fixture":"compression-sar1.mp4","requestedFrameRate":"source",
                                     "cleanupActive":inactiveCleanup.isActive,"protectedRegions":inactiveCleanup.protectedRegions.count,
                                     "processedFrames":metrics.processedFrames,"output":[metrics.outputWidth,metrics.outputHeight],
                                     "mode":metrics.mode,"fallback":metrics.fallbackReason ?? "",
                                     "nativeVisible":compressionView.diagnosticState.isNativeVisible])
   compressionPlayer.pause(); compressionView.stop()
  }
  for requestedRate in [EnhancementFrameRate.source, .fps60] {
   let geometryItem = AVPlayerItem(url:folder.appendingPathComponent("compression-sar2.mp4"))
   let geometryPlayer = AVPlayer(playerItem:geometryItem); geometryPlayer.isMuted = true
   let geometryView = CinemaVideoView(frame:CGRect(x:0,y:0,width:640,height:360))
   geometryView.configure(player:geometryPlayer,mode:.compression,generation:UUID(),cleanup:inactiveCleanup,
                          permission:.inspectSDRFrames,assessedItem:geometryItem,resolution:.source,frameRate:requestedRate,onMetrics:{_ in})
   geometryPlayer.playImmediately(atRate:1)
   var everEnhanced = false
   let deadline = Date().addingTimeInterval(12)
   while Date() < deadline {
    everEnhanced = everEnhanced || geometryView.diagnosticState.hasEnhancedFrame
    if rejectsNonSquareGeometry(geometryView.diagnosticMetrics.fallbackReason) { break }
    try await Task.sleep(nanoseconds:30_000_000)
   }
   // Observe beyond the rejection so a queued or late enhanced result cannot hide behind it.
   for _ in 0..<10 {
    try await Task.sleep(nanoseconds:30_000_000)
    everEnhanced = everEnhanced || geometryView.diagnosticState.hasEnhancedFrame
   }
   let metrics = geometryView.diagnosticMetrics
   check("compression_sar2_\(requestedRate.rawValue)_preserves_native_without_softening",
         !inactiveCleanup.isActive && rejectsNonSquareGeometry(metrics.fallbackReason) &&
         metrics.processedFrames == 0 && metrics.interpolatedFrames == 0 && metrics.cleanupAppliedRegions == 0 &&
         !everEnhanced && !geometryView.diagnosticState.hasEnhancedFrame && geometryView.diagnosticState.isNativeVisible &&
         !geometryView.diagnosticState.isHDRSticky && geometryItem.status == .readyToPlay &&
         geometryPlayer.currentTime().isNumeric && geometryPlayer.currentTime().seconds > 0,
         "frames=\(metrics.processedFrames) generated=\(metrics.interpolatedFrames) everEnhanced=\(everEnhanced) reason=\(metrics.fallbackReason ?? "none") timing=\(metrics.timingNote ?? "none")")
   if requestedRate == .fps60 {
    // This diagnostic is assigned by the real lookahead geometry rejection, before the
    // main decoder is checked on the ordinary path. Mere absence of interpolation is insufficient.
    check("compression_sar2_fps60_rejects_lookahead_geometry_before_returning_to_source_rate",
          rejectsNonSquareGeometry(metrics.timingNote) && metrics.timingNote?.contains("跟随片源帧率") == true,
          metrics.timingNote ?? "no lookahead geometry rejection observed")
   }
   compressionGeometrySamples.append(["fixture":"compression-sar2.mp4","requestedFrameRate":requestedRate.rawValue,
                                     "cleanupActive":inactiveCleanup.isActive,"protectedRegions":inactiveCleanup.protectedRegions.count,
                                     "processedFrames":metrics.processedFrames,"interpolatedFrames":metrics.interpolatedFrames,
                                     "everEnhanced":everEnhanced,"fallback":metrics.fallbackReason ?? "",
                                     "timing":metrics.timingNote ?? "","presentationSize":[geometryItem.presentationSize.width,geometryItem.presentationSize.height],
                                     "nativeVisible":geometryView.diagnosticState.isNativeVisible])
   geometryPlayer.pause(); geometryView.stop()
  }
#endif
  player.pause(); view.stop()
  let passed = checks.allSatisfy{$0["passed"] as? Bool == true}
  try JSONSerialization.data(withJSONObject:["passed":passed,"checks":checks,"compressionGeometrySamples":compressionGeometrySamples,"scope":"Headless real AVPlayer/CinemaVideoView; tagged synthetic SDR/PQ/HLG and encoded square/non-square pixel SDR compression-mode geometry checks, including the real lookahead decoder at a requested 60 fps. No RGBA screenshot, physical display, sustained 60 fps, audio sync or Dolby mastering certification."],options:[.prettyPrinted,.sortedKeys]).write(to:reportURL)
  if !passed { exit(1) }
 }
}
