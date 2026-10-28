import Foundation
import AVFoundation
import AppKit

final class SubtitleSink: NSObject, AVPlayerItemLegibleOutputPushDelegate {
 private let lock=NSLock(); private var storage=[String]()
 func legibleOutput(_ output: AVPlayerItemLegibleOutput, didOutputAttributedStrings strings: [NSAttributedString], nativeSampleBuffers: [Any], forItemTime itemTime: CMTime) { lock.lock(); storage.append(contentsOf: strings.map(\.string)); lock.unlock() }
 var found:Bool { lock.lock(); defer {lock.unlock()}; return storage.contains {$0.contains("Subtitle retention test")} }
}
@main struct Main {
 static func main() async throws {
  let url=URL(string:try String(contentsOfFile:CommandLine.arguments[1],encoding:.utf8))!
  let item=AVPlayerItem(url:url); let output=AVPlayerItemLegibleOutput(); let sink=SubtitleSink(); output.setDelegate(sink,queue:DispatchQueue.main); output.suppressesPlayerRendering=true; item.add(output)
  let video=AVPlayerItemVideoOutput(pixelBufferAttributes:[kCVPixelBufferPixelFormatTypeKey as String:kCVPixelFormatType_32BGRA]); item.add(video)
  let player=AVPlayer(playerItem:item);player.isMuted=true;player.play()
  let deadline=Date().addingTimeInterval(18)
  while item.status == .unknown && Date()<deadline { try await Task.sleep(nanoseconds:50_000_000) }
  guard item.status == .readyToPlay else {fatalError("item not ready: \(item.error?.localizedDescription ?? "unknown")")}
  if let group=try await item.asset.loadMediaSelectionGroup(for:.legible), let option=group.options.first {item.select(option,in:group)}
  var decoded=false
  while (!sink.found || !decoded || player.currentTime().seconds < 0.5) && Date()<deadline {
   let now=player.currentTime()
   if video.hasNewPixelBuffer(forItemTime:now), let pixels=video.copyPixelBuffer(forItemTime:now,itemTimeForDisplay:nil) { decoded = CVPixelBufferGetWidth(pixels)>0 }
   try await Task.sleep(nanoseconds:100_000_000)
  }
  let time=player.currentTime().seconds
  guard time>0.1, sink.found, decoded else {exit(1)}
  let sought = await withCheckedContinuation { continuation in
   player.seek(to:CMTime(seconds:5,preferredTimescale:600),toleranceBefore:.zero,toleranceAfter:CMTime(seconds:0.1,preferredTimescale:600)) { continuation.resume(returning:$0) }
  }
  let seekDeadline=Date().addingTimeInterval(8);var seekFrame=false
  while Date()<seekDeadline && !seekFrame {
   let now=player.currentTime()
   if now.seconds >= 4.9, video.hasNewPixelBuffer(forItemTime:now), let pixels=video.copyPixelBuffer(forItemTime:now,itemTimeForDisplay:nil) {seekFrame=CVPixelBufferGetWidth(pixels)>0}
   try await Task.sleep(nanoseconds:100_000_000)
  }
  print("avplayer_ready=true initial_seconds=\(time) subtitle_received=\(sink.found) video_frame_decoded=\(decoded) seek_succeeded=\(sought) seek_frame_decoded=\(seekFrame)")
  player.pause();guard sought,seekFrame else {exit(1)}
 }
}
