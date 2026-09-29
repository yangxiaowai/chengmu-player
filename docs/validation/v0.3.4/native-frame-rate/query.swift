import Foundation
import VideoToolbox
func four(_ x:UInt32)->String {String(bytes:[UInt8((x>>24)&255),UInt8((x>>16)&255),UInt8((x>>8)&255),UInt8(x&255)],encoding:.ascii) ?? "\(x)"}
var rows:[[String:Any]]=[]
for (w,h) in [(64,64),(160,64),(256,128),(640,360),(1280,720),(1920,1080),(3840,2160),(8192,4320),(8193,4320)] {
 var row:[String:Any]=["size":[w,h]]
 if let c=VTFrameRateConversionConfiguration(frameWidth:w,frameHeight:h,usePrecomputedFlow:false,qualityPrioritization:.normal,revision:.revision1) {
 row["valid"]=true;row["formats"]=c.supportedPixelFormats.map(four);row["source"]=String(describing:c.sourcePixelBufferAttributes);row["destination"]=String(describing:c.destinationPixelBufferAttributes)
 }else {row["valid"]=false}
 rows.append(row)
}
let min=VTFrameRateConversionConfiguration.minimumDimensions,max=VTFrameRateConversionConfiguration.maximumDimensions
let report:[String:Any]=["supported":VTFrameRateConversionConfiguration.isSupported,"minimum":[min?.width ?? -1,min?.height ?? -1],"maximum":[max?.width ?? -1,max?.height ?? -1],"rows":rows]
let data=try JSONSerialization.data(withJSONObject:report,options:[.prettyPrinted,.sortedKeys]);try data.write(to:URL(fileURLWithPath:".build/frame-rate-probe/capabilities.json"));print(String(data:data,encoding:.utf8)!)
