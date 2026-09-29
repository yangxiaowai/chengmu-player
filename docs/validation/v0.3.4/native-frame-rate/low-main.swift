import Foundation
import CoreImage
import CoreVideo
import CoreMedia
import VideoToolbox
import Metal
import QuartzCore

let device=MTLCreateSystemDefaultDevice()!, cs=CGColorSpace(name:CGColorSpace.sRGB)!
let context=CIContext(mtlDevice:device,options:[.cacheIntermediates:false,.workingColorSpace:CGColorSpace(name:CGColorSpace.extendedLinearSRGB)!])
var activeAttributes:[String:Any]=[:]
func allocate(_ w:Int,_ h:Int)throws->CVPixelBuffer {
 var output:CVPixelBuffer?
 var attributes=activeAttributes;attributes[kCVPixelBufferIOSurfacePropertiesKey as String]=[:];attributes[kCVPixelBufferMetalCompatibilityKey as String]=true
 guard CVPixelBufferCreate(nil,w,h,kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange,attributes as CFDictionary,&output)==0,let output else {throw NSError(domain:"allocation",code:1)}
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

func fill(_ buffer:CVPixelBuffer,image:CIImage,w:Int,h:Int) {
 let rgba=bitmap(image,w:w,h:h)
 CVPixelBufferLockBaseAddress(buffer,[])
 let y=CVPixelBufferGetBaseAddressOfPlane(buffer,0)!.assumingMemoryBound(to:UInt8.self),ys=CVPixelBufferGetBytesPerRowOfPlane(buffer,0)
 let uv=CVPixelBufferGetBaseAddressOfPlane(buffer,1)!.assumingMemoryBound(to:UInt8.self),uvs=CVPixelBufferGetBytesPerRowOfPlane(buffer,1)
 for row in 0..<h {for x in 0..<w {y[row*ys+x]=UInt8((Double(rgba[(row*w+x)*4])*219/255+16).rounded())}}
 for row in 0..<h/2 {for x in 0..<w {uv[row*uvs+x]=128}}
 CVPixelBufferUnlockBaseAddress(buffer,[])
 CVPixelBufferFillExtendedPixels(buffer)
 CVBufferSetAttachment(buffer,kCVImageBufferYCbCrMatrixKey,kCVImageBufferYCbCrMatrix_ITU_R_709_2,.shouldPropagate)
}
func run(w:Int,h:Int,n:Int,phases:[Float])throws->[String:Any] {
 guard let config=VTLowLatencyFrameInterpolationConfiguration(frameWidth:w,frameHeight:h,numberOfInterpolatedFrames:n) else {throw NSError(domain:"config",code:1)}
 let processor=VTFrameProcessor(),queue=device.makeCommandQueue()!,start=CACurrentMediaTime();try processor.startSession(configuration:config)
 let setup=(CACurrentMediaTime()-start)*1000
 defer {processor.endSession()}
 activeAttributes=config.sourcePixelBufferAttributes
 var frames:[VTFrameProcessorFrame]=[]
 for index in 0...5 {
  let buffer=try allocate(w,h);fill(buffer,image:fixture(w,h,position:Double(index)),w:w,h:h)
  frames.append(VTFrameProcessorFrame(buffer:buffer,presentationTimeStamp:CMTime(value:Int64(index),timescale:24))!)
 }
 var rows:[[String:Any]]=[]
 for index in 0..<5 {
  activeAttributes=config.destinationPixelBufferAttributes
  let buffers=try phases.map{_ in try allocate(w,h)}
  let outputs=zip(buffers,phases).map{VTFrameProcessorFrame(buffer:$0.0,presentationTimeStamp:CMTime(seconds:(Double(index)+Double($0.1))/24,preferredTimescale:600))!}
  guard let p=VTLowLatencyFrameInterpolationParameters(sourceFrame:frames[index+1],previousFrame:frames[index],interpolationPhase:phases,destinationFrames:outputs) else {throw NSError(domain:"parameters",code:1)}
  let t=CACurrentMediaTime(),command=queue.makeCommandBuffer()!
  processor.process(with:command,parameters:p);command.commit();command.waitUntilCompleted()
  let ms=(CACurrentMediaTime()-t)*1000
  guard command.status == .completed else {throw command.error ?? NSError(domain:"gpu",code:1)}
  var row:[String:Any]=["pair":index,"phases":phases,"completed_ms":ms,"gpu_ms":(command.gpuEndTime-command.gpuStartTime)*1000]
  if index==2 {
   var quality:[[String:Any]]=[]
   for k in phases.indices {
    try context.writePNGRepresentation(of:CIImage(cvPixelBuffer:buffers[k]),to:URL(fileURLWithPath:".build/frame-rate-probe/low-\(w)-n\(n)-phase\(phases[k]).png"),format:.RGBA8,colorSpace:cs)
    let a=bitmap(CIImage(cvPixelBuffer:buffers[k]),w:w,h:h),left=bitmap(fixture(w,h,position:Double(index)),w:w,h:h),right=bitmap(fixture(w,h,position:Double(index+1)),w:w,h:h),truth=bitmap(fixture(w,h,position:Double(index)+Double(phases[k])),w:w,h:h)
    let phase=Double(phases[k]),blend=zip(left,right).map{UInt8(max(0,min(255,Int((Double($0.0)*(1-phase)+Double($0.1)*phase).rounded()))))}
    quality.append(["phase":phase,"roi_mse_interpolation":score(a,truth,w:w,h:h),"roi_mse_duplicate_left":score(left,truth,w:w,h:h),"roi_mse_blend":score(blend,truth,w:w,h:h),"centroid_output":centroid(a,w:w,h:h),"centroid_expected":centroid(truth,w:w,h:h),"actual_phase":(centroid(a,w:w,h:h)-centroid(left,w:w,h:h))/(Double(w)/40),"identical_to_left":a==left,"identical_to_blend":a==blend])
   }
   row["quality"]=quality
  }
  rows.append(row);print("LL \(w)x\(h) n\(n) pair\(index) \(ms) ms")
 }
 let warm=rows.dropFirst().compactMap{$0["completed_ms"] as? Double}.sorted()
 return ["size":[w,h],"n":n,"actual_config_n":config.numberOfInterpolatedFrames,"phases":phases,"setup_ms":setup,"pairs":rows,"warm_mean_pair_ms":warm.reduce(0,+)/Double(warm.count),"warm_p95_pair_ms":warm[Int(Double(warm.count-1)*0.95)]]
}
var results:[[String:Any]]=[]
for (w,h,n,phases) in [(640,360,1,[Float(0.5)]),(640,360,2,[Float(0.4),0.8]),(1280,720,2,[Float(0.4),0.8]),(1920,1080,1,[Float(0.5)]),(1920,1080,2,[Float(0.4),0.8])] {
 do{results.append(try run(w:w,h:h,n:n,phases:phases))}catch{results.append(["size":[w,h],"n":n,"error":String(describing:error)])}
 try JSONSerialization.data(withJSONObject:["device":device.name,"scope":"Low latency frame interpolation, grayscale 420v prepared inputs; completed GPU processing only, excludes conversion/readback/playback. Input pair previous/current still needs buffering to display intermediates in time order.","results":results],options:[.prettyPrinted,.sortedKeys]).write(to:URL(fileURLWithPath:".build/frame-rate-probe/low-results.json"))
}
