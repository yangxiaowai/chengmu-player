import Foundation
import VideoToolbox
if #available(macOS 26.0,*) {
 for factor in [2,4] {
  let c=VTSuperResolutionScalerConfiguration(frameWidth:1920,frameHeight:1080,scaleFactor:factor,inputType:.video,usePrecomputedFlow:false,qualityPrioritization:.normal,revision:VTSuperResolutionScalerConfiguration.defaultRevision)
  print("factor\(factor) configuration_created=\(c != nil) advertised=\(VTSuperResolutionScalerConfiguration.supportedScaleFactors)")
 }
}
