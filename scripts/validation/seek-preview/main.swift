import Foundation
import AVFoundation
import AppKit
@main struct Smoke {
 @MainActor static func main() async throws {
  setbuf(stdout,nil)
  let controller = SeekPreviewController()
  let local = URL(fileURLWithPath: CommandLine.arguments[1])
  let hls = URL(string: CommandLine.arguments[2])!
  var cases: [[String:Any]] = []
  precondition(CommandLine.arguments.count == 9,"Expected local, HLS, rotated fixture, report path, extensionless HLS, slow HLS, slow segment HLS and unknown slow HLS")
  let extensionlessHLS = URL(string: CommandLine.arguments[5])!
  func wait(seconds: Double = 12) async throws {
   let deadline = Date().addingTimeInterval(seconds)
   while controller.isLoading, Date() < deadline { try await Task.sleep(nanoseconds:20_000_000) }
   assert(!controller.isLoading,"Request did not meet deadline")
  }
  for (name,url) in [("local",local),("ordinary_hls",hls),("rotated_local",URL(fileURLWithPath:CommandLine.arguments[3]))] {
   let main = AVPlayer(playerItem:AVPlayerItem(url:url))
   let itemID=UUID()
   controller.configure(asset:main.currentItem!.asset,itemID:itemID)
   let begin=Date()
   controller.request(time:7.3,duration:30)
   try await wait()
   guard let image=controller.image, let actual=controller.actualTime else { fatalError("\(name) \(controller.message ?? "no image")") }
   assert(abs(actual-7.3)<=0.45)
   assert(image.size.width<=320 && image.size.height<=180)
   assert(main.rate==0 && main.currentTime().seconds==0,"Preview changed main player")
   if name=="rotated_local" { assert(image.size.height>image.size.width) }
   print("PASS",name,image.size,actual,Date().timeIntervalSince(begin))
   cases.append(["source":name,"image_size":[image.size.width,image.size.height],"requested_time":controller.requestedTime,"actual_time":actual,"latency_seconds":Date().timeIntervalSince(begin),"main_player_unchanged":true])
  }
  let extensionlessPlayer = AVPlayer(playerItem: AVPlayerItem(url: extensionlessHLS))
  let extensionlessItemID = UUID()
  let extensionlessAsset = extensionlessPlayer.currentItem!.asset
  controller.configure(asset: extensionlessAsset, itemID: extensionlessItemID, isConfirmedHLS: true)
  let extensionlessStarted = Date()
  controller.request(time: 7.3, duration: 30)
  try await wait()
  guard controller.image != nil, let extensionlessTime = controller.actualTime else { fatalError("extensionless HLS did not return a frame: \(controller.message ?? "unknown")") }
  let extensionlessLatency = Date().timeIntervalSince(extensionlessStarted)
  assert(abs(extensionlessTime - 7.3) <= 0.45)
  assert(extensionlessLatency < 2.5, "Confirmed HLS preview took the slow generator path")
  assert(extensionlessPlayer.currentTime().seconds == 0 && extensionlessPlayer.rate == 0)
  // Delayed source inspection must update the same item and restart its pending preview.
  controller.configure(asset: extensionlessAsset, itemID: extensionlessItemID, isConfirmedHLS: false)
  controller.request(time: 12.4, duration: 30)
  try await Task.sleep(nanoseconds: 50_000_000)
  controller.configure(asset: extensionlessAsset, itemID: extensionlessItemID, isConfirmedHLS: true)
  try await wait()
  assert(controller.image != nil && abs((controller.actualTime ?? -100) - 12.4) <= 0.45, "Late HLS confirmation lost the current hover")
  assert(extensionlessPlayer.currentTime().seconds == 0 && extensionlessPlayer.rate == 0)
  print("PASS confirmed_extensionless_hls", extensionlessTime)
  cases.append(["source":"confirmed_extensionless_hls", "requested_time":7.3,"actual_time":extensionlessTime,"latency_seconds":extensionlessLatency,"main_player_unchanged":true])
  let playingMain = AVPlayer(playerItem: AVPlayerItem(url: local))
  playingMain.playImmediately(atRate: 1)
  try await Task.sleep(nanoseconds: 300_000_000)
  let positionBefore = playingMain.currentTime().seconds
  controller.configure(asset: playingMain.currentItem!.asset, itemID: UUID())
  controller.request(time: 18.2, duration: 30)
  try await wait()
  let positionAfter = playingMain.currentTime().seconds
  assert(playingMain.rate == 1 && positionAfter > positionBefore && positionAfter < positionBefore + 2, "Preview paused or sought the playing main clock")
  playingMain.pause()
  controller.configure(asset:AVURLAsset(url:hls),itemID:UUID(),isConfirmedHLS:true)
  // Mouse events at the same timeline position must not restart an in-flight decode forever.
  var seenRepeatedHoverFrame = false
  for _ in 0..<20 {
   controller.request(time: 11.2, duration: 30)
   try await Task.sleep(nanoseconds:100_000_000)
   if controller.image != nil { seenRepeatedHoverFrame = true; break }
  }
  assert(seenRepeatedHoverFrame, "Repeated same-position hover starved preview")
  controller.configure(asset:AVURLAsset(url:hls),itemID:UUID(),isConfirmedHLS:true)
  var seenJitterFrame = false
  for index in 0..<25 {
   controller.request(time:22.0 + (index.isMultiple(of: 2) ? 0 : 0.06), duration:30)
   try await Task.sleep(nanoseconds:100_000_000)
   if controller.image != nil && abs((controller.actualTime ?? -100) - controller.requestedTime) <= 0.45 { seenJitterFrame = true }
  }
  assert(seenJitterFrame, "Small repeated hover jitter must not starve preview")
  print("PASS small_hover_jitter_keeps_accurate_frame")
  // The initial target's nearest decoded frame may be on the opposite side of
  // a newer, nearby hover. It is the latest target that determines correctness.
  controller.configure(asset:AVURLAsset(url:local),itemID:UUID())
  controller.request(time:7.3,duration:30)
  try await Task.sleep(nanoseconds:50_000_000)
  controller.request(time:7.7,duration:30)
  try await wait()
  assert(controller.image != nil && abs((controller.actualTime ?? -100) - controller.requestedTime) <= 0.45,
         "A coalesced hover must return a frame matching the latest target")
  print("PASS coalesced_hover_matches_latest_time")
  controller.configure(asset:AVURLAsset(url:local),itemID:UUID())
  for index in 0..<60 { controller.request(time:Double(index)*0.4,duration:30); try await Task.sleep(nanoseconds:5_000_000) }
  try await wait()
  assert(abs((controller.actualTime ?? -100)-23.6)<=0.45,"Rapid hover showed stale request")
  print("PASS rapidhover",controller.actualTime ?? -1)
  for index in 0..<55 { controller.request(time:Double(index)*0.5,duration:30); try await wait() }
  assert(controller.cachedFrameCount<=48)
  let cacheCount=controller.cachedFrameCount
  controller.configure(asset:AVURLAsset(url:hls),itemID:UUID(),isConfirmedHLS:true)
  controller.request(time:18.2,duration:30)
  try await Task.sleep(nanoseconds:200_000_000)
  controller.hide()
  assert(controller.image==nil && !controller.isLoading)
  controller.configure(asset:AVURLAsset(url:local),itemID:UUID())
  controller.request(time:4.4,duration:30)
  try await wait()
  assert(abs((controller.actualTime ?? -100)-4.4)<=0.45,"Old item callback overwritten new item")
  controller.configure(asset:AVURLAsset(url:hls.deletingLastPathComponent().appendingPathComponent("missing.m3u8")),itemID:UUID(),isConfirmedHLS:true)
  controller.request(time:4,duration:30)
  try await wait()
  assert(controller.image==nil && controller.actualTime==nil && controller.message != nil)
  controller.request(time:.nan,duration:30)
  assert(controller.image==nil && !controller.isLoading)
  let slowHLS = URL(string: CommandLine.arguments[6])!
  controller.configure(asset: AVURLAsset(url: slowHLS), itemID: UUID(), isConfirmedHLS: true)
  controller.request(time: 7.3, duration: 30)
  try await wait()
  assert(controller.image != nil && abs((controller.actualTime ?? -100) - 7.3) <= 0.45, "A playable HLS playlist responding after five seconds must still show the requested frame")
  print("PASS slow_hls_requested_frame")
  controller.configure(asset: AVURLAsset(url: URL(string: CommandLine.arguments[7])!), itemID: UUID(), isConfirmedHLS: true)
  controller.request(time: 22, duration: 30)
  try await wait()
  assert(controller.image != nil && abs((controller.actualTime ?? -100) - 22) <= 0.45, "A playable HLS segment responding after three seconds must still show the requested frame")
  print("PASS slow_hls_segment_requested_frame")
  controller.configure(asset: AVURLAsset(url: URL(string: CommandLine.arguments[8])!), itemID: UUID(), isConfirmedHLS: false)
  controller.request(time: 7.3, duration: 30)
  try await wait(seconds: 20)
  assert(controller.image != nil && abs((controller.actualTime ?? -100) - 7.3) <= 0.45, "An unconfirmed extensionless HLS URL with a slow playlist must still show the requested frame")
  print("PASS slow_unconfirmed_hls_requested_frame")
  let base = hls.deletingLastPathComponent()
  controller.configure(asset: AVURLAsset(url: base.appendingPathComponent("cancel-late.m3u8")), itemID: UUID(), isConfirmedHLS: true)
  controller.request(time: 17, duration: 30)
  try await Task.sleep(nanoseconds: 250_000_000)
  let cancelStarted = Date(); controller.hide()
  assert(!controller.isLoading && Date().timeIntervalSince(cancelStarted) < 0.5, "Leaving a slow preview must immediately clear the loading state")
  controller.configure(asset: AVURLAsset(url: local), itemID: UUID())
  controller.request(time: 4.4, duration: 30); try await wait()
  try await Task.sleep(nanoseconds: 3_500_000_000)
  assert(controller.image != nil && abs((controller.actualTime ?? -100) - 4.4) <= 0.45, "Cancelled network responses must not overwrite a new item")
  print("PASS cancel_slow_preview_keeps_new_item")
  controller.configure(asset: AVURLAsset(url: base.appendingPathComponent("hang.m3u8")), itemID: UUID(), isConfirmedHLS: true)
  let hangStarted = Date(); controller.request(time: 7.3, duration: 30); try await wait(seconds: 20)
  assert(!controller.isLoading && controller.image == nil && controller.message != nil && Date().timeIntervalSince(hangStarted) <= 19,
         "A nonresponsive HLS playlist must exit loading within the finite budget")
  print("PASS nonresponsive_hls_stops_loading")
  for index in 0..<10 {
   controller.request(time: 7.3 + (index.isMultiple(of: 2) ? 0 : 0.06), duration: 30)
   try await Task.sleep(nanoseconds: 100_000_000)
  }
  assert(!controller.isLoading && controller.message != nil, "Same-position jitter must not silently restart a failed preview")
  controller.request(time: 9, duration: 30)
  assert(controller.isLoading, "Moving to another position must permit retry")
  controller.hide()
  print("PASS failed_hover_stays_failed_until_new_position")
  controller.stop()
  assert(controller.cachedFrameCount==0)
  let result:[String:Any]=["version":"0.2.4","scope":"Headless local MP4, rotated MP4 and ordinary no-iframe HLS, including an extensionless URL, served on loopback; no remote provider availability assertion","cases":cases,"late_hls_confirmation_restarts_hover":true,"playing_main_clock_untouched":true,"rapid_hover_last_request_only":true,"cache_count_at_limit":cacheCount,"hide_and_item_change_cancelled":true,"failure_cleared_stale_image":true,"invalid_time_rejected":true,"stop_released_cache":true,"passed":true]
  let json=try JSONSerialization.data(withJSONObject:result,options:[.prettyPrinted,.sortedKeys])
  try json.write(to:URL(fileURLWithPath:CommandLine.arguments[4]))
  print(String(decoding:json,as:UTF8.self))
 }
}
