import Foundation
import AVFoundation
import CoreImage
import Metal
import VideoToolbox
import CinemaCore

@main struct StreamingRestorationValidation {
    static var checks: [[String: Any]] = []
    static func check(_ name: String, _ value: Bool, _ evidence: [String: Any] = [:]) {
        checks.append(["name": name, "passed": value, "evidence": evidence])
    }
    static func fixture(_ pipeline: EnhancementPipeline, w: Int, h: Int, index: Int = 0) throws -> CVPixelBuffer {
        var buffer: CVPixelBuffer?
        let attrs: [String: Any] = [kCVPixelBufferMetalCompatibilityKey as String: true, kCVPixelBufferIOSurfacePropertiesKey as String: [:]]
        guard CVPixelBufferCreate(nil, w, h, kCVPixelFormatType_32BGRA, attrs as CFDictionary, &buffer) == kCVReturnSuccess, let buffer else { throw NSError(domain:"fixture", code:1) }
        let bounds = CGRect(x: 0, y: 0, width: w, height: h)
        let checker = CIFilter(name:"CICheckerboardGenerator", parameters:["inputWidth": 6, "inputColor0": CIColor(red:0.08,green:0.1,blue:0.16), "inputColor1": CIColor(red:0.55,green:0.50,blue:0.45)])!.outputImage!.cropped(to:bounds)
        let caption = CIImage(color:CIColor(red:0.95,green:0.95,blue:0.95)).cropped(to:CGRect(x:w/4,y:h/14,width:w/2,height:12))
        let moving = CIImage(color:CIColor(red:0.4,green:0.2,blue:0.15)).cropped(to:CGRect(x:w/2+index*2,y:h/3,width:40,height:h/4))
        pipeline.context.render(caption.composited(over:moving.composited(over:checker)), to:buffer, bounds:bounds, colorSpace:pipeline.colorSpace)
        CVBufferSetAttachment(buffer,kCVImageBufferColorPrimariesKey,kCVImageBufferColorPrimaries_ITU_R_709_2,.shouldPropagate)
        CVBufferSetAttachment(buffer,kCVImageBufferTransferFunctionKey,kCVImageBufferTransferFunction_sRGB,.shouldPropagate)
        CVBufferSetAttachment(buffer,kCVImageBufferYCbCrMatrixKey,kCVImageBufferYCbCrMatrix_ITU_R_709_2,.shouldPropagate)
        return buffer
    }
    static func pixels(_ frame: EnhancedFrame, pipeline: EnhancementPipeline) -> [UInt8] {
        var bytes = [UInt8](repeating:0,count:frame.width*frame.height*4)
        let image = CIImage(mtlTexture:frame.texture,options:[.colorSpace:pipeline.colorSpace])!.oriented(.downMirrored)
        pipeline.context.render(image,toBitmap:&bytes,rowBytes:frame.width*4,bounds:CGRect(x:0,y:0,width:frame.width,height:frame.height),format:.RGBA8,colorSpace:pipeline.colorSpace)
        return bytes
    }
    static func time(_ frame: Int) -> CMTime { CMTime(value:Int64(frame),timescale:30) }
    @available(macOS 26.0, *)
    static func lifecycle() throws {
        let p=try EnhancementPipeline(),b=try fixture(p,w:640,h:360),id=UUID()
        let raw=try p.process(b,mode:.original,time:time(0),streamID:id)
        let first=try p.process(b,mode:.temporal,time:time(0),streamID:id)
        check("temporal first frame is priming",!first.usedTemporalHistory && first.temporalResetReason != nil && first.mode.contains("参考建立"),["mode":first.mode])
        check("temporal priming equals original rendered pixels",pixels(first,pipeline:p)==pixels(raw,pipeline:p))
        let warm=try p.process(b,mode:.temporal,time:time(1),streamID:id)
        check("temporal warm frame uses history with truthful label",warm.usedTemporalHistory && warm.temporalResetReason==nil && warm.mode=="时域降噪",["mode":warm.mode])
        let nextID=UUID()
        let switched=try p.process(b,mode:.temporal,time:time(2),streamID:nextID)
        check("continuous PTS new stream clears old reference",!switched.usedTemporalHistory && switched.temporalResetReason != nil)
        check("new stream warms normally",try p.process(b,mode:.temporal,time:time(3),streamID:nextID).usedTemporalHistory)
        let forward=try p.process(b,mode:.temporal,time:time(303),streamID:nextID)
        check("forward seek primes",!forward.usedTemporalHistory)
        let forwardWarm=try p.process(b,mode:.temporal,time:time(304),streamID:nextID)
        check("forward seek new reference works",forwardWarm.usedTemporalHistory)
        let backward=try p.process(b,mode:.temporal,time:time(40),streamID:nextID)
        check("backward seek primes",!backward.usedTemporalHistory)
        _=try p.process(b,mode:.temporal,time:time(41),streamID:nextID)
        _=try p.process(b,mode:.original,time:time(42),streamID:nextID)
        check("explicit original mode discards temporal session",!(try p.process(b,mode:.temporal,time:time(43),streamID:nextID)).usedTemporalHistory)
        _=try p.process(b,mode:.temporal,time:time(44),streamID:nextID)
        _=try p.process(b,mode:.clarity,time:time(45),streamID:nextID)
        check("spatial mode discards temporal session",!(try p.process(b,mode:.temporal,time:time(46),streamID:nextID)).usedTemporalHistory)
        _=try p.process(b,mode:.temporal,time:time(47),streamID:nextID)
        let combined=try p.process(b,mode:.restoration,time:time(48),streamID:nextID)
        check("temporal to combined mode has fresh reference",!combined.usedTemporalHistory)
        check("combined to temporal mode has fresh reference",!(try p.process(b,mode:.temporal,time:time(49),streamID:nextID)).usedTemporalHistory)
        // The view bypasses this pipeline in original comparison. Its new revision is still a
        // stream ID, so direct temporal-to-temporal re-entry must reset without an original call.
        _=try p.process(b,mode:.temporal,time:time(50),streamID:nextID)
        check("native comparison return uses new revision",!(try p.process(b,mode:.temporal,time:time(51),streamID:UUID())).usedTemporalHistory)
    }
    @available(macOS 26.0, *)
    static func scalerAndGeometry() throws -> [[String: Any]] {
        var reports:[[String:Any]]=[]
        let p=try EnhancementPipeline(),id=UUID()
        for (w,h) in [(1280,720),(1920,1080)] {
            let b=try fixture(p,w:w,h:h)
            let factors=VTLowLatencySuperResolutionScalerConfiguration.supportedScaleFactors(frameWidth:w,frameHeight:h)
            let available=VTLowLatencySuperResolutionScalerConfiguration.isSupported ? factors.max():nil
            let expectedW=available.map{Int(Float(w)*$0)} ?? w,expectedH=available.map{Int(Float(h)*$0)} ?? h
            let first=try p.process(b,mode:.restoration,time:time(0),streamID:id)
            let warm=try p.process(b,mode:.restoration,time:time(1),streamID:id)
            check("\(w)x\(h) combined warm temporal active",warm.usedTemporalHistory)
            check("\(w)x\(h) actual output follows queried scale",warm.width==expectedW && warm.height==expectedH,["factors":factors,"expected":[expectedW,expectedH],"output":[warm.width,warm.height]])
            if let available {
                check("\(w)x\(h) combined label has actual factor",warm.mode.contains("时域降噪 + Apple AI ×\(available)") && first.mode.contains("参考建立"),["first_mode":first.mode,"warm_mode":warm.mode])
            } else {
                check("\(w)x\(h) no AI factor preserves denoised output",warm.mode.contains("无 AI 超分倍率") && warm.width==w && warm.height==h,["mode":warm.mode])
            }
            reports.append(["input":[w,h],"queried_factors":factors,"output":[warm.width,warm.height],"first_mode":first.mode,"warm_mode":warm.mode,"warm_completed_ms":warm.milliseconds])
        }
        let b=try fixture(p,w:640,h:360)
        let rotation=CGAffineTransform(a:0,b:1,c:-1,d:0,tx:360,ty:0)
        let rotated=try p.process(b,mode:.temporal,time:time(2),displayTransform:rotation,streamID:id)
        let rotatedWarm=try p.process(b,mode:.temporal,time:time(3),displayTransform:rotation,streamID:id)
        check("quarter rotation initializes correct native dimensions",rotated.width==360 && rotated.height==640 && !rotated.usedTemporalHistory && rotatedWarm.usedTemporalHistory)
        let landscape=try p.process(b,mode:.temporal,time:time(4),streamID:id)
        check("dimension change drops old rotated reference",landscape.width==640 && landscape.height==360 && !landscape.usedTemporalHistory)
        // Core Image expands a rotated raster to an integral extent. An arbitrary angle is
        // legitimate when that actual extent is supported; do not require a false rejection.
        let angle=CGAffineTransform(rotationAngle:.pi/19)
        let actualBounds=CIImage(cvPixelBuffer:b).transformed(by:angle).extent
        let arbitrary=try p.process(b,mode:.temporal,time:time(5),displayTransform:angle,streamID:id)
        check("non-quarter rotation follows actual raster extent",arbitrary.width==Int(actualBounds.width.rounded()) && arbitrary.height==Int(actualBounds.height.rounded()) && !arbitrary.usedTemporalHistory,["ci_extent":[actualBounds.width,actualBounds.height],"output":[arbitrary.width,arbitrary.height]])
        let recovery=try p.process(b,mode:.temporal,time:time(6),streamID:id)
        check("arbitrary rotation does not contaminate next landscape session",!recovery.usedTemporalHistory && recovery.width==640 && recovery.height==360)
        return reports
    }
    static func hdrRejection() throws {
        let p=try EnhancementPipeline(),b=try fixture(p,w:640,h:360)
        for transfer in [kCVImageBufferTransferFunction_SMPTE_ST_2084_PQ,kCVImageBufferTransferFunction_ITU_R_2100_HLG] {
            CVBufferSetAttachment(b,kCVImageBufferTransferFunctionKey,transfer,.shouldPropagate)
            for mode in [EnhancementMode.temporal,.restoration] {
                var reason:String?
                do{_=try p.process(b,mode:mode,time:.zero,streamID:UUID())}catch{reason=error.localizedDescription}
                check("HDR \(transfer) \(mode.rawValue) rejected",reason?.contains("HDR")==true,["reason":reason ?? "not rejected"])
            }
        }
    }
    @available(macOS 26.0, *)
    static func cleanup() throws -> [[String:Any]] {
        var cases:[[String:Any]]=[]
        for mode in [EnhancementMode.temporal,.restoration] {
            let baseline=try EnhancementPipeline(),changed=try EnhancementPipeline(),rejected=try EnhancementPipeline(),id=UUID()
            let first=try fixture(baseline,w:640,h:360,index:0),next=try fixture(baseline,w:640,h:360,index:1)
            let region=NormalizedVideoRect(x:0.10,y:0.10,width:0.3,height:0.3)
            let settings=AdCleanupSettings(enabled:true,regions:[region])
            _=try baseline.process(first,mode:mode,time:time(0),streamID:id)
            _=try changed.process(first,mode:mode,time:time(0),streamID:id)
            _=try rejected.process(first,mode:mode,time:time(0),streamID:id)
            let raw=try baseline.process(next,mode:mode,time:time(1),streamID:id)
            let cleaned=try changed.process(next,mode:mode,time:time(1),cleanup:settings,streamID:id)
            let conflict=AdCleanupSettings(enabled:true,regions:[NormalizedVideoRect(x:0.1,y:0.65,width:0.3,height:0.25)])
            let protectedOutput=try rejected.process(next,mode:mode,time:time(1),cleanup:conflict,streamID:id)
            let a=pixels(raw,pipeline:baseline),b=pixels(cleaned,pipeline:changed)
            let rect=AdCleanupPolicy.pixelRect(region,width:raw.width,height:raw.height)!
            let protectedRect=AdCleanupPolicy.pixelRect(AdCleanupSettings.defaultProtection,width:raw.width,height:raw.height)!
            var inside=0,outside=0,protectedChanges=0
            for y in 0..<raw.height {for x in 0..<raw.width {
                let offset=(y*raw.width+x)*4
                if a[offset..<offset+4] != b[offset..<offset+4] {
                    let point=CGPoint(x:Double(x)+0.5,y:Double(y)+0.5)
                    if rect.contains(point){inside+=1}else{outside+=1}
                    if protectedRect.contains(point){protectedChanges+=1}
                }
            }}
            check("\(mode.rawValue) cleanup retains temporal result",raw.usedTemporalHistory && cleaned.usedTemporalHistory && cleaned.cleanupAppliedRegions==1)
            check("\(mode.rawValue) actual blur is confined to selection",inside>0 && outside==0 && protectedChanges==0,["inside_changed":inside,"outside_changed":outside,"protected_changed":protectedChanges])
            check("\(mode.rawValue) subtitle-overlap cleanup rejected after enhancement",pixels(protectedOutput,pipeline:rejected)==a && protectedOutput.cleanupAppliedRegions==0 && protectedOutput.cleanupRejectedRegions==1)
            cases.append(["mode":mode.rawValue,"output":[raw.width,raw.height],"inside_changed":inside,"outside_changed":outside,"protected_changed":protectedChanges])
        }
        return cases
    }
    static func main() throws {
        guard #available(macOS 26.0,*),VTTemporalNoiseFilterConfiguration.isSupported else{throw NSError(domain:"streaming",code:1,userInfo:[NSLocalizedDescriptionKey:"Native temporal unavailable; no passing report"])}
        let path=CommandLine.arguments.count>1 ? CommandLine.arguments[1]:"/tmp/streaming-restoration.json"
        try lifecycle();let scales=try scalerAndGeometry();try hdrRejection();let cleanup=try cleanup()
        let failed=checks.filter{($0["passed"] as? Bool) != true}
        let report:[String:Any]=["scope":"Real production EnhancementPipeline and TemporalRestorer on synthetic SDR CVPixelBuffers; native/GPU completion and pixel readback. No app UI, network decoding, audio sync, real-film or sustained-playback validation.","device":MTLCreateSystemDefaultDevice()?.name ?? "unknown","os":ProcessInfo.processInfo.operatingSystemVersionString,"checks":checks,"scaling_cases":scales,"cleanup_cases":cleanup,"passed":failed.isEmpty,"failed_checks":failed.count]
        try JSONSerialization.data(withJSONObject:report,options:[.prettyPrinted,.sortedKeys]).write(to:URL(fileURLWithPath:path))
        print("Streaming restoration pipeline: \(checks.count-failed.count)/\(checks.count) checks passed; report \(path)")
        for failure in failed{print(failure)}
        if !failed.isEmpty{exit(1)}
    }
}
