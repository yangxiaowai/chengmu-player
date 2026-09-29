// EXPERIMENT ONLY: scalar sRGB brightness contrast gate; not production or GPU-validated.
import Foundation
import Metal
import CoreImage

/// SDR, contrast-gated cubic interpolation with a nearest-neighbour envelope.
/// This is spatial interpolation, not a learned reconstruction network.
/// Worker-owned: encode serially and finish the command before reusing the source texture.
/// Each result owns a separate texture so a displayed frame is never overwritten.
final class DetailScaler {
    private enum Failure: LocalizedError {
        case unavailable(String)
        var errorDescription: String? { switch self { case .unavailable(let reason): return reason } }
    }
    private let device: MTLDevice
    private let kernel: MTLComputePipelineState
    private var inputCache: MTLTexture?
    private let linear = CGColorSpace(name: CGColorSpace.extendedLinearSRGB)!
    init(device: MTLDevice) throws {
        self.device = device
        let library = try device.makeLibrary(source: Self.source, options: nil)
        guard let function = library.makeFunction(name: "detailScale") else { throw Failure.unavailable("细节缩放计算内核不可用") }
        kernel = try device.makeComputePipelineState(function: function)
    }
    func encode(_ image: CIImage, width: Int, height: Int, context: CIContext, command: MTLCommandBuffer) throws -> MTLTexture {
        let extent = image.extent
        guard extent.width.isFinite, extent.height.isFinite, extent.width > 0, extent.height > 0,
              extent.width <= 16384, extent.height <= 16384, width > 0, height > 0,
              width <= 16384, height <= 16384, extent.minX == 0, extent.minY == 0 else {
            throw Failure.unavailable("细节缩放画面尺寸无效")
        }
        let sourceWidth = Int(extent.width), sourceHeight = Int(extent.height)
        guard width >= sourceWidth, height >= sourceHeight else {
            throw Failure.unavailable("细节缩放仅用于放大画面")
        }

        func allocate(_ width: Int, _ height: Int, _ format: MTLPixelFormat) -> MTLTexture? {
            let d = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: format, width: width, height: height, mipmapped: false)
            d.usage = [.shaderRead, .shaderWrite, .renderTarget]; d.storageMode = .private
            return device.makeTexture(descriptor: d)
        }
        if inputCache?.width != sourceWidth || inputCache?.height != sourceHeight { inputCache = allocate(sourceWidth, sourceHeight, .rgba16Float) }
        guard let input = inputCache, let output = allocate(width, height, .bgra8Unorm) else { throw Failure.unavailable("细节缩放纹理分配失败") }
        context.render(image, to: input, commandBuffer: command, bounds: image.extent, colorSpace: linear)
        guard let encoder = command.makeComputeCommandEncoder() else { throw Failure.unavailable("细节缩放计算提交失败") }
        encoder.setComputePipelineState(kernel); encoder.setTexture(input, index: 0); encoder.setTexture(output, index: 1)
        let w = kernel.threadExecutionWidth, h = min(8, kernel.maxTotalThreadsPerThreadgroup / w)
        encoder.dispatchThreads(MTLSize(width: width, height: height, depth: 1), threadsPerThreadgroup: MTLSize(width: w, height: h, depth: 1))
        encoder.endEncoding()
        return output
    }
    private static let source = """
    #include <metal_stdlib>
    using namespace metal;
    float4 weights(float t) {
        float t2=t*t, t3=t2*t;
        return float4(-0.5*t+t2-0.5*t3, 1.0-2.5*t2+1.5*t3,
                      0.5*t+2.0*t2-1.5*t3, -0.5*t2+0.5*t3);
    }
    float4 readClamp(texture2d<float, access::read> image, int2 p) {
        return image.read(uint2(clamp(p, int2(0), int2(image.get_width()-1,image.get_height()-1))));
    }
    // Throwaway gate-domain candidate. Interpolation and the local envelope stay linear.
    // This is OETF(linear luminance), a perceptual brightness proxy, not exact RGB luma Y'.
    float perceptualBrightness(float value) {
        float v=clamp(value,0.0,1.0);
        return v<=0.0031308 ? 12.92*v : 1.055*pow(v,1.0/2.4)-0.055;
    }
    kernel void detailScale(texture2d<float, access::read> input [[texture(0)]],
                            texture2d<float, access::write> output [[texture(1)]], uint2 tid [[thread_position_in_grid]]) {
        if (tid.x>=output.get_width() || tid.y>=output.get_height()) return;
        float2 scale=float2(input.get_width(),input.get_height())/float2(output.get_width(),output.get_height());
        float2 p=(float2(tid)+0.5)*scale-0.5, f=fract(p);
        int2 base=int2(floor(p));
        float4 wx=weights(f.x), wy=weights(f.y), cubic=0.0, previousLuma=0.0;
        float gx=0.0, gy=0.0, ax=0.0, ay=0.0;
        const float3 lumaWeights=float3(0.2126,0.7152,0.0722);
        for (int y=0;y<4;++y) {
            float4 row=0.0, rowLuma=0.0;
            for (int x=0;x<4;++x) {
                float4 sample=readClamp(input,base+int2(x-1,y-1));
                row+=sample*wx[x]; rowLuma[x]=dot(sample.rgb,lumaWeights);
            }
            float dx=rowLuma.z-rowLuma.y; gx+=dx; ax+=abs(dx);
            if (y==1) previousLuma=rowLuma;
            if (y==2) {float4 dy=rowLuma-previousLuma;gy=dot(dy,float4(1));ay=dot(abs(dy),float4(1));}
            cubic+=row*wy[y];
        }
        float4 a=readClamp(input,base), b=readClamp(input,base+int2(1,0));
        float4 c=readClamp(input,base+int2(0,1)), d=readClamp(input,base+int2(1,1));
        float4 lo=min(min(a,b),min(c,d)), hi=max(max(a,b),max(c,d));
        float4 bilinear=mix(mix(a,b,f.x),mix(c,d,f.x),f.y);
        // Restrict the cubic's negative lobes to the local 2x2 range. Low-contrast
        // regions use bilinear to avoid emphasizing residual noise after denoising.
        float contrast=perceptualBrightness(dot(hi.rgb,lumaWeights))-perceptualBrightness(dot(lo.rgb,lumaWeights));
        float coherence=max(gx*gx/(ax*ax+1e-12),gy*gy/(ay*ay+1e-12));
        float confidence=0.8*smoothstep(0.06,0.14,contrast)*smoothstep(0.45,0.90,coherence);
        float4 value=mix(bilinear,clamp(cubic,lo,hi),confidence);
        // Final SDR output is sRGB code values, matching the normal pipeline render.
        float3 rgb=clamp(value.rgb,0.0,1.0);
        value.rgb=select(1.055*pow(rgb,float3(1.0/2.4))-0.055,12.92*rgb,rgb<=0.0031308);
        value.a=1.0;
        output.write(value,tid);
    }
    """
}
