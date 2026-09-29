import Foundation
import CoreImage
import CoreMedia
import CoreVideo
import Metal
import QuartzCore
import CinemaCore

@main struct FullCacheBenchmark {
static func main() throws {
    let basePipeline = try EnhancementPipeline(), candidatePipeline = try EnhancementPipeline()
    let baseline = InterpolatedFramePipelineBaseline(pipeline: basePipeline)
    let candidate = InterpolatedFramePipelineMeasured(pipeline: candidatePipeline)
    let width = 1920, height = 1080, cs = basePipeline.colorSpace
    var buffer: CVPixelBuffer?
    let attrs: [String: Any] = [kCVPixelBufferIOSurfacePropertiesKey as String: [:], kCVPixelBufferMetalCompatibilityKey as String: true]
    guard CVPixelBufferCreate(nil,width,height,kCVPixelFormatType_32BGRA,attrs as CFDictionary,&buffer)==0,let buffer else {fatalError("fixture allocation")}
    CVBufferSetAttachment(buffer,kCVImageBufferColorPrimariesKey,kCVImageBufferColorPrimaries_ITU_R_709_2,.shouldPropagate)
    CVBufferSetAttachment(buffer,kCVImageBufferTransferFunctionKey,kCVImageBufferTransferFunction_sRGB,.shouldPropagate)
    func fixture(_ n:Int) -> CIImage {
        let bounds=CGRect(x:0,y:0,width:width,height:height),shift=Double(n*12)
        let base=CIImage(color:CIColor(red:0.08,green:0.12,blue:0.18)).cropped(to:bounds)
        let patch=CIFilter(name:"CICheckerboardGenerator",parameters:["inputWidth":16.0,"inputCenter":CIVector(x:shift,y:0),"inputColor0":CIColor(red:0.72,green:0.61,blue:0.53),"inputColor1":CIColor(red:0.38,green:0.48,blue:0.67)])!.outputImage!.cropped(to:CGRect(x:420+shift,y:320,width:580,height:440))
        let caption=CIImage(color:CIColor(red:0.85,green:0.85,blue:0.85)).cropped(to:CGRect(x:320,y:90,width:1000,height:14))
        return caption.composited(over:patch.composited(over:base))
    }
    func pixels(_ frame:EnhancedFrame,_ pipeline:EnhancementPipeline)->[UInt8] {
        let image=CIImage(mtlTexture:frame.texture,options:[.colorSpace:cs])!
        var bytes=[UInt8](repeating:0,count:width*height*4)
        pipeline.context.render(image,toBitmap:&bytes,rowBytes:width*4,bounds:CGRect(x:0,y:0,width:width,height:height),format:.RGBA8,colorSpace:cs)
        return bytes
    }
    var rows:[[String:Any]]=[], quality:[String:[UInt8]]=[:]
    for (round,name) in ["baseline","candidate","candidate","baseline"].enumerated() {
        let isBase=name=="baseline",stream=UUID()
        if isBase {baseline.reset()} else {candidate.reset()}
        let initialConversions=isBase ? baseline.interpolator?.renderedInputCount ?? 0 : candidate.interpolator?.renderedInputCount ?? 0
        let initialHits=candidate.interpolator?.reusedInputCount ?? 0
        var times:[Double]=[],wall:[Double]=[],setup=0.0,generated=0
        for index in 0...20 {
            let image=fixture(index)
            basePipeline.context.render(image,to:buffer,bounds:image.extent,colorSpace:cs)
            let start=CACurrentMediaTime(), t=CMTime(value:Int64(index),timescale:24)
            let frames:[(time:Double,frame:EnhancedFrame)]
            if isBase {
                frames=try baseline.process(buffer:buffer,time:t,mode:.clarity,resolution:.fullHD,transform:.identity,cleanup:.init(),streamID:stream)
                setup += baseline.lastSetupMilliseconds
                generated += baseline.lastInterpolatedFrameCount
                if index>=3 {times.append(baseline.lastMilliseconds)}
            } else {
                frames=try candidate.process(buffer:buffer,time:t,mode:.clarity,resolution:.fullHD,transform:.identity,cleanup:.init(),streamID:stream)
                setup += candidate.lastSetupMilliseconds
                generated += candidate.lastInterpolatedFrameCount
                if index>=3 {times.append(candidate.lastMilliseconds)}
            }
            if index>=3 {wall.append((CACurrentMediaTime()-start)*1000)}
            if index==8 {quality["\(name)-\(round)"]=pixels(frames[0].frame,isBase ? basePipeline : candidatePipeline)}
        }
        let totalConversions=isBase ? baseline.interpolator?.renderedInputCount ?? 0 : candidate.interpolator?.renderedInputCount ?? 0
        let hits=isBase ? 0:(candidate.interpolator?.reusedInputCount ?? 0)-initialHits
        let sorted=times.sorted()
        let row:[String:Any]=["round":round,"implementation":name,"measured_source_intervals":times.count,"all_source_frames":21,"generated_frames":generated,"cache_hits":hits,"full_resolution_input_conversions":totalConversions-initialConversions,"setup_ms":setup,"mean_ms":times.reduce(0,+)/Double(times.count),"p95_ms":sorted[Int(ceil(Double(sorted.count)*0.95))-1],"mean_wall_ms":wall.reduce(0,+)/Double(wall.count),"over_24fps_budget":times.filter{$0>1000.0/24}.count,"times_ms":times]
        rows.append(row);print(name,round,"mean",row["mean_ms"]!,"p95",row["p95_ms"]!,"hits",hits,"conversions",totalConversions-initialConversions)
    }
    let old=quality["baseline-0"]!,new=quality["candidate-1"]!,repeated=quality["candidate-2"]!
    let different=zip(old,new).filter{$0 != $1}.count
    let differentRepeat=zip(new,repeated).filter{$0 != $1}.count
    let checks:[[String:Any]]=[
        ["name":"full_pipeline_pixels_identical_to_uncached_baseline","passed":different==0,"different_components":different],
        ["name":"reset_repeated_run_pixels_identical","passed":differentRepeat==0,"different_components":differentRepeat],
        ["name":"all_continuous_pairs_hit_cache","passed":rows.filter{$0["implementation"] as? String=="candidate"}.allSatisfy{$0["cache_hits"] as? Int==19 && $0["full_resolution_input_conversions"] as? Int==21}],
        ["name":"baseline_renders_both_pair_inputs","passed":rows.filter{$0["implementation"] as? String=="baseline"}.allSatisfy{$0["full_resolution_input_conversions"] as? Int==40}]
    ]
    let passed=checks.allSatisfy{$0["passed"] as? Bool==true}
    let report:[String:Any]=["passed":passed,"device":basePipeline.device.name,"size":[width,height],"checks":checks,"rounds":rows,"scope":"ABBA full InterpolatedFramePipeline with 1080p natural denoise and 24-to-60 FRC. Production snapshots differ only in source-cache implementation and test-only counters; no test fields added to production. Each round 21 source frames/20 pairs, first three source frames excluded from measurement. Includes spatial processing, scene preview, input conversion, FRC and final output texture completion; excludes fixture generation, correctness readback, decoder and VideoSurface.draw/present. Setup is separately recorded. Short performance observation, not sustained displayed 60fps proof."]
    try JSONSerialization.data(withJSONObject:report,options:[.prettyPrinted,.sortedKeys]).write(to:URL(fileURLWithPath:CommandLine.arguments[1]))
    if !passed {exit(1)}
}
}
