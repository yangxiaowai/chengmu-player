import Foundation
import VideoToolbox
if #available(macOS 26.0,*) {
 var r:[[String:Any]]=[]
 for (w,h) in [(640,360),(1280,720),(1920,1080)] {
  for factor in VTSuperResolutionScalerConfiguration.supportedScaleFactors {
   if let c=VTSuperResolutionScalerConfiguration(frameWidth:w,frameHeight:h,scaleFactor:factor,inputType:.video,usePrecomputedFlow:false,qualityPrioritization:.normal,revision:VTSuperResolutionScalerConfiguration.defaultRevision) {
    r.append(["input":[w,h],"factor":factor,"model_status":c.configurationModelStatus.rawValue,"model_percentage":c.configurationModelPercentageAvailable,"formats":c.supportedPixelFormats.map{String(format:"%08x",$0)}])
   }
  }
 }
 print(String(data:try! JSONSerialization.data(withJSONObject:r,options:[.prettyPrinted,.sortedKeys]),encoding:.utf8)!)
}
