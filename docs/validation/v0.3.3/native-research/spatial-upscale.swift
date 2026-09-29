import Foundation
import CoreImage
import Metal
import MetalFX
import MetalPerformanceShaders
import QuartzCore
let device=MTLCreateSystemDefaultDevice()!,queue=MTLCreateSystemDefaultDevice()!.makeCommandQueue()!
let ctx=CIContext(mtlDevice:device,options:[.cacheIntermediates:false]),srgb=CGColorSpace(name:CGColorSpace.sRGB)!,linear=CGColorSpace(name:CGColorSpace.extendedLinearSRGB)!
let w=1920,h=1080,ow=3840,oh=2160
var raw=[UInt8](repeating:255,count:w*h*4),seed:UInt64=9876
for y in 0..<h {for x in 0..<w {
 var v=x<w/2 ? 64:192
 if x>w/16 && x<w/3 && y<h/2 {
  seed=seed &* 6364136223846793005 &+ 1442695040888963407;v += Int((seed>>32)%17)-8
 }
 for c in 0..<3{raw[(y*w+x)*4+c]=UInt8(v)}
}}
let image=CIImage(bitmapData:Data(raw),bytesPerRow:w*4,size:CGSize(width:w,height:h),format:.RGBA8,colorSpace:srgb)
var rows:[[String:Any]]=[]
for kind in ["metalfx-perceptual","metalfx-linear","mps-lanczos","ci-bspline"] {
 let format:MTLPixelFormat=kind=="metalfx-perceptual" ? .bgra8Unorm_srgb:.rgba16Float
 let space=kind=="metalfx-perceptual" ? srgb:linear
 let desc=MTLTextureDescriptor.texture2DDescriptor(pixelFormat:format,width:w,height:h,mipmapped:false);desc.storageMode = .private;desc.usage=[.shaderRead,.shaderWrite,.renderTarget]
 let source=device.makeTexture(descriptor:desc)!
 desc.width=ow;desc.height=oh;let dest=device.makeTexture(descriptor:desc)!
 var scaler:MTLFXSpatialScaler?
 if kind.hasPrefix("metalfx") {let s=MTLFXSpatialScalerDescriptor();s.inputWidth=w;s.inputHeight=h;s.outputWidth=ow;s.outputHeight=oh;s.colorTextureFormat=format;s.outputTextureFormat=format;s.colorProcessingMode=kind=="metalfx-linear" ? .linear:.perceptual;scaler=s.makeSpatialScaler(device:device)!;scaler!.colorTexture=source;scaler!.outputTexture=dest;scaler!.inputContentWidth=w;scaler!.inputContentHeight=h}
 let lanczos=MPSImageLanczosScale(device:device)
 var walls:[Double]=[],gpu:[Double]=[]
 for _ in 0..<4 {
  let start=CACurrentMediaTime(),command=queue.makeCommandBuffer()!
  if kind=="ci-bspline" {
   let up=image.clampedToExtent().applyingFilter("CIBicubicScaleTransform",parameters:["inputScale":2.0,"inputAspectRatio":1.0,"inputB":1.0,"inputC":0.0]).cropped(to:CGRect(x:0,y:0,width:ow,height:oh))
   ctx.render(up,to:dest,commandBuffer:command,bounds:up.extent,colorSpace:space)
  }else{
   ctx.render(image,to:source,commandBuffer:command,bounds:image.extent,colorSpace:space)
   if let scaler {scaler.encode(commandBuffer:command)}else{lanczos.encode(commandBuffer:command,sourceTexture:source,destinationTexture:dest)}
  }
  command.commit();command.waitUntilCompleted()
  guard command.status == .completed else{fatalError(String(describing:command.error))}
  walls.append((CACurrentMediaTime()-start)*1000);gpu.append((command.gpuEndTime-command.gpuStartTime)*1000)
 }
 var out=[UInt8](repeating:0,count:ow*oh*4)
 ctx.render(CIImage(mtlTexture:dest,options:[.colorSpace:space])!,toBitmap:&out,rowBytes:ow*4,bounds:CGRect(x:0,y:0,width:ow,height:oh),format:.RGBA8,colorSpace:srgb)
 // Core Image's MTL import is vertically flipped. All measurements avoid deriving y-origin
 // from assumptions: edge spans full height; noise ROI is detected by inspecting both halves.
 var minEdge=255,maxEdge=0
 for y in stride(from:50,to:oh-50,by:200){for x in (ow/2-16)..<(ow/2+16){minEdge=min(minEdge,Int(out[(y*ow+x)*4]));maxEdge=max(maxEdge,Int(out[(y*ow+x)*4]))}}
 func roi(_ y0:Int,_ y1:Int)->Double {var e=0.0,n=0;for y in stride(from:y0,to:y1,by:3){for x in stride(from:ow/8,to:ow/3,by:3){let d=Double(out[(y*ow+x)*4])-64;e+=d*d;n+=1}};return e/Double(n)}
 let mse=max(roi(64,oh/3),roi(oh*2/3,oh-64))
 let l=Int(out[((oh/2)*ow+64)*4]),r=Int(out[((oh/2)*ow+ow-64)*4])
 rows.append(["method":kind,"first_completed_ms":walls[0],"warm_mean_completed_ms":walls.dropFirst().reduce(0,+)/3,"warm_gpu_mean_ms":gpu.dropFirst().reduce(0,+)/3,"edge_observed_range":[minEdge,maxEdge],"expected_plateaus":[64,192],"edge_overshoot_codevalues":max(0,max(64-minEdge,maxEdge-192)),"upscaled_flat_noise_mse":mse,"flat_readback_values":[l,r]])
}
print(String(data:try JSONSerialization.data(withJSONObject:["scope":"Synthetic grayscale step and independent flat noise,1080→4K,first+3warm. Completed GPU command including source conversion; does not include temporal DNR or playback. Not general image quality.","device":device.name,"results":rows],options:[.prettyPrinted,.sortedKeys]),encoding:.utf8)!)
