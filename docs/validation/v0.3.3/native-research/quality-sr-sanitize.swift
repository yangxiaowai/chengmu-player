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
 for index in 0..<1 {
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
  CVPixelBufferLockBaseAddress(dest,.readOnly)
  let pointer=CVPixelBufferGetBaseAddress(dest)!.assumingMemoryBound(to:Float16.self), stride=CVPixelBufferGetBytesPerRow(dest)/2
  var mins=[Float](repeating:Float.greatestFiniteMagnitude,count:4),maxs=[Float](repeating:-Float.greatestFiniteMagnitude,count:4)
  for y in Swift.stride(from:0,to:outH,by:16){for x in Swift.stride(from:0,to:outW,by:16){for c in 0..<4{let value=Float(pointer[y*stride+x*4+c]);mins[c]=min(mins[c],value);maxs[c]=max(maxs[c],value)}}}
  let corner=(0..<4).map{Float(pointer[(outH-24)*stride+(outW-24)*4+$0])}
  let bits=(0..<16).map{String(pointer[$0].bitPattern,radix:16)}
  let lockInfo:[String:Any]=["row_bytes":CVPixelBufferGetBytesPerRow(dest),"size_bytes":CVPixelBufferGetDataSize(dest),"plane_count":CVPixelBufferGetPlaneCount(dest),"bits_first_16":bits]
  func safe(_ values:[Float])->[String]{values.map{String($0)}}
  CVPixelBufferUnlockBaseAddress(dest,.readOnly)
  CVPixelBufferLockBaseAddress(dest,[])
  let alphaPointer=CVPixelBufferGetBaseAddress(dest)!.assumingMemoryBound(to:Float16.self)
  for y in 0..<outH {for x in 0..<outW {alphaPointer[y*stride+x*4+3]=Float16(1)}}
  CVPixelBufferUnlockBaseAddress(dest,[])
  var thumbnails:[[String:Any]]=[]
  for forced in [false,true] {
   var candidate=CIImage(cvPixelBuffer:dest)
   if forced {candidate=candidate.applyingFilter("CIColorMatrix",parameters:["inputAVector":CIVector(x:0,y:0,z:0,w:0),"inputBiasVector":CIVector(x:0,y:0,z:0,w:1)])}
   var pixel=[UInt8](repeating:0,count:64*36*4)
   context.render(candidate.transformed(by:CGAffineTransform(scaleX:64.0/Double(outW),y:36.0/Double(outH))),toBitmap:&pixel,rowBytes:64*4,bounds:CGRect(x:0,y:0,width:64,height:36),format:.RGBA8,colorSpace:cs)
   thumbnails.append(["force_alpha_one":forced,"rgb_max":pixel.enumerated().filter{$0.offset%4 != 3}.map{$0.element}.max() ?? 0,"alpha_min":Swift.stride(from:3,to:pixel.count,by:4).map{pixel[$0]}.min() ?? 0])
  }
  rows.append(["frame":index,"raw_output_format":CVPixelBufferGetPixelFormatType(dest),"source_attributes":String(describing:config.sourcePixelBufferAttributes),"destination_attributes":String(describing:config.destinationPixelBufferAttributes),"layout":lockInfo,"raw_min":safe(mins),"raw_max":safe(maxs),"raw_corner_rgba":safe(corner),"thumbnail_after_raw_alpha_sanitize":thumbnails])
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
 return ["input":[w,h],"native_output":[outW,outH],"setup_ms":setupMS,"frames":rows]

}
var reports:[[String:Any]]=[]
if #available(macOS 26.0,*) {
 for (w,h) in [(640,360)] {
  do{reports.append(try run(w:w,h:h))}catch{reports.append(["input":[w,h],"error":String(describing:error)])}
  let data:[String:Any]=["device":device.name,"scope":"Synthetic SDR frame processing with native 4x quality model; waits completed callback and final GPU texture. Includes input render and positive-kernel downscale when native output exceeds4K. No decoding or presentation.","results":reports]
  try JSONSerialization.data(withJSONObject:data,options:[.prettyPrinted,.sortedKeys]).write(to:URL(fileURLWithPath:".build/native-optimization-probe/quality-sr-sanitize-results.json"))
 }

}
try JSONSerialization.data(withJSONObject:["device":device.name,"scope":"Native quality4x; first+3 sequential frames; no model download. GPU completed output, no playback/sync/quality claim.","results":reports],options:[.prettyPrinted,.sortedKeys]).write(to:URL(fileURLWithPath:".build/native-optimization-probe/quality-sr-sanitize-results.json"))
