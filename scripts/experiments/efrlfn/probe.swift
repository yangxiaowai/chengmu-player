// Synthetic repeatability and complete-frame performance probe; no playback/FPS guarantee.
import Foundation
import CoreML
import CoreImage
import CoreVideo
import Metal
import QuartzCore
import CryptoKit

struct ProbeError: Error, CustomStringConvertible { let description: String }
guard CommandLine.arguments.count >= 3 else {
    fputs("Usage: probe MODEL.mlpackage OUTPUT_DIRECTORY [all|gpu] [WIDTHxHEIGHT]\n", stderr)
    exit(2)
}
let directory = URL(fileURLWithPath: CommandLine.arguments[2], isDirectory: true)
try FileManager.default.createDirectory(at:directory,withIntermediateDirectories:true)
let sourceURL = URL(fileURLWithPath: CommandLine.arguments[1])
let unitName = CommandLine.arguments.count > 3 ? CommandLine.arguments[3] : "all"
guard ["all","gpu"].contains(unitName) else {throw ProbeError(description:"Compute unit must be all or gpu")}
let configuration = MLModelConfiguration()
configuration.computeUnits = unitName == "gpu" ? .cpuAndGPU : .all
let loadStart = CACurrentMediaTime()
let compiledURL = try MLModel.compileModel(at: sourceURL)
let model = try MLModel(contentsOf: compiledURL, configuration: configuration)
let loadMS = (CACurrentMediaTime()-loadStart)*1000
let device = MTLCreateSystemDefaultDevice()!
let queue = device.makeCommandQueue()!
let srgb = CGColorSpace(name: CGColorSpace.sRGB)!
let context = CIContext(mtlDevice: device, options: [.cacheIntermediates:false, .workingColorSpace:CGColorSpace(name: CGColorSpace.extendedLinearSRGB)!])
func makeBuffer(_ width: Int, _ height: Int) throws -> CVPixelBuffer {
 var buffer: CVPixelBuffer?
 let attributes: [String:Any] = [kCVPixelBufferIOSurfacePropertiesKey as String:[:], kCVPixelBufferMetalCompatibilityKey as String:true]
 let status = CVPixelBufferCreate(nil,width,height,kCVPixelFormatType_32BGRA,attributes as CFDictionary,&buffer)
 guard status == kCVReturnSuccess, let buffer else {throw ProbeError(description:"buffer \(status)")}
 CVBufferSetAttachment(buffer,kCVImageBufferCGColorSpaceKey,srgb,.shouldPropagate)
 CVBufferSetAttachment(buffer,kCVImageBufferColorPrimariesKey,kCVImageBufferColorPrimaries_ITU_R_709_2,.shouldPropagate)
 CVBufferSetAttachment(buffer,kCVImageBufferTransferFunctionKey,kCVImageBufferTransferFunction_sRGB,.shouldPropagate)
 return buffer
}
func fixture(_ width:Int,_ height:Int) -> CIImage {
 let r = CGRect(x:0,y:0,width:width,height:height)
 let gradient = CIFilter(name:"CILinearGradient",parameters:["inputPoint0":CIVector(x:0,y:0),"inputPoint1":CIVector(x:CGFloat(width),y:CGFloat(height)),"inputColor0":CIColor(red:0.04,green:0.07,blue:0.1),"inputColor1":CIColor(red:0.78,green:0.65,blue:0.32)])!.outputImage!.cropped(to:r)
 let checker = CIFilter(name:"CICheckerboardGenerator",parameters:["inputWidth":8.0,"inputColor0":CIColor(red:0.2,green:0.3,blue:0.5),"inputColor1":CIColor(red:0.6,green:0.7,blue:0.4)])!.outputImage!.cropped(to:CGRect(x:0,y:0,width:width/3,height:height/3))
 return checker.composited(over:gradient)
}
func digest(_ buffer:CVPixelBuffer) -> String {
 CVPixelBufferLockBaseAddress(buffer,.readOnly);defer{CVPixelBufferUnlockBaseAddress(buffer,.readOnly)}
 let width=CVPixelBufferGetWidth(buffer),height=CVPixelBufferGetHeight(buffer),stride=CVPixelBufferGetBytesPerRow(buffer)
 var hasher = SHA256()
 for y in 0..<height {hasher.update(data:Data(bytes:CVPixelBufferGetBaseAddress(buffer)!.advanced(by:y*stride),count:width*4))}
 return hasher.finalize().map{String(format:"%02x",$0)}.joined()
}
var reports:[[String:Any]]=[]
var dimensions = [(64,64),(480,200),(960,400),(1280,720),(1920,1080)]
if CommandLine.arguments.count > 4 {
 let size=CommandLine.arguments[4].split(separator:"x").compactMap {Int($0)}
 guard size.count==2,size[0]>=64,size[0]<=1920,size[1]>=64,size[1]<=1080 else {throw ProbeError(description:"Expected WIDTHxHEIGHT within 64..1920 by 64..1080")}
 dimensions=[(size[0],size[1])]
}
for (width,height) in dimensions {
 try autoreleasepool {
  let buffer=try makeBuffer(width,height)
  let image=fixture(width,height)
  let description = MTLTextureDescriptor.texture2DDescriptor(pixelFormat:.bgra8Unorm,width:width*2,height:height*2,mipmapped:false)
  description.usage=[.shaderRead,.shaderWrite,.renderTarget]
  guard let texture=device.makeTexture(descriptor:description) else {throw ProbeError(description:"texture")}
  var times:[Double]=[],modelTimes:[Double]=[],hashes:[String]=[]
  for index in 0..<5 {
   try autoreleasepool {
    let start=CACurrentMediaTime()
    context.render(image,to:buffer,bounds:image.extent,colorSpace:srgb)
    let input=try MLDictionaryFeatureProvider(dictionary:["image":MLFeatureValue(pixelBuffer:buffer)])
    let predictionStart=CACurrentMediaTime()
    let result=try model.prediction(from:input)
    let predictionMS=(CACurrentMediaTime()-predictionStart)*1000
    guard let output=result.featureValue(for:"restored")?.imageBufferValue else {throw ProbeError(description:"no image output")}
    guard CVPixelBufferGetWidth(output)==width*2,CVPixelBufferGetHeight(output)==height*2 else {throw ProbeError(description:"wrong output size")}
    let outImage=CIImage(cvPixelBuffer:output,options:[.colorSpace:srgb])
    let command=queue.makeCommandBuffer()!
    context.render(outImage,to:texture,commandBuffer:command,bounds:outImage.extent,colorSpace:srgb)
    command.commit();command.waitUntilCompleted()
    guard command.status == .completed else {throw ProbeError(description:command.error?.localizedDescription ?? "GPU completion failed")}
    let totalMS=(CACurrentMediaTime()-start)*1000
    times.append(totalMS);modelTimes.append(predictionMS)
    if index==0 || index==4 {hashes.append(digest(output))}
    if index==0 && width==64 {
      try context.writePNGRepresentation(of:CIImage(cvPixelBuffer:buffer,options:[.colorSpace:srgb]),to:directory.appendingPathComponent("input64-\(unitName).png"),format:.RGBA8,colorSpace:srgb)
      try context.writePNGRepresentation(of:outImage,to:directory.appendingPathComponent("output64-\(unitName).png"),format:.RGBA8,colorSpace:srgb)
    }
    print("\(unitName) \(width)x\(height) frame\(index) complete total=\(totalMS) model=\(predictionMS)")
    fflush(stdout)
   }
  }
  let warm=Array(times.dropFirst())
  reports.append(["input":[width,height],"output":[width*2,height*2],"completed_frames":times.count,"total_ms":times,"model_ms":modelTimes,"warm_mean_ms":warm.reduce(0,+)/Double(warm.count),"warm_max_ms":warm.max()!,"output_first_last_sha256":hashes,"repeat_identical":hashes[0]==hashes[1]])
 }
}
let report:[String:Any] = ["device":device.name,"units":unitName,"compile_and_load_ms":loadMS,"scope":"5 repeated synthetic SDR frames per size; CI sRGB input render + synchronous Core ML prediction + completed Metal output render; no decode/audio/playback. No FPS claim.","input_description":String(describing:model.modelDescription.inputDescriptionsByName),"output_description":String(describing:model.modelDescription.outputDescriptionsByName),"results":reports]
try JSONSerialization.data(withJSONObject:report,options:[.prettyPrinted,.sortedKeys]).write(to:directory.appendingPathComponent("report-\(unitName).json"))
