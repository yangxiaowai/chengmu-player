import Foundation
import VideoToolbox
func four(_ x:UInt32)->String {String(bytes:[UInt8((x>>24)&255),UInt8((x>>16)&255),UInt8((x>>8)&255),UInt8(x&255)],encoding:.ascii) ?? "\(x)"}
var rows:[[String:Any]]=[]
for (w,h) in [(640,360),(1280,720),(1920,1080),(3840,2160)] {
 for n in [1,2,3] {
 var row:[String:Any]=["size":[w,h],"n":n]
 if let c=VTLowLatencyFrameInterpolationConfiguration(frameWidth:w,frameHeight:h,numberOfInterpolatedFrames:n) {row["valid"]=true;row["formats"]=c.supportedPixelFormats.map(four);row["source"]=String(describing:c.sourcePixelBufferAttributes);row["destination"]=String(describing:c.destinationPixelBufferAttributes)}else{row["valid"]=false}
 rows.append(row)
 }
}
let report:[String:Any]=["supported":VTLowLatencyFrameInterpolationConfiguration.isSupported,"max_dim1":VTLowLatencyFrameInterpolationConfiguration.maximumDimension(forSpatialScaleFactor:1) ?? -1,"max_pixels1":VTLowLatencyFrameInterpolationConfiguration.maximumPixelCount(forSpatialScaleFactor:1) ?? -1,"max_dim2":VTLowLatencyFrameInterpolationConfiguration.maximumDimension(forSpatialScaleFactor:2) ?? -1,"max_pixels2":VTLowLatencyFrameInterpolationConfiguration.maximumPixelCount(forSpatialScaleFactor:2) ?? -1,"rows":rows]
let data=try JSONSerialization.data(withJSONObject:report,options:[.prettyPrinted,.sortedKeys]);try data.write(to:URL(fileURLWithPath:".build/frame-rate-probe/low-capabilities.json"));print(String(data:data,encoding:.utf8)!)
