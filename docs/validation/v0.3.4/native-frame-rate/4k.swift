import Foundation
import CoreImage
import CoreVideo
import CoreMedia
import VideoToolbox
import Metal
import QuartzCore

let device=MTLCreateSystemDefaultDevice()!, cs=CGColorSpace(name:CGColorSpace.sRGB)!
let context=CIContext(mtlDevice:device,options:[.cacheIntermediates:false,.workingColorSpace:CGColorSpace(name:CGColorSpace.extendedLinearSRGB)!])
func allocate(_ w:Int,_ h:Int)throws->CVPixelBuffer {
 var output:CVPixelBuffer?
 let attributes:[String:Any]=[kCVPixelBufferIOSurfacePropertiesKey as String:[:],kCVPixelBufferMetalCompatibilityKey as String:true]
 guard CVPixelBufferCreate(nil,w,h,kCVPixelFormatType_64RGBAHalf,attributes as CFDictionary,&output)==0,let output else {throw NSError(domain:"allocation",code:1)}
 CVBufferSetAttachment(output,kCVImageBufferColorPrimariesKey,kCVImageBufferColorPrimaries_ITU_R_709_2,.shouldPropagate)
 CVBufferSetAttachment(output,kCVImageBufferTransferFunctionKey,kCVImageBufferTransferFunction_sRGB,.shouldPropagate)
 return output
}
func fixture(_ w:Int,_ h:Int,position:Double)->CIImage {
 let bounds=CGRect(x:0,y:0,width:w,height:h),shift=Double(w)/40*position
 let base=CIImage(color:CIColor(red:0.08,green:0.08,blue:0.08)).cropped(to:bounds)
 let rect=CGRect(x:Double(w)/3+shift,y:Double(h)/3,width:Double(w)/5,height:Double(h)/3)
 let patch=CIFilter(name:"CICheckerboardGenerator",parameters:["inputWidth":Double(w)/80,"inputColor0":CIColor(red:0.75,green:0.75,blue:0.75),"inputColor1":CIColor(red:0.45,green:0.45,blue:0.45),"inputCenter":CIVector(x:shift,y:0)])!.outputImage!.cropped(to:rect)
 return patch.composited(over:base)
}
func bitmap(_ image:CIImage,w:Int,h:Int)->[UInt8] {
 var p=[UInt8](repeating:0,count:w*h*4)
 context.render(image,toBitmap:&p,rowBytes:w*4,bounds:CGRect(x:0,y:0,width:w,height:h),format:.RGBA8,colorSpace:cs)
 return p
}
func sanitize(_ buffer:CVPixelBuffer,w:Int,h:Int)->[String:Any] {
 CVPixelBufferLockBaseAddress(buffer,[])
 let p=CVPixelBufferGetBaseAddress(buffer)!.assumingMemoryBound(to:Float16.self),row=CVPixelBufferGetBytesPerRow(buffer)/2
 var nanAlpha=0,nanRGB=0
 for y in 0..<h {for x in 0..<w {let i=y*row+x*4;for c in 0..<3 {if !p[i+c].isFinite {nanRGB+=1}};if !p[i+3].isFinite {nanAlpha+=1};p[i+3]=1}}
 CVPixelBufferUnlockBaseAddress(buffer,[])
 return ["nonfinite_rgb":nanRGB,"nonfinite_alpha":nanAlpha,"alpha_diagnostic_repaired":true]
}
func score(_ a:[UInt8],_ b:[UInt8],w:Int,h:Int)->Double {
 var e=0.0,n=0
 for y in h/3-8..<h*2/3+8 {for x in w/4..<w*3/4 {let i=(y*w+x)*4,d=Double(a[i])-Double(b[i]);e+=d*d;n+=1}}
 return e/Double(n)
}
func centroid(_ p:[UInt8],w:Int,h:Int)->Double {
 var sum=0.0,count=0.0
 for y in h/3+8..<h*2/3-8 {for x in 0..<w {if p[(y*w+x)*4]>80 {sum+=Double(x);count+=1}}}
 return sum/max(1,count)
}
func run(w:Int,h:Int,pairs:Int)throws->[String:Any] {
 guard let config=VTFrameRateConversionConfiguration(frameWidth:w,frameHeight:h,usePrecomputedFlow:false,qualityPrioritization:.normal,revision:.revision1) else {throw NSError(domain:"config",code:1)}
 let processor=VTFrameProcessor(),start=CACurrentMediaTime();try processor.startSession(configuration:config)
 let setup=(CACurrentMediaTime()-start)*1000
 defer {processor.endSession()}
 var frames:[VTFrameProcessorFrame]=[]
 for index in 0...pairs {
 let buffer=try allocate(w,h);context.render(fixture(w,h,position:Double(index)),to:buffer,bounds:CGRect(x:0,y:0,width:w,height:h),colorSpace:cs)
 frames.append(VTFrameProcessorFrame(buffer:buffer,presentationTimeStamp:CMTime(value:Int64(index),timescale:24))!)
 }
 var rows:[[String:Any]]=[]
 for index in 0..<pairs {
  let phases:[Float]=index%2==0 ? [0.4,0.8]:[0.2,0.6]
  let buffers=try phases.map{_ in try allocate(w,h)}
  let outputs=zip(buffers,phases).map{VTFrameProcessorFrame(buffer:$0.0,presentationTimeStamp:CMTime(seconds:(Double(index)+Double($0.1))/24,preferredTimescale:600))!}
  let p=VTFrameRateConversionParameters(sourceFrame:frames[index],nextFrame:frames[index+1],opticalFlow:nil,interpolationPhase:phases,submissionMode:index==0 ? .random:.sequential,destinationFrames:outputs)!
  let sem=DispatchSemaphore(value:0);var error:Error?
  let t=CACurrentMediaTime()
  processor.process(parameters:p){_,e in error=e;sem.signal()};sem.wait()
  let ms=(CACurrentMediaTime()-t)*1000
  if let error {throw error}
  var row:[String:Any]=["pair":index,"phases":phases,"callback_completed_ms":ms,"generated_frames":outputs.count]
  if index==min(2,pairs-1) {
    let alpha=sanitize(buffers[0],w:w,h:h),a=bitmap(CIImage(cvPixelBuffer:buffers[0]),w:w,h:h)
    let left=bitmap(fixture(w,h,position:Double(index)),w:w,h:h),right=bitmap(fixture(w,h,position:Double(index+1)),w:w,h:h),truth=bitmap(fixture(w,h,position:Double(index)+Double(phases[0])),w:w,h:h)
    let phase=Double(phases[0]);let blend=zip(left,right).map{UInt8(max(0,min(255,Int((Double($0.0)*(1-phase)+Double($0.1)*phase).rounded()))))}
    row["pixel_quality"]=["alpha":alpha,"roi_mse_interpolation":score(a,truth,w:w,h:h),"roi_mse_duplicate_left":score(left,truth,w:w,h:h),"roi_mse_duplicate_right":score(right,truth,w:w,h:h),"roi_mse_blend":score(blend,truth,w:w,h:h),"centroid_output":centroid(a,w:w,h:h),"centroid_expected":centroid(truth,w:w,h:h),"centroid_left":centroid(left,w:w,h:h),"centroid_right":centroid(right,w:w,h:h),"identical_to_left":a==left,"identical_to_blend":a==blend]
    try context.writePNGRepresentation(of:CIImage(cvPixelBuffer:buffers[0]),to:URL(fileURLWithPath:".build/frame-rate-probe/interpolated-\(w).png"),format:.RGBA8,colorSpace:cs)
    try context.writePNGRepresentation(of:fixture(w,h,position:Double(index)+Double(phases[0])),to:URL(fileURLWithPath:".build/frame-rate-probe/expected-\(w).png"),format:.RGBA8,colorSpace:cs)
  }
  rows.append(row)
  print("\(w)x\(h) pair\(index) two phases completed \(ms) ms")
 }
 let warm=rows.dropFirst().compactMap{$0["callback_completed_ms"] as? Double}.sorted()
 return ["size":[w,h],"setup_ms":setup,"pairs":rows,"warm_mean_pair_ms":warm.reduce(0,+)/Double(warm.count),"warm_p95_pair_ms":warm[Int(Double(warm.count-1)*0.95)],"scope":"Prepared source RGBAHalf; VT callback-completed including optical flow and two synthesized phases. Excludes input conversion, pixel sanitization/readback, display/decoding/DNR. source 24fps, future1frame." ]
}
var results:[[String:Any]]=[]
for (w,h,count) in [(3840,2160,4)] {
 do{results.append(try run(w:w,h:h,pairs:count))}catch{results.append(["size":[w,h],"error":String(describing:error)])}
 try JSONSerialization.data(withJSONObject:["device":device.name,"results":results],options:[.prettyPrinted,.sortedKeys]).write(to:URL(fileURLWithPath:".build/frame-rate-probe/4k-results.json"))
}
