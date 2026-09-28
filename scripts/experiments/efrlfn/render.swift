// Render only SDR RGB fixtures; compare against the original FP32 reference.
import Foundation
import CoreML
import CoreImage
import CoreVideo
import Metal
import QuartzCore
guard CommandLine.arguments.count>=4 else {
 fputs("Usage: render MODEL.mlpackage OUTPUT_DIRECTORY INPUT.png [INPUT2.png ...]\n",stderr)
 exit(2)
}
let outputDirectory=URL(fileURLWithPath:CommandLine.arguments[2],isDirectory:true)
try FileManager.default.createDirectory(at:outputDirectory,withIntermediateDirectories:true)
let modelURL=URL(fileURLWithPath:CommandLine.arguments[1])
let compiled=try MLModel.compileModel(at:modelURL)
let configuration=MLModelConfiguration();configuration.computeUnits = .all
let model=try MLModel(contentsOf:compiled,configuration:configuration)
let srgb=CGColorSpace(name:CGColorSpace.sRGB)!
let context=CIContext(mtlDevice:MTLCreateSystemDefaultDevice()!,options:[.workingColorSpace:CGColorSpace(name:CGColorSpace.extendedLinearSRGB)!, .cacheIntermediates:false])
for path in CommandLine.arguments.dropFirst(3) {
 let url=URL(fileURLWithPath:path)
 let image=CIImage(contentsOf:url, options:[.colorSpace:srgb])!
 let w=Int(image.extent.width),h=Int(image.extent.height)
 var buffer:CVPixelBuffer?
 CVPixelBufferCreate(nil,w,h,kCVPixelFormatType_32BGRA,[kCVPixelBufferIOSurfacePropertiesKey as String:[:],kCVPixelBufferMetalCompatibilityKey as String:true] as CFDictionary,&buffer)
 CVBufferSetAttachment(buffer!,kCVImageBufferCGColorSpaceKey,srgb,.shouldPropagate)
 CVBufferSetAttachment(buffer!,kCVImageBufferColorPrimariesKey,kCVImageBufferColorPrimaries_ITU_R_709_2,.shouldPropagate)
 CVBufferSetAttachment(buffer!,kCVImageBufferTransferFunctionKey,kCVImageBufferTransferFunction_sRGB,.shouldPropagate)
 context.render(image,to:buffer!,bounds:image.extent,colorSpace:srgb)
 let input=try MLDictionaryFeatureProvider(dictionary:["image":MLFeatureValue(pixelBuffer:buffer!)])
 let result=try model.prediction(from:input)
 let output=result.featureValue(for:"restored")!.imageBufferValue!
 let restored=CIImage(cvPixelBuffer:output,options:[.colorSpace:srgb])
 let outputURL=outputDirectory.appendingPathComponent(url.deletingPathExtension().lastPathComponent+"-coreml.png")
 try context.writePNGRepresentation(of:restored,to:outputURL,format:.RGBA8,colorSpace:srgb)
 print(outputURL.path)
}
