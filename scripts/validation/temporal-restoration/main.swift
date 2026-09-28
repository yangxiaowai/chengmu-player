import Foundation
import CoreImage
import CoreMedia
import CoreVideo
import Metal
import VideoToolbox

@main struct TemporalRestorationValidation {
    static let color = CGColorSpace(name: CGColorSpace.sRGB)!
    static var checks: [[String: Any]] = []
    static func check(_ name: String, _ passed: Bool, _ details: [String: Any] = [:]) {
        checks.append(["name": name, "passed": passed, "details": details])
    }
    static func pixels(_ image: CIImage, context: CIContext, w: Int, h: Int) -> [UInt8] {
        var p = [UInt8](repeating: 0, count: w * h * 4)
        context.render(image, toBitmap: &p, rowBytes: w * 4, bounds: CGRect(x: 0, y: 0, width: w, height: h), format: .RGBA8, colorSpace: color)
        return p
    }
    static func fixture(w: Int, h: Int, index: Int, noisy: Bool) -> CIImage {
        var p = [UInt8](repeating: 255, count: w * h * 4), seed = UInt64(index + 76543)
        for y in 0..<h { for x in 0..<w {
            let base: [Int]
            if y > h * 4 / 5 && y < h * 4 / 5 + 12 && x > (index < 6 ? 100 : 200) && x < (index < 6 ? 400 : 500) && (x / 8) % 3 != 0 { base = [228, 228, 228] }
            else if x > w / 2 + index * 5 && x < w / 2 + index * 5 + 80 && y > h / 3 && y < h * 2 / 3 { base = [180, 180, 180] }
            else if x > w * 3 / 4 && y < h / 4 { base = (x / 3) % 2 == 0 ? [90, 90, 90] : [114, 114, 114] }
            else if x < w / 3 { base = [30, 30, 30] }
            else { base = [102, 102, 102] }
            for c in 0..<3 {
                seed = seed &* 6364136223846793005 &+ 1442695040888963407
                p[(y * w + x) * 4 + c] = UInt8(clamping: base[c] + (noisy ? Int((seed >> 32) % 31) - 15 : 0))
            }
        }}
        return CIImage(bitmapData: Data(p), bytesPerRow: w * 4, size: CGSize(width: w, height: h), format: .RGBA8, colorSpace: color)
    }
    static func mse(_ a: [UInt8], _ truth: [UInt8], w: Int, h: Int, region: String) -> Double {
        var sum = 0.0, count = 0
        for y in stride(from: 16, to: h - 16, by: 2) { for x in stride(from: 16, to: w - 16, by: 2) {
            let include: Bool
            switch region {
            case "flat": include = x < w / 3 - 20 && y < h * 3 / 4
            case "motion": include = x > w / 2 - 10 && x < w / 2 + 180 && y > h / 3 - 10 && y < h * 2 / 3 + 10
            case "texture": include = x > w * 3 / 4 + 16 && y < h / 4 - 16
            case "subtitle": include = x > 90 && x < 510 && y > h * 4 / 5 - 4 && y < h * 4 / 5 + 18
            default: include = true
            }
            if include { for c in 0..<3 { let d = Double(a[(y*w+x)*4+c]) - Double(truth[(y*w+x)*4+c]); sum += d*d; count += 1 } }
        }}
        return sum / Double(max(1, count))
    }
    @available(macOS 26.0, *)
    static func quality(context: CIContext, w: Int, h: Int) throws -> [String: Any] {
        let restorer = try TemporalRestorer(width: w, height: h, context: context), stream = UUID()
        var timings: [Double] = [], measurements: [[String: Any]] = []
        for index in 0..<12 {
            let noisy = fixture(w: w, h: h, index: index, noisy: true)
            let restored = try restorer.process(noisy, time: CMTime(value: Int64(index), timescale: 30), streamID: stream)
            timings.append(restored.milliseconds)
            check("\(w)p frame \(index) history", restored.usedHistory == (index > 0), ["reason": restored.resetReason ?? "none"])
            if index == 0 {
                check("\(w)p priming is exact original", pixels(noisy, context: context, w: w, h: h) == pixels(restored.image, context: context, w: w, h: h))
            }
            if [1, 6, 11].contains(index) {
                let truth = pixels(fixture(w: w, h: h, index: index, noisy: false), context: context, w: w, h: h)
                let raw = pixels(noisy, context: context, w: w, h: h), out = pixels(restored.image, context: context, w: w, h: h)
                let spatial = pixels(noisy.applyingFilter("CINoiseReduction", parameters: ["inputNoiseLevel": 0.015, "inputSharpness": 0]), context: context, w: w, h: h)
                var values: [String: Any] = ["frame": index]
                for region in ["flat", "motion", "texture", "subtitle"] {
                    let before = mse(raw, truth, w: w, h: h, region: region), after = mse(out, truth, w: w, h: h, region: region)
                    let old = mse(spatial, truth, w: w, h: h, region: region)
                    values[region] = ["raw_mse": before, "temporal_mse": after, "spatial_mse": old]
                    check("\(w)p frame \(index) \(region) noise improves", after < before * 0.8, ["raw_mse": before, "restored_mse": after])
                    if region == "motion" || region == "texture" { check("\(w)p frame \(index) \(region) beats spatial", after < old * 0.85, ["spatial_mse": old, "restored_mse": after]) }
                }
                var strokes = 0, preserved = 0, background = 0, leaked = 0
                for y in (h*4/5-4)..<(h*4/5+18) { for x in 90..<510 {
                    if truth[(y*w+x)*4] > 200 { strokes += 1; if out[(y*w+x)*4] > 180 { preserved += 1 } }
                    else { background += 1; if out[(y*w+x)*4] > 180 { leaked += 1 } }
                }}
                let recall = Double(preserved)/Double(strokes), leak = Double(leaked)/Double(background)
                values["subtitle_foreground_recall"] = recall; values["subtitle_background_leak"] = leak
                check("\(w)p frame \(index) subtitle strokes", recall >= 0.985 && leak < 0.005, ["foreground_recall": recall, "background_leak": leak])
                measurements.append(values)
            }
        }
        let warm = Array(timings.dropFirst(2)), sorted = warm.sorted()
        return ["dimensions": [w,h], "frames": timings.count, "first_priming_ms": timings[0], "first_native_process_ms": timings[1], "warm_completed_mean_ms": warm.reduce(0,+)/Double(warm.count), "warm_completed_p95_ms": sorted[min(sorted.count-1, Int(Double(sorted.count)*0.95))], "measurements": measurements]
    }
    @available(macOS 26.0, *)
    static func protections(context: CIContext) throws {
        let w = 640, h = 360, stream = UUID()
        let restorer = try TemporalRestorer(width: w, height: h, context: context)
        func solid(_ r: CGFloat, _ g: CGFloat, _ b: CGFloat) -> CIImage { CIImage(color: CIColor(red: r, green: g, blue: b)).cropped(to: CGRect(x: 0, y: 0, width: w, height: h)) }
        let a = fixture(w: w, h: h, index: 0, noisy: true)
        _ = try restorer.process(a, time: .zero, streamID: stream)
        check("steady frame uses history", try restorer.process(a, time: CMTime(value: 1, timescale: 30), streamID: stream).usedHistory)
        let seek = try restorer.process(a, time: CMTime(value: 3000, timescale: 30), streamID: stream)
        check("seek primes exact current image", !seek.usedHistory && pixels(seek.image, context: context, w: w, h: h) == pixels(a, context: context, w: w, h: h))
        let afterSeek = try restorer.process(a, time: CMTime(value: 3001, timescale: 30), streamID: stream)
        let fresh = try TemporalRestorer(width: w, height: h, context: context)
        _ = try fresh.process(a, time: CMTime(value: 3000, timescale: 30), streamID: stream)
        let afterFresh = try fresh.process(a, time: CMTime(value: 3001, timescale: 30), streamID: stream)
        let resetMSE = mse(pixels(afterSeek.image, context: context, w: w, h: h), pixels(afterFresh.image, context: context, w: w, h: h), w: w, h: h, region: "all")
        check("seek output equals fresh session", resetMSE <= 0.01, ["mse": resetMSE])
        check("backward timestamp clears history", !(try restorer.process(a, time: .zero, streamID: stream)).usedHistory)
        check("duplicate timestamp clears history", !(try restorer.process(a, time: .zero, streamID: stream)).usedHistory)
        check("new stream identity clears history", !(try restorer.process(a, time: CMTime(value: 1, timescale: 30), streamID: UUID())).usedHistory)
        check("invalid timestamp clears history", !(try restorer.process(a, time: .invalid, streamID: stream)).usedHistory)
        let cut = try TemporalRestorer(width: w, height: h, context: context)
        _ = try cut.process(solid(0.1,0.1,0.1), time: .zero, streamID: stream)
        let changed = solid(0.9,0.9,0.9)
        let cutResult = try cut.process(changed, time: CMTime(value: 1, timescale: 30), streamID: stream)
        check("hard cut has no old-frame ghost", !cutResult.usedHistory && pixels(cutResult.image, context: context, w: w, h: h) == pixels(changed, context: context, w: w, h: h))
        let colorCut = try TemporalRestorer(width: w, height: h, context: context)
        _ = try colorCut.process(solid(1,0,0), time: .zero, streamID: stream)
        let colorResult = try colorCut.process(solid(0,0.3,0), time: CMTime(value: 1, timescale: 30), streamID: stream)
        check("equal-luma color cut clears history", !colorResult.usedHistory)
        let pan = try TemporalRestorer(width: w, height: h, context: context)
        func checker(_ offset: CGFloat) -> CIImage { CIFilter(name: "CICheckerboardGenerator", parameters: ["inputWidth": 16, "inputCenter": CIVector(x: offset, y: 0), "inputColor0": CIColor(red: 0.15,green:0.15,blue:0.15), "inputColor1": CIColor(red:0.55,green:0.55,blue:0.55)])!.outputImage!.cropped(to: CGRect(x:0,y:0,width:w,height:h)) }
        _ = try pan.process(checker(0), time: .zero, streamID: stream)
        let panResult = try pan.process(checker(16), time: CMTime(value: 1, timescale: 30), streamID: stream)
        check("large fast motion bypasses history", !panResult.usedHistory)
        var sizeRejected = false
        do { _ = try restorer.process(a.cropped(to: CGRect(x:0,y:0,width:w/2,height:h)), time: .zero, streamID: stream) } catch { sizeRejected = true }
        check("size change throws for session rebuild", sizeRejected)
        var badStrength = false
        do { _ = try TemporalRestorer(width: w, height: h, context: context, strength: 1.1) } catch { badStrength = true }
        check("invalid strength is rejected", badStrength)
    }
    @available(macOS 26.0, *)
    static func colorsAndDepth(context: CIContext) throws {
        let w=640,h=360,id=UUID(),p=try TemporalRestorer(width:640,height:360,context:context)
        let clean=fixture(w:w,h:h,index:0,noisy:false)
        _=try p.process(clean,time:.zero,streamID:id)
        let out=try p.process(clean,time:CMTime(value:1,timescale:30),streamID:id)
        let error=mse(pixels(out.image,context:context,w:w,h:h),pixels(clean,context:context,w:w,h:h),w:w,h:h,region:"all")
        check("clean detailed frame is preserved",error<1.1,["mse":error])
        for rgb:[CGFloat] in [[0.1,0.1,0.1],[0.4,0.2,0.6],[0.7,0.5,0.2],[0.95,0.95,0.95]] {
            let r=try TemporalRestorer(width:w,height:h,context:context)
            let image=CIImage(color:CIColor(red:rgb[0],green:rgb[1],blue:rgb[2])).cropped(to:CGRect(x:0,y:0,width:w,height:h))
            _=try r.process(image,time:.zero,streamID:id)
            let result=try r.process(image,time:CMTime(value:1,timescale:30),streamID:id)
            let before=pixels(image,context:context,w:w,h:h),after=pixels(result.image,context:context,w:w,h:h)
            let d=(0..<3).map{abs(Int(before[$0])-Int(after[$0]))}.max()!
            check("SDR color \(rgb) remains within 2 codes",d<=2,["input":Array(before.prefix(3)),"output":Array(after.prefix(3)),"max_difference":d])
        }
        var fp=[Float](repeating:1,count:w*h*4)
        for y in 0..<h {for x in 0..<w {for c in 0..<3{fp[(y*w+x)*4+c]=0.15+Float(x)/1024}}}
        let data=fp.withUnsafeBytes{Data($0)}
        let gradient=CIImage(bitmapData:data,bytesPerRow:w*16,size:CGSize(width:w,height:h),format:.RGBAf,colorSpace:color)
        let r=try TemporalRestorer(width:w,height:h,context:context)
        _=try r.process(gradient,time:.zero,streamID:id)
        let result=try r.process(gradient,time:CMTime(value:1,timescale:30),streamID:id)
        var restored=[Float](repeating:0,count:w*4)
        context.render(result.image,toBitmap:&restored,rowBytes:w*16,bounds:CGRect(x:0,y:h/2,width:w,height:1),format:.RGBAf,colorSpace:color)
        let levels=Set(stride(from:0,to:w*4,by:4).map{Int((restored[$0]*4096).rounded())}).count
        check("restoration keeps more than 8-bit ramp steps",levels>256,["distinct_levels_on_640_pixel_ramp":levels])
    }
    static func main() throws {
        let path=CommandLine.arguments.count>1 ? CommandLine.arguments[1]:"/tmp/temporal-restoration.json"
        guard #available(macOS 26.0,*),VTTemporalNoiseFilterConfiguration.isSupported,let device=MTLCreateSystemDefaultDevice() else { throw NSError(domain:"TemporalValidation",code:1,userInfo:[NSLocalizedDescriptionKey:"Native temporal processing unsupported; no passing report produced"]) }
        let context=CIContext(mtlDevice:device,options:[.cacheIntermediates:false,.workingColorSpace:CGColorSpace(name:CGColorSpace.extendedLinearSRGB)!])
        let reports=try [(1280,720),(1920,1080)].map{try quality(context:context,w:$0.0,h:$0.1)}
        try protections(context:context);try colorsAndDepth(context:context)
        let failures=checks.filter{($0["passed"] as? Bool) != true}
        let report:[String:Any]=["scope":"Deterministic synthetic SDR native temporal processing. Actual completion waited, includes scene preview and float16-to-lossless10 conversion. No application playback, decoding, network, HDR or long-duration claim.","device":device.name,"os":ProcessInfo.processInfo.operatingSystemVersionString,"strength":0.75,"reference_frames":["past":1,"future":0],"results":reports,"checks":checks,"passed":failures.isEmpty,"failed_checks":failures.count]
        try JSONSerialization.data(withJSONObject:report,options:[.prettyPrinted,.sortedKeys]).write(to:URL(fileURLWithPath:path))
        print("Temporal restoration: \(checks.count-failures.count)/\(checks.count) checks passed; report \(path)")
        for failure in failures{print(failure)}
        if !failures.isEmpty{exit(1)}
    }
}
