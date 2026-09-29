import Foundation
import CoreImage
import CoreVideo
import CoreMedia
import Metal
import VideoToolbox
import QuartzCore
struct Failure:Error {let message:String}
func alloc(_ attributes:[String:Any],w:Int,h:Int)throws->CVPixelBuffer {
 var attrs=attributes;attrs[kCVPixelBufferWidthKey as String]=w;attrs[kCVPixelBufferHeightKey as String]=h
 attrs[kCVPixelBufferIOSurfacePropertiesKey as String]=[:];attrs[kCVPixelBufferMetalCompatibilityKey as String]=true
 var pool:CVPixelBufferPool?,buffer:CVPixelBuffer?
 guard CVPixelBufferPoolCreate(nil,nil,attrs as CFDictionary,&pool)==0,let pool,CVPixelBufferPoolCreatePixelBuffer(nil,pool,&buffer)==0,let buffer else {throw Failure(message:"allocate \(w)x\(h)")}
 CVBufferSetAttachment(buffer,kCVImageBufferColorPrimariesKey,kCVImageBufferColorPrimaries_ITU_R_709_2,.shouldPropagate)
 CVBufferSetAttachment(buffer,kCVImageBufferTransferFunctionKey,kCVImageBufferTransferFunction_sRGB,.shouldPropagate)
 return buffer
}
let device=MTLCreateSystemDefaultDevice()!,queue=MTLCreateSystemDefaultDevice()!.makeCommandQueue()!,cs=CGColorSpace(name:CGColorSpace.sRGB)!
let context=CIContext(mtlDevice:device,options:[.cacheIntermediates:false,.workingColorSpace:CGColorSpace(name:CGColorSpace.extendedLinearSRGB)!])
@available(macOS 26.0,*)
func run(w:Int,h:Int)throws->[String:Any] {
 guard let config=VTSuperResolutionScalerConfiguration(frameWidth:w,frameHeight:h,scaleFactor:4,inputType:.video,usePrecomputedFlow:false,qualityPrioritization:.normal,revision:VTSuperResolutionScalerConfiguration.defaultRevision) else {throw Failure(message:"config")}
 guard config.configurationModelStatus == .ready else {throw Failure(message:"model not ready; no download requested")}
 let processor=VTFrameProcessor(),start=CACurrentMediaTime();try processor.startSession(configuration:config)
 let setupMS=(CACurrentMediaTime()-start)*1000
 defer{processor.endSession()}
 var previous:VTFrameProcessorFrame?,previousOutput:VTFrameProcessorFrame?
 var rows:[[String:Any]]=[]
 let outW=w*4,outH=h*4,targetW=min(outW,3840),targetH=min(outH,2160)
 let td=MTLTextureDescriptor.texture2DDescriptor(pixelFormat:.bgra8Unorm,width:targetW,height:targetH,mipmapped:false);td.usage=[.shaderRead,.shaderWrite,.renderTarget]
 let texture=device.makeTexture(descriptor:td)!
 for index in 0..<4 {
  let source=try alloc(config.sourcePixelBufferAttributes,w:w,h:h),dest=try alloc(config.destinationPixelBufferAttributes,w:outW,h:outH)
  let whole=CACurrentMediaTime()
  let base=CIImage(color:CIColor(red:0.12,green:0.18,blue:0.24)).cropped(to:CGRect(x:0,y:0,width:w,height:h))
  let checker=CIFilter(name:"CICheckerboardGenerator",parameters:["inputWidth":4.0])!.outputImage!.cropped(to:CGRect(x:20,y:20,width:w/3,height:h/4))
  let stripe=CIImage(color:CIColor(red:0.8,green:0.5,blue:0.2)).cropped(to:CGRect(x:w/2+index*4,y:h/3,width:50,height:h/3))
  let image=stripe.composited(over:checker.composited(over:base))
  context.render(image,to:source,bounds:image.extent,colorSpace:cs)
  let input=VTFrameProcessorFrame(buffer:source,presentationTimeStamp:CMTime(value:Int64(index),timescale:30))!,output=VTFrameProcessorFrame(buffer:dest,presentationTimeStamp:CMTime(value:Int64(index),timescale:30))!
  guard let params=VTSuperResolutionScalerParameters(sourceFrame:input,previousFrame:previous,previousOutputFrame:previousOutput,opticalFlow:nil,submissionMode:index==0 ? .random:.sequential,destinationFrame:output) else {throw Failure(message:"parameters")}
  let processStart=CACurrentMediaTime(),sem=DispatchSemaphore(value:0);var error:Error?
  processor.process(parameters:params){_,err in error=err;sem.signal()}
  sem.wait()
  if let error {throw error}
  let modelMS=(CACurrentMediaTime()-processStart)*1000
  var restored=CIImage(cvPixelBuffer:dest)
  if outW>3840 {restored=restored.clampedToExtent().applyingFilter("CIBicubicScaleTransform",parameters:["inputScale":Double(targetW)/Double(outW),"inputAspectRatio":1.0,"inputB":1.0,"inputC":0.0]).cropped(to:CGRect(x:0,y:0,width:targetW,height:targetH))}
  let renderStart=CACurrentMediaTime(),command=queue.makeCommandBuffer()!
  context.render(restored,to:texture,commandBuffer:command,bounds:CGRect(x:0,y:0,width:targetW,height:targetH),colorSpace:cs)
  command.commit();command.waitUntilCompleted()
  guard command.status == .completed else{throw Failure(message:"render failed")}
  let renderMS=(CACurrentMediaTime()-renderStart)*1000,totalMS=(CACurrentMediaTime()-whole)*1000
  rows.append(["frame":index,"native_model_completed_ms":modelMS,"final_texture_and_optional_downscale_ms":renderMS,"complete_input_to_texture_ms":totalMS])
  previous=input;previousOutput=output
  FileHandle.standardError.write(Data("\(w)x\(h) frame\(index): native \(modelMS) ms total \(totalMS) ms\n".utf8))
 }
 var sample=[UInt8](repeating:0,count:4)
 context.render(CIImage(mtlTexture:texture,options:[.colorSpace:cs])!,toBitmap:&sample,rowBytes:4,bounds:CGRect(x:targetW-24,y:targetH-24,width:1,height:1),format:.RGBA8,colorSpace:cs)
 return ["input":[w,h],"native_output":[outW,outH],"display_output":[targetW,targetH],"native_scale_factor":4,"setup_ms":setupMS,"frames":rows,"warm_mean_model_ms":rows.dropFirst().map{$0["native_model_completed_ms"] as! Double}.reduce(0,+)/3,"warm_mean_total_ms":rows.dropFirst().map{$0["complete_input_to_texture_ms"] as! Double}.reduce(0,+)/3,"last_background_rgba":sample]
}
var reports:[[String:Any]]=[]
if #available(macOS 26.0,*) {
 for (w,h) in [(640,360),(960,540),(1280,720)] {
  do{reports.append(try run(w:w,h:h))}catch{reports.append(["input":[w,h],"error":String(describing:error)])}
  let data:[String:Any]=["device":device.name,"scope":"Synthetic SDR frame processing with native 4x quality model; waits completed callback and final GPU texture. Includes input render and positive-kernel downscale when native output exceeds4K. No decoding or presentation.","results":reports]
  try JSONSerialization.data(withJSONObject:data,options:[.prettyPrinted,.sortedKeys]).write(to:URL(fileURLWithPath:".build/native-optimization-probe/quality-sr-results.json"))
 }
 if let last=reports.last,let warm=last["warm_mean_total_ms"] as? Double,warm<30 {
  do{reports.append(try run(w:1920,h:1080))}catch{reports.append(["input":[1920,1080],"error":String(describing:error)])}
 }else{reports.append(["input":[1920,1080],"skipped":"Earlier full pipeline warm mean exceeds30ms or failed; no 8K workload initiated"])}
}
try JSONSerialization.data(withJSONObject:["device":device.name,"scope":"Native quality4x; first+3 sequential frames; no model download. GPU completed output, no playback/sync/quality claim.","results":reports],options:[.prettyPrinted,.sortedKeys]).write(to:URL(fileURLWithPath:".build/native-optimization-probe/quality-sr-results.json"))
