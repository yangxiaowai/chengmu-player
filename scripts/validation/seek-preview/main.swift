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
  precondition(CommandLine.arguments.count == 5,"Expected local, HLS, rotated fixture, report path")
  func wait() async throws {
   let deadline = Date().addingTimeInterval(12)
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
  controller.configure(asset:AVURLAsset(url:local),itemID:UUID())
  for index in 0..<60 { controller.request(time:Double(index)*0.4,duration:30); try await Task.sleep(nanoseconds:5_000_000) }
  try await wait()
  assert(abs((controller.actualTime ?? -100)-23.6)<=0.45,"Rapid hover showed stale request")
  print("PASS rapidhover",controller.actualTime ?? -1)
  for index in 0..<55 { controller.request(time:Double(index)*0.5,duration:30); try await wait() }
  assert(controller.cachedFrameCount<=48)
  let cacheCount=controller.cachedFrameCount
  controller.configure(asset:AVURLAsset(url:hls),itemID:UUID())
  controller.request(time:18.2,duration:30)
  try await Task.sleep(nanoseconds:200_000_000)
  controller.hide()
  assert(controller.image==nil && !controller.isLoading)
  controller.configure(asset:AVURLAsset(url:local),itemID:UUID())
  controller.request(time:4.4,duration:30)
  try await wait()
  assert(abs((controller.actualTime ?? -100)-4.4)<=0.45,"Old item callback overwritten new item")
  controller.configure(asset:AVURLAsset(url:hls.deletingLastPathComponent().appendingPathComponent("missing.m3u8")),itemID:UUID())
  controller.request(time:4,duration:30)
  try await wait()
  assert(controller.image==nil && controller.actualTime==nil && controller.message != nil)
  controller.request(time:.nan,duration:30)
  assert(controller.image==nil && !controller.isLoading)
  controller.stop()
  assert(controller.cachedFrameCount==0)
  let result:[String:Any]=["version":"0.2.4","scope":"Headless local MP4, rotated MP4 and ordinary no-iframe HLS served on loopback; no remote provider availability assertion","cases":cases,"playing_main_clock_untouched":true,"rapid_hover_last_request_only":true,"cache_count_at_limit":cacheCount,"hide_and_item_change_cancelled":true,"failure_cleared_stale_image":true,"invalid_time_rejected":true,"stop_released_cache":true,"passed":true]
  let json=try JSONSerialization.data(withJSONObject:result,options:[.prettyPrinted,.sortedKeys])
  try json.write(to:URL(fileURLWithPath:CommandLine.arguments[4]))
  print(String(decoding:json,as:UTF8.self))
 }
}
