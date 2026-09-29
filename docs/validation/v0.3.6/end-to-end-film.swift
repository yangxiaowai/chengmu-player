import Foundation
import AVFoundation
import CoreImage
import CoreVideo
import Metal
import ImageIO
import UniformTypeIdentifiers
import CryptoKit
import CinemaCore

private enum AssessmentFailure: LocalizedError {
    case invalid(String)
    var errorDescription: String? { if case .invalid(let message) = self { return message }; return nil }
}

private struct Raster {
    let width: Int
    let height: Int
    let rgba: [Float]
}

/// Uses every RGB sample and all consecutive pairs. Values are 8-bit-equivalent
/// code units for readable errors, but neither candidate is quantized to RGBA8.
private struct Accumulator {
    var spatialSSE = 0.0, temporalSSE = 0.0
    var spatialCount = 0, temporalCount = 0
    var framePSNR: [Double] = []
    private var previousOutput: [Float]?
    private var previousReference: [Float]?
    mutating func append(_ output: Raster, reference: Raster) throws {
        guard output.width == reference.width, output.height == reference.height,
              output.rgba.count == reference.rgba.count else { throw AssessmentFailure.invalid("Metric grids differ") }
        var frameSSE = 0.0
        for i in stride(from: 0, to: output.rgba.count, by: 4) {
            for c in 0..<3 {
                let p = i+c
                guard output.rgba[p].isFinite, reference.rgba[p].isFinite else {
                    throw AssessmentFailure.invalid("Non-finite pixel")
                }
                let residual = (Double(output.rgba[p])-Double(reference.rgba[p]))*255
                frameSSE += residual*residual
                if let oldOutput = previousOutput, let oldReference = previousReference {
                    let observedDelta = Double(output.rgba[p]) - Double(oldOutput[p])
                    let referenceDelta = Double(reference.rgba[p]) - Double(oldReference[p])
                    let difference = (observedDelta - referenceDelta) * 255
                    temporalSSE += difference*difference
                    temporalCount += 1
                }
            }
        }
        let count = output.width*output.height*3
        spatialSSE += frameSSE; spatialCount += count
        framePSNR.append(Self.psnr(frameSSE/Double(count)))
        previousOutput = output.rgba; previousReference = reference.rgba
    }
    static func psnr(_ mse: Double) -> Double { 10*log10(255*255/max(mse,1e-20)) }
    var report: [String: Any] {
        let mse = spatialSSE/Double(max(1,spatialCount))
        let temporalMSE = temporalSSE/Double(max(1,temporalCount))
        return ["rgb_mse_code2":mse,"rgb_psnr_db":Self.psnr(mse),
                "temporal_derivative_error_mse_code2":temporalMSE,
                "temporal_derivative_error_rmse_code":sqrt(temporalMSE),
                "frames":framePSNR.count,"temporal_pairs":max(0,framePSNR.count-1),
                "rgb_sample_count":spatialCount,"temporal_rgb_sample_count":temporalCount,
                "per_frame_psnr_db":framePSNR]
    }
}

private struct ModeStats {
    var metric = Accumulator()
    var processMS: [Double] = [], withReadbackMS: [Double] = []
    var history = 0
    var resets: [[String: Any]] = []
    var labels = Set<String>()
    var report: [String: Any] {
        ["metrics":metric.report,"frames_using_history":history,"resets":resets,
         "actual_mode_labels":labels.sorted(),"pipeline_completed_ms":summarize(processMS),
         "pipeline_plus_same_readback_ms":summarize(withReadbackMS)]
    }
    private func summarize(_ xs:[Double])->[String:Any] {
        let sorted=xs.sorted(),warm=Array(xs.dropFirst())
        return ["count":xs.count,"mean":xs.reduce(0,+)/Double(max(1,xs.count)),
                "p95":sorted.isEmpty ? 0 : sorted[min(sorted.count-1,max(0,Int(ceil(Double(sorted.count)*0.95))-1))],
                "first":xs.first ?? 0,"excluding_first_mean":warm.reduce(0,+)/Double(max(1,warm.count)),
                "samples":xs]
    }
}

private final class FrameReader {
    let reader: AVAssetReader
    let output: AVAssetReaderTrackOutput
    let transform: CGAffineTransform
    private(set) var decoded = 0
    static let colorSpace = CGColorSpace(name: CGColorSpace.sRGB)!
    init(url:URL) async throws {
        let asset=AVURLAsset(url:url)
        guard let track=try await asset.loadTracks(withMediaType:.video).first else {
            throw AssessmentFailure.invalid("Missing video: \(url.path)")
        }
        transform=try await track.load(.preferredTransform)
        reader=try AVAssetReader(asset:asset)
        output=AVAssetReaderTrackOutput(track:track,outputSettings:[
            kCVPixelBufferPixelFormatTypeKey as String:kCVPixelFormatType_32BGRA,
            kCVPixelBufferMetalCompatibilityKey as String:true,
            kCVPixelBufferIOSurfacePropertiesKey as String:[:]
        ])
        output.alwaysCopiesSampleData=false
        guard reader.canAdd(output) else { throw AssessmentFailure.invalid("Cannot add output") }
        reader.add(output)
        guard reader.startReading() else { throw reader.error ?? AssessmentFailure.invalid("Cannot start reader") }
    }
    func next() throws -> (CVPixelBuffer,CMTime)? {
        guard let sample=output.copyNextSampleBuffer() else {
            guard reader.status == .completed else { throw reader.error ?? AssessmentFailure.invalid("Reader did not complete") }
            return nil
        }
        guard let buffer=CMSampleBufferGetImageBuffer(sample) else { throw AssessmentFailure.invalid("No decoded pixels") }
        let pts=CMSampleBufferGetPresentationTimeStamp(sample)
        guard pts.isNumeric else { throw AssessmentFailure.invalid("Invalid PTS") }
        // Local known-SDR fixture contract applied identically to both decoded assets.
        // No pixel copy, CI->bitmap reconstruction, or candidate-only colour override.
        CVBufferSetAttachment(buffer,kCVImageBufferColorPrimariesKey,kCVImageBufferColorPrimaries_ITU_R_709_2,.shouldPropagate)
        CVBufferSetAttachment(buffer,kCVImageBufferTransferFunctionKey,kCVImageBufferTransferFunction_sRGB,.shouldPropagate)
        CVBufferSetAttachment(buffer,kCVImageBufferCGColorSpaceKey,Self.colorSpace,.shouldPropagate)
        guard ColorFrameGate.decision(for:buffer) == .sdr else { throw AssessmentFailure.invalid("Fixture SDR tagging failed") }
        decoded += 1
        return (buffer,pts)
    }
    func image(_ buffer:CVPixelBuffer) throws -> CIImage {
        guard var result=ColorFrameGate.inputImage(for:buffer) else { throw AssessmentFailure.invalid("Fixture input image blocked") }
        result=result.transformed(by:transform)
        return result.transformed(by:CGAffineTransform(translationX:-result.extent.minX,y:-result.extent.minY))
    }
}

@available(macOS 26.0, *)
@main private struct EndToEndFilm {
    static let color=CGColorSpace(name:CGColorSpace.sRGB)!
    static let expectedFrames=96
    static let variants=["compressed-film","noisy-film","heavy-noisy-film"]
    static let modeNames=["restoration","compression"]
    static func main() async {
        do {
            guard CommandLine.arguments.count >= 3 else { throw AssessmentFailure.invalid("Usage: check report.json fixture-directory [source,hd720]") }
            let reportURL=URL(fileURLWithPath:CommandLine.arguments[1])
            let fixtures=URL(fileURLWithPath:CommandLine.arguments[2],isDirectory:true)
            let requested=(CommandLine.arguments.count>3 ? CommandLine.arguments[3] : "source").split(separator:",").map(String.init)
            guard !requested.isEmpty,Set(requested).count == requested.count,
                  requested.allSatisfy({["source","hd720"].contains($0)}),requested.contains("source") else {
                throw AssessmentFailure.invalid("Resolution list must contain source and optionally hd720; no 4K")
            }
            let resolutions=requested.map { EnhancementResolution(rawValue:$0)! }
            let framesURL=reportURL.deletingPathExtension().appendingPathExtension("frames")
            try FileManager.default.createDirectory(at:framesURL,withIntermediateDirectories:true)
            guard let device=MTLCreateSystemDefaultDevice(),let queue=device.makeCommandQueue() else { throw AssessmentFailure.invalid("No Metal device") }
            let context=CIContext(mtlDevice:device,options:[.cacheIntermediates:false,.workingColorSpace:CGColorSpace(name:CGColorSpace.extendedLinearSRGB)!])
            var results:[[String:Any]]=[]
            for resolution in resolutions {
                for variant in variants {
                    let result=try await assess(variant:variant,resolution:resolution,fixtures:fixtures,framesURL:framesURL,device:device,queue:queue,context:context)
                    results.append(result)
                    print("COMPLETED \(variant) / \(resolution.rawValue): \(result["comparison"]!)")
                    fflush(stdout)
                }
            }
            var inputHashes:[String:String]=[:]
            for name in ["clean-film"]+variants {
                inputHashes[name+".mp4"]=try hash(fixtures.appendingPathComponent(name+".mp4"))
            }
            var sourceHashes:[String:String]=[:]
            for path in ["Sources/CinemaApp/EnhancementPipeline.swift","Sources/CinemaApp/CompressionCleaner.swift","Sources/CinemaApp/TemporalRestorer.swift","Sources/CinemaApp/DetailScaler.swift","Sources/CinemaApp/VideoProcessingPolicy.swift","Sources/CinemaCore/EnhancementTarget.swift","Sources/CinemaCore/AdCleanupPolicy.swift","docs/validation/v0.3.6/end-to-end-film.swift"] {
                sourceHashes[path]=try hash(URL(fileURLWithPath:path))
            }
            let report:[String:Any]=[
                "schema_version":1,"validation_completed":true,"device":device.name,
                "operating_system":ProcessInfo.processInfo.operatingSystemVersionString,
                "scope":"Actual production EnhancementPipeline .restoration vs .compression, independent instances and temporal histories, identical decoded CV frame input in PTS order; all 96 frames and 95 consecutive pairs for each of three degradations of one movie excerpt. No quality-pass requirement or selected-frame exclusion. Not generalization, playback, audio sync or a formal timing benchmark.",
                "fixture_attribution":"(CC) Blender Foundation | mango.blender.org; Tears of Steel CC BY 3.0",
                "fixture_sha256":inputHashes,"source_sha256":sourceHashes,
                "color_and_metrics":[
                    "input":"AVAssetReader 32BGRA; both degraded and clean local known-SDR buffers explicitly tagged BT.709 primaries, sRGB transfer and sRGB CGColorSpace. Decoder pixel data fed directly to production pipelines; no bitmap-reconstructed candidate input.",
                    "reference":"Clean CV input interpreted with the same ColorFrameGate. source: one CI Lanczos 960x400 to 480x200. Optional hd720: same clean-to-target Lanczos geometry for both branches.",
                    "final_materialization":"Both candidates use production SDRTextureFormat.output RGB10A2 texture. Reference is also rendered to the identical RGB10A2 format. All three textures use the exact same CIImage(sRGB)->CIContext RGBAf(sRGB) readback. Final UNORM range conversion is common; no candidate-only clipping or added RGBA8 quantization in scoring.",
                    "spatial":"Pooled squared error over every RGB sample, alpha excluded; PSNR = 10log10(255^2/MSE), errors in equivalent 8bit code units.",
                    "temporal":"Pooled squared ((output[t]-output[t-1])-(reference[t]-reference[t-1])) across all 95 aligned pairs, preserving true reference motion.",
                    "timing":"Recorded processing and processing+common readback wall times; sequential alternating branch order by frame. Excludes decoder, metrics, reference materialization and PNG IO. No claim of sustained playback or independent randomized benchmark.",
                    "protection":"Default product AdCleanupSettings retained identically; compression always protects its normal lower subtitle band. No artificial clean-reference mask is supplied.",
                    "causality":"Decode exactly one observed frame at a time, pass same CV buffer/PTS/stream ID to two independent pipelines, finish both before decoding next; no future frames; clean reference never enters either candidate."
                ],"requested_resolutions":requested,"results":results,"png_directory":framesURL.path,
                "sample_png_frame":24,"quality_acceptance":"Informational, fail only structural/numeric prerequisites. Negative quality results are reported unchanged."
            ]
            try JSONSerialization.data(withJSONObject:report,options:[.prettyPrinted,.sortedKeys]).write(to:reportURL)
            print("WROTE \(reportURL.path)")
        } catch {
            fputs("End-to-end film assessment failed: \(error.localizedDescription)\n",stderr)
            exit(1)
        }
    }

    static func assess(variant:String,resolution:EnhancementResolution,fixtures:URL,framesURL:URL,device:MTLDevice,queue:MTLCommandQueue,context:CIContext) async throws->[String:Any] {
        let clean=try await FrameReader(url:fixtures.appendingPathComponent("clean-film.mp4"))
        let observed=try await FrameReader(url:fixtures.appendingPathComponent(variant+".mp4"))
        let baseline=try EnhancementPipeline(),candidate=try EnhancementPipeline()
        let stream=UUID()
        let target=resolution.target(width:480,height:200,automatic4K:false)
        var stats=["restoration":ModeStats(),"compression":ModeStats()]
        var count=0,previousPTS:Double?=nil
        var frameComparisons:[[String:Any]]=[]
        var firstPTS=0.0,lastPTS=0.0
        while let (pixel,pts)=try observed.next() {
            guard let (refPixel,refPTS)=try clean.next(),count<expectedFrames,
                  abs(pts.seconds-refPTS.seconds)<1e-5,
                  CVPixelBufferGetWidth(pixel)==480,CVPixelBufferGetHeight(pixel)==200,
                  CVPixelBufferGetWidth(refPixel)==960,CVPixelBufferGetHeight(refPixel)==400 else {
                throw AssessmentFailure.invalid("Grid/count/PTS mismatch at \(variant) frame \(count)")
            }
            if let previousPTS,abs(pts.seconds-previousPTS-1/24.0)>1e-5 { throw AssessmentFailure.invalid("Non-24fps interval") }
            previousPTS=pts.seconds
            if count==0 { firstPTS=pts.seconds };lastPTS=pts.seconds
            try autoreleasepool {
                let refImage=try clean.image(refPixel)
                let scaleY=Double(target.height)/refImage.extent.height
                let scaleX=Double(target.width)/refImage.extent.width
                let referenceImage=refImage.clampedToExtent().applyingFilter("CILanczosScaleTransform",parameters:["inputScale":scaleY,"inputAspectRatio":scaleX/scaleY]).cropped(to:CGRect(x:0,y:0,width:target.width,height:target.height))
                let refTexture=try renderReference(referenceImage,width:target.width,height:target.height,device:device,queue:queue,context:context)
                let reference=try readTexture(refTexture,context:context)
                var outputs:[String:Raster]=[:]
                // Alternate order to reduce systematic cache/thermal order bias. Histories
                // remain independent, and each sees exactly the same ordered current frame.
                for name in (count%2==0 ? modeNames : Array(modeNames.reversed())) {
                    let pipeline=name=="restoration" ? baseline : candidate
                    let mode:EnhancementMode=name=="restoration" ? .restoration : .compression
                    let start=CACurrentMediaTime()
                    let result=try pipeline.process(pixel,mode:mode,time:pts,displayTransform:observed.transform,streamID:stream,resolution:resolution)
                    guard result.width==target.width,result.height==target.height,result.texture.pixelFormat==SDRTextureFormat.output,
                          observed.decoded==count+1 else { throw AssessmentFailure.invalid("Output grid/format/causality mismatch") }
                    let output=try readTexture(result.texture,context:context)
                    let elapsed=(CACurrentMediaTime()-start)*1000
                    try stats[name]!.metric.append(output,reference:reference)
                    stats[name]!.processMS.append(result.milliseconds)
                    stats[name]!.withReadbackMS.append(elapsed)
                    stats[name]!.labels.insert(result.mode)
                    if result.usedTemporalHistory { stats[name]!.history += 1 }
                    if let reason=result.temporalResetReason { stats[name]!.resets.append(["frame":count,"reason":reason]) }
                    outputs[name]=output
                    if count==24 { try savePNG(output,to:framesURL.appendingPathComponent("\(variant)-\(resolution.rawValue)-\(name)-frame024.png")) }
                }
                guard let a=outputs["restoration"],let b=outputs["compression"] else { throw AssessmentFailure.invalid("Missing paired output") }
                var changeSSE=0.0,maxChange=0.0
                for i in stride(from:0,to:a.rgba.count,by:4) { for c in 0..<3 {
                    let d=(Double(b.rgba[i+c])-Double(a.rgba[i+c]))*255
                    changeSSE += d*d;maxChange=max(maxChange,abs(d))
                }}
                frameComparisons.append(["frame":count,"pts_seconds":pts.seconds,
                    "compression_minus_restoration_psnr_db":stats["compression"]!.metric.framePSNR.last!-stats["restoration"]!.metric.framePSNR.last!,
                    "output_rgb_difference_rms_code":sqrt(changeSSE/Double(target.width*target.height*3)),
                    "output_rgb_difference_max_abs_code":maxChange])
                if count==24 { try savePNG(reference,to:framesURL.appendingPathComponent("\(variant)-\(resolution.rawValue)-clean-frame024.png")) }
            }
            count += 1
        }
        guard try clean.next()==nil,count==expectedFrames,
              stats.values.allSatisfy({$0.metric.framePSNR.count==expectedFrames && $0.history>0}) else {
            throw AssessmentFailure.invalid("Incomplete sequence or unused temporal branch")
        }
        let base=stats["restoration"]!.metric.report,cand=stats["compression"]!.metric.report
        let delta=(cand["rgb_psnr_db"] as! Double)-(base["rgb_psnr_db"] as! Double)
        let temporalDelta=(cand["temporal_derivative_error_rmse_code"] as! Double)-(base["temporal_derivative_error_rmse_code"] as! Double)
        return ["variant":variant,"resolution":resolution.rawValue,"output":[target.width,target.height],
                "frames":count,"first_pts_seconds":firstPTS,"last_pts_seconds":lastPTS,
                "modes":stats.mapValues{$0.report},"per_frame_comparison":frameComparisons,
                "comparison":["compression_minus_restoration_psnr_db":delta,
                              "compression_minus_restoration_temporal_rmse_code":temporalDelta,
                              "spatial_metric_improved":delta>0,"temporal_metric_improved":temporalDelta<0,
                              "frames_with_higher_psnr":frameComparisons.filter{($0["compression_minus_restoration_psnr_db"] as! Double)>0}.count,
                              "history_frame_counts_equal":stats["restoration"]!.history==stats["compression"]!.history]]
    }

    static func renderReference(_ image:CIImage,width:Int,height:Int,device:MTLDevice,queue:MTLCommandQueue,context:CIContext)throws->MTLTexture {
        let desc=MTLTextureDescriptor.texture2DDescriptor(pixelFormat:SDRTextureFormat.output,width:width,height:height,mipmapped:false)
        desc.usage=[.shaderRead,.shaderWrite,.renderTarget]
        guard let texture=device.makeTexture(descriptor:desc),let command=queue.makeCommandBuffer() else { throw AssessmentFailure.invalid("Reference render allocation") }
        context.render(image,to:texture,commandBuffer:command,bounds:CGRect(x:0,y:0,width:width,height:height),colorSpace:color)
        command.commit();command.waitUntilCompleted()
        guard command.status == .completed else { throw AssessmentFailure.invalid("Reference GPU render failed") }
        return texture
    }
    static func readTexture(_ texture:MTLTexture,context:CIContext)throws->Raster {
        guard texture.pixelFormat==SDRTextureFormat.output,
              let image=CIImage(mtlTexture:texture,options:[.colorSpace:color]) else { throw AssessmentFailure.invalid("Cannot read common output texture") }
        var rgba=[Float](repeating:0,count:texture.width*texture.height*4)
        context.render(image,toBitmap:&rgba,rowBytes:texture.width*16,bounds:CGRect(x:0,y:0,width:texture.width,height:texture.height),format:.RGBAf,colorSpace:color)
        return Raster(width:texture.width,height:texture.height,rgba:rgba)
    }
    static func savePNG(_ raster:Raster,to url:URL)throws {
        let bytes=raster.rgba.map{UInt8(clamping:Int((max(0,min(1,$0))*255).rounded()))}
        guard let provider=CGDataProvider(data:Data(bytes) as CFData),
              let image=CGImage(width:raster.width,height:raster.height,bitsPerComponent:8,bitsPerPixel:32,bytesPerRow:raster.width*4,space:color,bitmapInfo:CGBitmapInfo(rawValue:CGImageAlphaInfo.premultipliedLast.rawValue),provider:provider,decode:nil,shouldInterpolate:false,intent:.defaultIntent),
              let destination=CGImageDestinationCreateWithURL(url as CFURL,UTType.png.identifier as CFString,1,nil) else { throw AssessmentFailure.invalid("PNG allocation") }
        CGImageDestinationAddImage(destination,image,nil)
        guard CGImageDestinationFinalize(destination) else { throw AssessmentFailure.invalid("PNG write") }
    }
    static func hash(_ url:URL)throws->String { SHA256.hash(data:try Data(contentsOf:url)).map{String(format:"%02x",$0)}.joined() }
}
