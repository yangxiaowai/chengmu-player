import Foundation
import AVFoundation
import CoreImage
import CoreVideo
import Metal
import ImageIO
import UniformTypeIdentifiers
import CryptoKit

private enum FilmFailure: LocalizedError {
    case invalid(String)
    var errorDescription: String? { if case .invalid(let message) = self { return message }; return nil }
}

private final class FrameReader {
    let asset: AVURLAsset
    let reader: AVAssetReader
    let output: AVAssetReaderTrackOutput
    let transform: CGAffineTransform
    private(set) var framesDecoded = 0

    init(url: URL) async throws {
        asset = AVURLAsset(url: url)
        guard let track = try await asset.loadTracks(withMediaType: .video).first else {
            throw FilmFailure.invalid("No video track: \(url.path)")
        }
        transform = try await track.load(.preferredTransform)
        reader = try AVAssetReader(asset: asset)
        output = AVAssetReaderTrackOutput(track: track, outputSettings: [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
            kCVPixelBufferMetalCompatibilityKey as String: true,
            kCVPixelBufferIOSurfacePropertiesKey as String: [:]
        ])
        output.alwaysCopiesSampleData = false
        guard reader.canAdd(output) else { throw FilmFailure.invalid("Cannot add video reader") }
        reader.add(output)
        guard reader.startReading() else { throw reader.error ?? FilmFailure.invalid("Cannot start video reader") }
    }

    func next() throws -> (CIImage, CMTime, CVPixelBuffer)? {
        guard let sample = output.copyNextSampleBuffer() else {
            guard reader.status == .completed else { throw reader.error ?? FilmFailure.invalid("Reader ended unexpectedly") }
            return nil
        }
        guard let pixel = CMSampleBufferGetImageBuffer(sample) else { throw FilmFailure.invalid("Missing decoded image") }
        let time = CMSampleBufferGetPresentationTimeStamp(sample)
        guard time.isNumeric else { throw FilmFailure.invalid("Missing numeric presentation timestamp") }
        var image = CIImage(cvPixelBuffer: pixel).transformed(by: transform)
        image = image.transformed(by: CGAffineTransform(translationX: -image.extent.minX, y: -image.extent.minY))
        framesDecoded += 1
        return (image, time, pixel)
    }
}


@available(macOS 26.0, *) @main struct Export {
 static func main() async throws {
  let root=URL(fileURLWithPath:CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : ".build/restoration-lab")
  let out=URL(fileURLWithPath:CommandLine.arguments.count > 2 ? CommandLine.arguments[2] : ".build/repair-v036/post-temporal")
  try FileManager.default.createDirectory(at:out,withIntermediateDirectories:true)
  let context=CIContext(mtlDevice:MTLCreateSystemDefaultDevice()!,options:[.cacheIntermediates:false,.workingColorSpace:CGColorSpace(name:CGColorSpace.extendedLinearSRGB)!])
  let color=CGColorSpace(name:CGColorSpace.sRGB)!
  func save(_ image:CIImage,_ name:String)throws {
   var rgba=[Float](repeating:0,count:480*200*4)
   context.render(image,toBitmap:&rgba,rowBytes:480*16,bounds:CGRect(x:0,y:0,width:480,height:200),format:.RGBAf,colorSpace:color)
   try rgba.withUnsafeBytes{Data($0)}.write(to:out.appendingPathComponent(name+".rgba32f"))
  }
  for name in ["clean-film","compressed-film","noisy-film","heavy-noisy-film"] {
   let reader=try await FrameReader(url:root.appendingPathComponent(name+".mp4"))
   let restorer=try TemporalRestorer(width:480,height:200,context:context),stream=UUID()
   var index=0
   while let (image,time,_)=try reader.next() {
    if name=="clean-film" {
     if [12,24,48,72,84].contains(index) {
      let reduced=image.applyingFilter("CILanczosScaleTransform",parameters:["inputScale":0.5,"inputAspectRatio":1.0])
      try save(reduced,"clean-\(index)")
     }
    }else{
     let restored=try restorer.process(image,time:time,streamID:stream)
     if [12,24,48,72,84].contains(index){try save(image,"\(name)-raw-\(index)");try save(restored.image,"\(name)-temporal-\(index)")}
    }
    index+=1
   }
   print("exported \(name) \(index) frames processed")
  }
 }
}
