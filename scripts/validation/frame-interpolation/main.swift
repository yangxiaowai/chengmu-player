import Foundation
import AVFoundation
import CoreImage
import CoreMedia
import CoreVideo
import Metal
import CinemaCore
let reportPath=CommandLine.arguments.count>1 ? CommandLine.arguments[1]:"docs/validation/v0.3.4/frame-interpolation.json"
let artifactDirectory=URL(fileURLWithPath:reportPath).deletingPathExtension().appendingPathExtension("frames")
try FileManager.default.createDirectory(at:artifactDirectory,withIntermediateDirectories:true)
let pipeline=try EnhancementPipeline(),helper=InterpolatedFramePipeline(pipeline:pipeline),id=UUID()
var checks:[[String:Any]]=[]
func check(_ name:String,_ value:Bool,_ evidence:[String:Any]=[:]){checks.append(["name":name,"passed":value,"evidence":evidence]);print("\(value ? "PASS":"FAIL") \(name) \(evidence)")}
func fixtureImage(_ position:Double,color:Double?=nil)->CIImage {
 let base=CIImage(color:CIColor(red:color ?? 0.08,green:color ?? 0.08,blue:color ?? 0.08)).cropped(to:CGRect(x:0,y:0,width:640,height:360))
 let box=CIImage(color:CIColor(red:0.75,green:0.5,blue:0.2)).cropped(to:CGRect(x:180+position*8,y:120,width:110,height:110))
 return color == nil ? box.composited(over:base):base
}
func fixture(_ index:Int,color:Double?=nil)throws->CVPixelBuffer {
 var b:CVPixelBuffer?
 let attrs:[String:Any]=[kCVPixelBufferMetalCompatibilityKey as String:true,kCVPixelBufferIOSurfacePropertiesKey as String:[:]]
 guard CVPixelBufferCreate(nil,640,360,kCVPixelFormatType_32BGRA,attrs as CFDictionary,&b)==0,let b else{throw NSError(domain:"buffer",code:1)}
 let source=fixtureImage(Double(index),color:color)
 pipeline.context.render(source,to:b,bounds:source.extent,colorSpace:pipeline.colorSpace)
 CVBufferSetAttachment(b,kCVImageBufferColorPrimariesKey,kCVImageBufferColorPrimaries_ITU_R_709_2,.shouldPropagate)
 CVBufferSetAttachment(b,kCVImageBufferTransferFunctionKey,kCVImageBufferTransferFunction_sRGB,.shouldPropagate)
 return b
}
func pixels(_ f:EnhancedFrame)->[UInt8] {
 var bytes=[UInt8](repeating:0,count:f.width*f.height*4)
 pipeline.context.render(CIImage(mtlTexture:f.texture,options:[.colorSpace:pipeline.colorSpace])!,toBitmap:&bytes,rowBytes:f.width*4,bounds:CGRect(x:0,y:0,width:f.width,height:f.height),format:.RGBA8,colorSpace:pipeline.colorSpace)
 return bytes
}
func bitmap(_ image:CIImage)->[UInt8] {
 var data=[UInt8](repeating:0,count:640*360*4)
 pipeline.context.render(image,toBitmap:&data,rowBytes:640*4,bounds:CGRect(x:0,y:0,width:640,height:360),format:.RGBA8,colorSpace:pipeline.colorSpace)
 return data
}
func mse(_ a:[UInt8],_ b:[UInt8])->Double {
 var sum=0.0,n=0
 for y in 110..<250 {for x in 160..<320 {let i=(y*640+x)*4;for c in 0..<3 {let d=Double(a[i+c])-Double(b[i+c]);sum+=d*d;n+=1}}}
 return sum/Double(n)
}
func save(_ image:CIImage,_ name:String)throws {
 try pipeline.context.writePNGRepresentation(of:image,to:artifactDirectory.appendingPathComponent(name+".png"),format:.RGBA8,colorSpace:pipeline.colorSpace)
}
var all:[(time:Double,frame:EnhancedFrame)]=[],generated=0,times:[Double]=[]
var retained:EnhancedFrame?,retainedPixels:[UInt8]=[]
for index in 0...24 {
 let frames=try helper.process(buffer:fixture(index),time:CMTime(value:Int64(index),timescale:24),mode:.original,resolution:.source,transform:.identity,cleanup:.init(),streamID:id)
 if index==0 {check("first reference reports priming",helper.lastWasPriming && helper.lastInterpolatedFrameCount==0,["setup_ms":helper.lastSetupMilliseconds])}
 if index==1 {check("first FRC execution marked warmup",helper.lastWasPriming);retained=frames.first!.frame;retainedPixels=pixels(retained!)
 let previous=bitmap(fixtureImage(0)),current=bitmap(fixtureImage(1)),truth=bitmap(fixtureImage(0.4))
 let blended=zip(previous,current).map{UInt8((Double($0.0)*0.6+Double($0.1)*0.4).rounded())}
 check("generated frame is neither source copy nor blend",retainedPixels != previous && retainedPixels != current && retainedPixels != blended)
 check("motion-compensated midpoint improves analytic motion truth over blend",mse(retainedPixels,truth)<mse(blended,truth),["motion_mse":mse(retainedPixels,truth),"blend_mse":mse(blended,truth),"duplicate_mse":mse(previous,truth)])
 try save(fixtureImage(0),"motion-source-000000")
 try save(fixtureImage(1),"motion-source-041667")
 try save(fixtureImage(0.4),"motion-truth-016667")
 try save(CIImage(mtlTexture:retained!.texture,options:[.colorSpace:pipeline.colorSpace])!,"motion-interpolated-016667")
 }
 generated+=helper.lastInterpolatedFrameCount
 if !helper.lastWasPriming {times.append(helper.lastMilliseconds)}
 all+=frames
}
check("24fps inputs produce exactly 60 grid points before one second",all.filter{$0.time<1-1e-8}.count==60,["count":all.filter{$0.time<1-1e-8}.count,"generated":generated])
check("only actual generated motion frames carry readiness marker",all.filter{$0.frame.isInterpolated}.count==generated && all.first?.frame.isInterpolated==false && retained?.isInterpolated==true)
check("all subsequent points on 60 grid",all.allSatisfy{abs($0.time*60-($0.time*60).rounded())<1e-6})
check("all timestamps unique increasing",zip(all,all.dropFirst()).allSatisfy{$0.time<$1.time})
check("all generated textures independent",Set(all.map{ObjectIdentifier($0.frame.texture)}).count==all.count)
check("retained interpolated output unchanged by later processing",pixels(retained!)==retainedPixels)
let changed=try helper.process(buffer:fixture(25),time:CMTime(value:25,timescale:24),mode:.original,resolution:.source,transform:.identity,cleanup:.init(),streamID:UUID())
check("stream change primes despite continuous PTS",helper.lastWasPriming && helper.lastInterpolatedFrameCount==0 && changed.count==1)
let back=try helper.process(buffer:fixture(0),time:.zero,mode:.original,resolution:.source,transform:.identity,cleanup:.init(),streamID:id)
check("backward seek primes",helper.lastWasPriming && back.count==1)
_=try helper.process(buffer:fixture(1),time:CMTime(value:1,timescale:24),mode:.original,resolution:.source,transform:.identity,cleanup:.init(),streamID:id)
let cut=try helper.process(buffer:fixture(2,color:0.9),time:CMTime(value:2,timescale:24),mode:.original,resolution:.source,transform:.identity,cleanup:.init(),streamID:id)
check("hard scene cut does not morph",helper.lastInterpolatedFrameCount==0 && cut.allSatisfy{!$0.frame.isInterpolated} && helper.lastResetReason?.contains("切镜")==true,["returned_frames":cut.count])
_=try helper.process(buffer:fixture(3,color:0.1),time:CMTime(value:3,timescale:24),mode:.original,resolution:.source,transform:.identity,cleanup:.init(),streamID:id)
check("off-grid cut does not add source anchor",helper.lastInterpolatedFrameCount==0)
helper.reset()
_=try helper.process(buffer:fixture(4),time:CMTime(value:4,timescale:24),mode:.original,resolution:.source,transform:.identity,cleanup:.init(),streamID:id)
check("explicit reset primes",helper.lastWasPriming)
// Same-PTS source/enhanced film evidence uses actual successive decoded frames.
// It is a visual artifact, not a paired clean-reference quality benchmark.
var film:[String:Any]=["skipped":"optional local fixture missing"]
let filmURL=URL(fileURLWithPath:".build/restoration-lab/noisy-film.mp4")
if FileManager.default.fileExists(atPath:filmURL.path) {
 let asset=AVURLAsset(url:filmURL)
 if let track=asset.tracks(withMediaType:.video).first {
  let reader=try AVAssetReader(asset:asset)
  let output=AVAssetReaderTrackOutput(track:track,outputSettings:[kCVPixelBufferPixelFormatTypeKey as String:kCVPixelFormatType_32BGRA])
  output.alwaysCopiesSampleData=false
  reader.add(output)
  guard reader.startReading() else {throw reader.error ?? NSError(domain:"film",code:1)}
  let filmPipeline=try EnhancementPipeline(),filmID=UUID()
  var index=0
  while let sample=output.copyNextSampleBuffer() {
   if let buffer=CMSampleBufferGetImageBuffer(sample),index>=22 && index<=24 {
    // Fixtures are generated SDR; tag the fixture buffer explicitly rather than weakening production gates.
    CVBufferSetAttachment(buffer,kCVImageBufferColorPrimariesKey,kCVImageBufferColorPrimaries_ITU_R_709_2,.shouldPropagate)
    CVBufferSetAttachment(buffer,kCVImageBufferTransferFunctionKey,kCVImageBufferTransferFunction_sRGB,.shouldPropagate)
    let pts=CMSampleBufferGetPresentationTimeStamp(sample)
    let frame=try filmPipeline.process(buffer,mode:.restoration,time:pts,streamID:filmID,resolution:.source)
    if index==24 {
     try save(CIImage(cvPixelBuffer:buffer),"film-source-pts1000000")
     try save(CIImage(mtlTexture:frame.texture,options:[.colorSpace:filmPipeline.colorSpace])!,"film-restored-pts1000000")
     film=["source":filmURL.path,"pts":pts.seconds,"mode":frame.mode,"used_temporal_history":frame.usedTemporalHistory,"width":frame.width,"height":frame.height,"scope":"Same decoded source PTS and actual restoration output; not interpolation or clean-reference PSNR."]
     check("film source and enhanced evidence share PTS and temporal history",abs(pts.seconds-1)<0.001 && frame.usedTemporalHistory,film)
    }
   }
   index+=1;if index>24 {reader.cancelReading();break}
  }
 }
}
let sorted=times.sorted()
let report:[String:Any]=["film":film,"checks":checks,"passed":checks.allSatisfy{$0["passed"] as? Bool == true},"steady_ms":times,"steady_mean_ms":times.reduce(0,+)/Double(times.count),"steady_p95_ms":sorted[Int(Double(sorted.count-1)*0.95)],"generated_frames":generated,"grid_times":all.map{$0.time},"scope":"Real production helper, 640x360 original enhancement, one second synthetic24fps source; actual FRC/output GPU completion; no AVPlayer scheduling proof."]
try JSONSerialization.data(withJSONObject:report,options:[.prettyPrinted,.sortedKeys]).write(to:URL(fileURLWithPath:reportPath))
if !(checks.allSatisfy{$0["passed"] as? Bool == true}) {exit(1)}
