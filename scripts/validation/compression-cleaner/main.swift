import Foundation
import Metal
import CoreImage
import CoreMedia
import CinemaCore

@main struct CleanerValidation {
    static let w = 320, h = 180
    static let color = CGColorSpace(name: CGColorSpace.sRGB)!
    static var checks: [[String: Any]] = []
    static func check(_ name: String, _ value: Bool, _ evidence: [String: Any] = [:]) {
        checks.append(["name":name,"passed":value,"evidence":evidence]); print("\(value ? "PASS":"FAIL") \(name) \(evidence)")
    }
    static func image(_ width: Int, _ height: Int, value: (Int,Int)->Float) -> CIImage {
        var rgba=[Float](repeating:1,count:width*height*4)
        // Bitmap rows are top-down; expose bottom-left CI coordinates to the fixture.
        for y in 0..<height {for x in 0..<width {let i=((height-1-y)*width+x)*4,v=value(x,y)/255;rgba[i]=v;rgba[i+1]=v;rgba[i+2]=v}}
        return rgba.withUnsafeBytes { CIImage(bitmapData:Data($0),bytesPerRow:width*16,size:CGSize(width:width,height:height),format:.RGBAf,colorSpace:color) }
    }
    static func pixels(_ image:CIImage,context:CIContext)->[Float] {
        let w=Int(image.extent.width),h=Int(image.extent.height)
        var rgba=[Float](repeating:0,count:w*h*4)
        // Read back in bottom-left row order for the independently specified CI rectangles.
        context.render(image.oriented(.downMirrored),toBitmap:&rgba,rowBytes:w*16,bounds:image.extent,format:.RGBAf,colorSpace:color)
        return rgba
    }
    static func mse(_ a:[Float],_ b:[Float],width:Int,height:Int,region:CGRect?=nil)->Double {
        var sum=0.0,n=0
        for y in 0..<height {for x in 0..<width {
            if let region,!region.contains(CGPoint(x:Double(x)+0.5,y:Double(y)+0.5)){continue}
            for c in 0..<3 {let d=Double(a[(y*width+x)*4+c]-b[(y*width+x)*4+c])*255;sum+=d*d;n+=1}
        }}
        return sum/Double(max(1,n))
    }
    static let filmVariants = ["compressed-film", "noisy-film", "heavy-noisy-film"]
    static let filmFrames = [12, 24, 48, 72, 84]
    static func loadFilmExports(from directory: URL) throws -> [String: Data] {
        let expectedBytes = 480 * 200 * 4 * MemoryLayout<Float>.size
        let names = filmFrames.map { "clean-\($0)" } + filmVariants.flatMap { variant in
            filmFrames.map { "\(variant)-temporal-\($0)" }
        }
        var exports: [String: Data] = [:]
        for name in names {
            let file = directory.appendingPathComponent(name + ".rgba32f")
            var isDirectory: ObjCBool = false
            guard FileManager.default.fileExists(atPath: file.path, isDirectory: &isDirectory), !isDirectory.boolValue else {
                throw NSError(domain: "CleanerValidation", code: 1, userInfo: [NSLocalizedDescriptionKey: "Film export file is missing or is not a file: \(file.path)"])
            }
            let data: Data
            do { data = try Data(contentsOf: file) }
            catch {
                throw NSError(domain: "CleanerValidation", code: 2, userInfo: [NSLocalizedDescriptionKey: "Cannot read film export \(file.path): \(error.localizedDescription)"])
            }
            guard data.count == expectedBytes else {
                throw NSError(domain: "CleanerValidation", code: 3, userInfo: [NSLocalizedDescriptionKey: "Film export has invalid size: \(file.path); expected \(expectedBytes) bytes (480x200 RGBA32F), got \(data.count)"])
            }
            exports[name] = data
        }
        return exports
    }
    static func main() {
        do { try run() }
        catch {
            FileHandle.standardError.write(Data("ERROR: \(error.localizedDescription)\n".utf8))
            exit(2)
        }
    }
    static func run() throws {
        guard (2...3).contains(CommandLine.arguments.count) else {
            throw NSError(domain: "CleanerValidation", code: 4, userInfo: [NSLocalizedDescriptionKey: "Usage: check REPORT_PATH [FILM_EXPORT_DIRECTORY]"])
        }
        let filmDirectory = CommandLine.arguments.count == 3 ? URL(fileURLWithPath: CommandLine.arguments[2], isDirectory: true) : nil
        // Check every supplied export before creating the GPU pipeline or starting measurements.
        let filmExports = try filmDirectory.map { try loadFilmExports(from: $0) }
        let p=try EnhancementPipeline(),out=URL(fileURLWithPath:CommandLine.arguments[1])
        let frameDir=out.deletingPathExtension().appendingPathExtension("frames")
        try FileManager.default.createDirectory(at:frameDir,withIntermediateDirectories:true)
        #if CLEANER_BASELINE
        func process(_ image:CIImage,_ protection:[NormalizedVideoRect] = [AdCleanupSettings.defaultProtection])throws->CIImage {image}
        #else
        let cleaner=try CompressionCleaner(device:p.device)
        func process(_ image:CIImage,_ protection:[NormalizedVideoRect] = [AdCleanupSettings.defaultProtection])throws->CIImage {
            try cleaner.process(image,protectedRegions:protection,context:p.context,queue:p.queue)
        }
        #endif
        let vertical=image(w,h){_,y in Float(y)}
        let verticalRead=pixels(vertical,context:p.context)
        check("fixture and readback coordinates are bottom-left",abs(verticalRead[0]*255)<0.05 && abs(verticalRead[((h-1)*w)*4]*255-Float(h-1))<0.15)
        let truth=image(w,h){_,_ in 128},truthP=pixels(truth,context:p.context)
        var seed:UInt64=730629
        let noisy=image(w,h){_,_ in seed=seed &* 6364136223846793005 &+ 1442695040888963407;return 128+Float(Int((seed>>32)%9)-4)}
        let original=pixels(noisy,context:p.context),filtered=try process(noisy),result=pixels(filtered,context:p.context)
        let upper=CGRect(x:8,y:65,width:w-16,height:h-73)
        let before=mse(original,truthP,width:w,height:h,region:upper),after=mse(result,truthP,width:w,height:h,region:upper)
        check("flat residual noise reduced at least 15 percent",after < before*0.85,["mse_before":before,"mse_after":after])
        let protectedError=mse(original,result,width:w,height:h,region:CGRect(x:0,y:0,width:w,height:50))
        check("default bottom subtitle band has no extra filtering",protectedError<0.003,["mse_change_codes":protectedError])
        let maxDelta=zip(result,original).enumerated().filter{$0.offset%4 != 3}.map{abs(Double($0.element.0-$0.element.1))*255}.max()!
        check("local correction is bounded to 2 code values plus storage tolerance",maxDelta <= 2.15,["max_delta_code":maxDelta])
        let custom=NormalizedVideoRect(x:0.1,y:0.1,width:0.25,height:0.25)
        let customOutput=pixels(try process(noisy,[custom]),context:p.context)
        let customRect=CGRect(x:32,y:117,width:80,height:45)
        let customError=mse(original,customOutput,width:w,height:h,region:customRect)
        check("top-left normalized custom protection maps to correct image area",customError<0.003,["mse_change_codes":customError])
        let customBottomError=mse(original,customOutput,width:w,height:h,region:CGRect(x:0,y:0,width:w,height:50))
        check("custom protection keeps the default subtitle band",customBottomError<0.003,["mse_change_codes":customBottomError])
        check("protection does not accidentally disable the whole frame",mse(original,customOutput,width:w,height:h,region:CGRect(x:180,y:80,width:100,height:80))>0.005)
        let stable=pixels(try process(truth),context:p.context)
        check("constant gray stays unchanged",mse(stable,truthP,width:w,height:h)<0.003)
        let edge=image(w,h){x,_ in x<w/2 ? 32:224},edgeP=pixels(edge,context:p.context)
        check("strong clean edge stays unchanged",mse(pixels(try process(edge),context:p.context),edgeP,width:w,height:h)<0.003)
        let ramp=image(1024,h){x,_ in 16+Float(x)*224/1023}
        let rampPixels=pixels(try process(ramp),context:p.context)
        let levels=Set((0..<1024).map{Int((rampPixels[(100*1024+$0)*4]*65535).rounded())}).count
        check("SDR prepass retains more than 8-bit ramp levels",levels>800,["distinct_levels":levels])
        let texture=image(w,h){x,_ in 128+4*cos(Float(x)*2*Float.pi/8)}
        let textureP=pixels(texture,context:p.context),textureOut=pixels(try process(texture),context:p.context)
        let loss=mse(textureP,textureOut,width:w,height:h,region:upper)
        check("weak clean texture is not flattened",loss<0.4,["mse_change_codes":loss])
        // A fine caption belongs to the protected bottom band. It changes every call:
        // a stateless prepass must never retain a disappearing or moved glyph.
        let captions=image(w,h){x,y in y<40 && ((x==60 && y>8)||(y==25 && x>40 && x<90)||(x-y==130)) ? 132:128}
        check("fine low-contrast caption protected",mse(pixels(try process(captions),context:p.context),pixels(captions,context:p.context),width:w,height:h,region:CGRect(x:0,y:0,width:w,height:45))<0.003)
        check("caption disappearance leaves no old pixels",mse(pixels(try process(truth),context:p.context),truthP,width:w,height:h)<0.003)
        let retained=pixels(filtered,context:p.context)
        _=try process(edge)
        check("retained output is immutable after later frames",pixels(filtered,context:p.context)==retained)
        var rejected=false
        do{_=try process(noisy,[NormalizedVideoRect(x:.nan,y:0,width:1,height:1)])}catch{rejected=true}
        check("invalid protection fails safely",rejected)
        try p.context.writePNGRepresentation(of:noisy,to:frameDir.appendingPathComponent("noise-before.png"),format:.RGBA8,colorSpace:color)
        try p.context.writePNGRepresentation(of:filtered,to:frameDir.appendingPathComponent("noise-after.png"),format:.RGBA8,colorSpace:color)
        var films:[[String:Any]]=[]
        if let filmExports {
            func load(_ name:String)->CIImage {
                CIImage(bitmapData:filmExports[name]!,bytesPerRow:480*16,size:CGSize(width:480,height:200),format:.RGBAf,colorSpace:color)
            }
            for name in filmVariants {
                for frame in filmFrames {
                    let source=load("\(name)-temporal-\(frame)"),reference=pixels(load("clean-\(frame)"),context:p.context)
                    let input=pixels(source,context:p.context),output=try process(source),actual=pixels(output,context:p.context)
                    // The same final SDR clamp on all three avoids crediting only the new
                    // path for clipping extended SDR decoder/Lanczos overshoot.
                    let displayInput=input.map{min(1,max(0,$0))},displayReference=reference.map{min(1,max(0,$0))},displayActual=actual.map{min(1,max(0,$0))}
                    let before=mse(displayInput,displayReference,width:480,height:200),after=mse(displayActual,displayReference,width:480,height:200)
                    films.append(["variant":name,"frame":frame,"mse_before":before,"mse_after":after,"psnr_gain_db":10*log10(before/after)])
                    if frame==24 {for (suffix,image) in [("before",source),("after",output)] {try p.context.writePNGRepresentation(of:image,to:frameDir.appendingPathComponent("\(name)-\(suffix).png"),format:.RGBA8,colorSpace:color)}}
                }
            }
        }
        var timings:[[String:Any]]=[]
        for (bw,bh) in [(1280,720),(1920,1080)] {
            let test=image(bw,bh){x,y in 128+Float((x*73+y*31)%9)-4}
            for _ in 0..<3{_=try process(test)}
            var times:[Double]=[]
            for _ in 0..<30 {let start=CFAbsoluteTimeGetCurrent();_=try process(test);times.append((CFAbsoluteTimeGetCurrent()-start)*1000)}
            let sorted=times.sorted()
            timings.append(["size":[bw,bh],"mean_ms":times.reduce(0,+)/Double(times.count),"p95_ms":sorted[28],"samples_ms":times])
        }
        let passed=checks.allSatisfy{$0["passed"] as? Bool == true}
        var filmSummary:[String:Any] = ["status":filmDirectory == nil ? "skipped":"completed", "samples":films.count]
        let filmScope:String
        if let filmDirectory {
            filmSummary["fixture_directory"] = filmDirectory.path
            filmScope = " + \(films.count) same-frame production temporal export samples"
        } else {
            filmSummary["reason"] = "No film export directory supplied; pass it as the runner's third argument."
            filmScope = "; film measurements skipped because no export directory was supplied"
        }
        let scope = "Synthetic SDR extra prepass (\(checks.count) checks)\(filmScope); completed prepass timing only, not complete playback, whole-film or subjective display proof."
        let report:[String:Any]=["passed":passed,"checks":checks,"film_post_temporal":films,"film_post_temporal_summary":filmSummary,"completed_prepass_timing":timings,"scope":scope]
        try JSONSerialization.data(withJSONObject:report,options:[.prettyPrinted,.sortedKeys]).write(to:out)
        print("Cleaner \(checks.filter{$0["passed"] as? Bool == true}.count)/\(checks.count); \(out.path)")
        if !passed{exit(1)}
    }
}
