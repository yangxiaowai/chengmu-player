import Foundation
import CoreImage
import Metal
import CinemaCore

/// Optional, source-sized SDR cleanup after temporal denoising. Inspired by constrained
/// differences, not the AV1 codec CDEF filter. No sharpening and no frame history.
/// sRGB code-value input/output in half-float storage; HDR never reaches this stage.
final class CompressionCleaner {
    private let device: MTLDevice
    private let kernel: MTLComputePipelineState
    private let colorSpace = CGColorSpace(name: CGColorSpace.sRGB)!
    private var input: MTLTexture?

    init(device: MTLDevice) throws {
        self.device = device
        let library = try device.makeLibrary(source: Self.source, options: nil)
        guard let function = library.makeFunction(name: "compressionClean") else {
            throw EnhancementError.unavailable("压缩抑噪内核不可用")
        }
        kernel = try device.makeComputePipelineState(function: function)
    }

    /// Serial worker only. Output owns its texture and stays immutable after return.
    func process(_ image: CIImage, protectedRegions: [NormalizedVideoRect], context: CIContext, queue: MTLCommandQueue) throws -> CIImage {
        let extent = image.extent
        guard extent.minX == 0, extent.minY == 0, extent.width.isFinite, extent.height.isFinite,
              extent.width >= 1, extent.height >= 1, extent.width <= 16384, extent.height <= 16384,
              protectedRegions.count <= AdCleanupPolicy.maxProtectedRegions,
              protectedRegions.allSatisfy(AdCleanupPolicy.isValid) else {
            throw EnhancementError.unavailable("压缩抑噪尺寸或字幕保护区无效，保留原片")
        }
        let width = Int(extent.width), height = Int(extent.height)
        // Always protect the usual lower caption band. Extra selections may extend it;
        // they must never silently remove the baseline protection. Coordinates are CI's
        // bottom-left after the video's display transform, rounded OUTWARD, unlike ad crops.
        var regions = [AdCleanupSettings.defaultProtection]
        for region in protectedRegions where !regions.contains(region) { regions.append(region) }
        var rectangles = regions.map { region in
            SIMD4<Float>(Float(floor(region.x * Double(width)) - 2),
                         Float(floor((1 - region.y - region.height) * Double(height)) - 2),
                         Float(ceil((region.x + region.width) * Double(width)) + 2),
                         Float(ceil((1 - region.y) * Double(height)) + 2))
        }
        var count = UInt32(rectangles.count)
        func allocate() -> MTLTexture? {
            let descriptor = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .rgba16Float, width: width, height: height, mipmapped: false)
            descriptor.storageMode = .private; descriptor.usage = [.shaderRead, .shaderWrite, .renderTarget]
            return device.makeTexture(descriptor: descriptor)
        }
        if input?.width != width || input?.height != height { input = allocate() }
        guard let input, let output = allocate(), let command = queue.makeCommandBuffer() else {
            throw EnhancementError.unavailable("压缩抑噪缓冲分配失败")
        }
        context.render(image, to: input, commandBuffer: command, bounds: extent, colorSpace: colorSpace)
        guard let encoder = command.makeComputeCommandEncoder() else { throw EnhancementError.unavailable("压缩抑噪提交失败") }
        encoder.setComputePipelineState(kernel)
        encoder.setTexture(input, index: 0); encoder.setTexture(output, index: 1)
        encoder.setBytes(&rectangles, length: rectangles.count * MemoryLayout<SIMD4<Float>>.stride, index: 0)
        encoder.setBytes(&count, length: MemoryLayout<UInt32>.size, index: 1)
        let x = kernel.threadExecutionWidth, y = min(8, kernel.maxTotalThreadsPerThreadgroup / x)
        encoder.dispatchThreads(MTLSize(width: width, height: height, depth: 1), threadsPerThreadgroup: MTLSize(width: x, height: y, depth: 1))
        encoder.endEncoding(); command.commit(); command.waitUntilCompleted()
        guard command.status == .completed, let result = CIImage(mtlTexture: output, options: [.colorSpace: colorSpace]) else {
            throw EnhancementError.unavailable(command.error?.localizedDescription ?? "压缩抑噪执行失败")
        }
        return result
    }

    private static let source = """
    #include <metal_stdlib>
    using namespace metal;
    float luminance(float3 rgb) { return dot(rgb,float3(0.2126,0.7152,0.0722))*255.0; }
    kernel void compressionClean(texture2d<float,access::read> input [[texture(0)]],
                                 texture2d<float,access::write> output [[texture(1)]],
                                 constant float4 *rectangles [[buffer(0)]], constant uint &count [[buffer(1)]],
                                 uint2 tid [[thread_position_in_grid]]) {
        if (tid.x>=output.get_width() || tid.y>=output.get_height()) return;
        float4 center=input.read(tid);
        float protection=1.0;
        for(uint i=0;i<count;++i) {
            float4 r=rectangles[i];float2 p=float2(tid)+0.5;
            float distance=max(max(r.x-p.x,p.x-r.z),max(r.y-p.y,p.y-r.w));
            protection=min(protection,smoothstep(0.0,2.0,distance));
        }
        if (protection==0.0) { output.write(center,tid); return; }
        const int2 offsets[8]={int2(0,-1),int2(0,1),int2(-1,0),int2(1,0),
                               int2(-1,-1),int2(1,1),int2(1,-1),int2(-1,1)};
        float y=luminance(center.rgb),difference[8],lo=y,hi=y;
        int2 bounds=int2(input.get_width()-1,input.get_height()-1);
        for(int i=0;i<8;++i) {
            float n=luminance(input.read(uint2(clamp(int2(tid)+offsets[i],int2(0),bounds))).rgb);
            difference[i]=n-y;lo=min(lo,n);hi=max(hi,n);
        }
        float minimum=INFINITY,maximum=0.0;
        for(int i=0;i<8;i+=2){float cost=abs(difference[i])+abs(difference[i+1]);minimum=min(minimum,cost);maximum=max(maximum,cost);}
        // Coherent lines retain even their weak contrast; strength is deliberately NOT
        // added to this denominator, which would misclassify faint texture as flat noise.
        float coherence=(maximum-minimum)/(maximum+minimum+0.001);
        float gate=(1.0-smoothstep(0.50,0.85,coherence))*(1.0-smoothstep(12.0,32.0,maximum));
        float sum=0.0;
        for(int i=0;i<8;++i){float d=difference[i];float constrained=sign(d)*min(abs(d),max(0.0,4.0-0.5*abs(d)));sum+=(i<4?2.0:1.0)*constrained;}
        float correction=clamp(gate*sum/16.0,-2.0,2.0)*protection;
        correction=clamp(y+correction,lo,hi)-y;
        // Preserve extended SDR values until the existing final render. Clipping only
        // this branch could otherwise masquerade as denoising in the quality comparison.
        output.write(float4(center.rgb+correction/255.0,center.a),tid);
    }
    """
}
