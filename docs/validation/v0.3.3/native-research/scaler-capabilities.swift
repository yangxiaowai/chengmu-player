import Foundation
import Metal
import MetalFX
import MetalPerformanceShaders
let device=MTLCreateSystemDefaultDevice()!
var rows:[[String:Any]]=[]
for (format,name,mode) in [(MTLPixelFormat.bgra8Unorm,"bgra8Unorm",MTLFXSpatialScalerColorProcessingMode.perceptual),(.bgra8Unorm_srgb,"bgra8Unorm_srgb",.perceptual),(.rgba16Float,"rgba16Float",.linear),(.rgba16Float,"rgba16Float",.perceptual)] {
 let d=MTLFXSpatialScalerDescriptor();d.inputWidth=1920;d.inputHeight=1080;d.outputWidth=3840;d.outputHeight=2160;d.colorTextureFormat=format;d.outputTextureFormat=format;d.colorProcessingMode=mode
 let scaler=d.makeSpatialScaler(device:device)
 rows.append(["format":name,"mode":mode.rawValue,"configuration_created":scaler != nil,"input_usage_bits":scaler?.colorTextureUsage.rawValue ?? 0,"output_usage_bits":scaler?.outputTextureUsage.rawValue ?? 0])
}
let data:[String:Any] = ["device":device.name,"os":ProcessInfo.processInfo.operatingSystemVersionString,"spatial_supported":MTLFXSpatialScalerDescriptor.supportsDevice(device),"input":[1920,1080],"output":[3840,2160],"configurations":rows,"scope":"Read configuration/capability only. No GPU command encoded or committed. No quality or performance result."]
print(String(data:try JSONSerialization.data(withJSONObject:data,options:[.prettyPrinted,.sortedKeys]),encoding:.utf8)!)
