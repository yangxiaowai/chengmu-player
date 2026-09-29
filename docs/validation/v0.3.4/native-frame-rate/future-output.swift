import Foundation
import AVFoundation
import CoreVideo
import QuartzCore

let url=URL(fileURLWithPath:CommandLine.arguments.count>1 ? CommandLine.arguments[1]:".build/restoration-lab/clean-film.mp4")
let item=AVPlayerItem(url:url)
let output=AVPlayerItemVideoOutput(pixelBufferAttributes:[kCVPixelBufferPixelFormatTypeKey as String:kCVPixelFormatType_32BGRA])
output.suppressesPlayerRendering=true
item.add(output)
let player=AVPlayer(playerItem:item)
player.isMuted=true
player.automaticallyWaitsToMinimizeStalling=false
func spin(_ seconds:Double) {let end=Date().addingTimeInterval(seconds);while Date()<end {RunLoop.current.run(until:Date().addingTimeInterval(0.005))}}
let begin=Date()
while item.status == .unknown && Date().timeIntervalSince(begin)<10 {spin(0.01)}
output.requestNotificationOfMediaDataChange(withAdvanceInterval:0.1)
player.play()
spin(0.4)
var rows:[[String:Any]]=[]
for index in 0..<20 {
 let now=item.currentTime(),future=CMTimeAdd(now,CMTime(value:80,timescale:1000))
 var currentPTS=CMTime.invalid,futurePTS=CMTime.invalid,afterPTS=CMTime.invalid
 let currentNew=output.hasNewPixelBuffer(forItemTime:now)
 let current=output.copyPixelBuffer(forItemTime:now,itemTimeForDisplay:&currentPTS)
 let futureNew=output.hasNewPixelBuffer(forItemTime:future)
 let futureFrame=output.copyPixelBuffer(forItemTime:future,itemTimeForDisplay:&futurePTS)
 let currentAfter=output.copyPixelBuffer(forItemTime:now,itemTimeForDisplay:&afterPTS)
 func seconds(_ t:CMTime)->Any {t.isNumeric ? t.seconds as Any:NSNull()}
 rows.append(["index":index,"player_time":seconds(now),"current_new":currentNew,"current_present":current != nil,"current_pts":seconds(currentPTS),"future_requested":seconds(future),"future_new":futureNew,"future_present":futureFrame != nil,"future_pts":seconds(futurePTS),"future_ahead_of_current_ms":futurePTS.isNumeric && currentPTS.isNumeric ? (futurePTS.seconds-currentPTS.seconds)*1000 as Any:NSNull(),"current_after_future_present":currentAfter != nil,"current_after_future_pts":seconds(afterPTS)])
 spin(0.05)
}
player.pause();item.remove(output)
let report:[String:Any]=["fixture":url.path,"status":item.status.rawValue,"time_control":player.timeControlStatus.rawValue,"rows":rows,"scope":"Local AVPlayerItemVideoOutput at playing currentTime and currentTime+80ms; no visible UI, main runloop, 20 polling instants. Does not prove remote/HLS forward decode contracts."]
try JSONSerialization.data(withJSONObject:report,options:[.prettyPrinted,.sortedKeys]).write(to:URL(fileURLWithPath:".build/frame-rate-probe/future-output.json"))
print("future buffers \(rows.filter{$0["future_present"] as? Bool == true}.count)/20")
print(String(data:try JSONSerialization.data(withJSONObject:rows.prefix(4).map{$0},options:[.prettyPrinted]),encoding:.utf8)!)
