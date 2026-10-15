import CoreImage
import CoreVideo
import DKCore
import Foundation
import Metal
import QuartzCore

/// Metal 多屏实时合成器（方案 M2.5）：
/// 各路 CVPixelBuffer → MTLTexture → 按布局画布拼接 → 输出单帧 CVPixelBuffer 直入编码器。
/// 着色器经 newLibrary(source:) 运行时编译，不依赖本机金属工具链；
/// 编译失败回退 CoreGraphics CPU 合成（功能等价、性能降级，UI 需提示）。
public final class MetalCompositor: @unchecked Sendable {
    private let device: MTLDevice?
    private let pipeline: MTLRenderPipelineState?
    private let commandQueue: MTLCommandQueue?
    private let textureCache: CVMetalTextureCache?
    private var useCGFallback: Bool
    private var layout: ComposeLayout

    private static let mslSource = """
    #include <metal_stdlib>
    using namespace metal;
    struct VertOut {
        float4 pos [[position]];
        float2 uv;
    };
    vertex VertOut compose_vertex(uint vid [[vertex_id]]) {
        // 全屏三角形：覆盖 NDC [-1,3]x[-1,1] 的三顶点
        float2 p = float2((vid << 1) & 2, vid & 2) * 2.0 - float2(1.0, 1.0);
        VertOut o;
        o.pos = float4(p, 0, 1);
        // 纹理坐标 y 翻转（画布左上原点 → Metal NDC 左下）
        o.uv = float2(p.x * 0.5 + 0.5, 0.5 - p.y * 0.5);
        return o;
    }
    // 片元采样单路纹理；多路通过各自 viewport 内重复绘制完成
    fragment half4 compose_fragment(VertOut vin [[stage_in]],
                                    texture2d<half> tex [[texture(0)]]) {
        constexpr sampler s(coord::normalized, filter::linear, address::clamp_to_edge);
        return tex.sample(s, vin.uv);
    }
    """

    public convenience init(layout: ComposeLayout) {
        self.init(layout: layout, forceCPUFallback: false)
    }

    /// `forceCPUFallback=true` 直接走 CoreGraphics CPU 合成路径（方案 M2.5/§四「性能降级」）：
    /// 用于无可用 GPU / 需要验证回退一致性的场景；不初始化 Metal 管线。
    public init(layout: ComposeLayout, forceCPUFallback: Bool) {
        self.layout = layout
        guard !forceCPUFallback else {
            self.device = nil
            self.commandQueue = nil
            self.textureCache = nil
            self.pipeline = nil
            self.useCGFallback = true
            DKLog.compose.info("显式采用 CPU(CG) 合成路径")
            return
        }
        let dev = MTLCreateSystemDefaultDevice()
        self.device = dev
        self.commandQueue = dev?.makeCommandQueue()
        self.useCGFallback = dev == nil

        if let dev {
            var cache: CVMetalTextureCache?
            CVMetalTextureCacheCreate(kCFAllocatorDefault, nil, dev, nil, &cache)
            self.textureCache = cache
            if let source = try? dev.makeLibrary(source: Self.mslSource, options: nil) {
                let desc = MTLRenderPipelineDescriptor()
                desc.vertexFunction = source.makeFunction(name: "compose_vertex")
                desc.fragmentFunction = source.makeFunction(name: "compose_fragment")
                desc.colorAttachments[0].pixelFormat = .bgra8Unorm
                self.pipeline = try? dev.makeRenderPipelineState(descriptor: desc)
                self.useCGFallback = self.pipeline == nil
            } else {
                self.pipeline = nil
                self.useCGFallback = true
            }
        } else {
            self.textureCache = nil
            self.pipeline = nil
            self.useCGFallback = true
        }
        if useCGFallback {
            DKLog.compose.error("Metal 合成不可用，回退 CPU(CG) 合成")
        }
    }

    public var isMetalActive: Bool { !useCGFallback }

    /// 布局热更新（录制前编辑完成后设置）
    public func setLayout(_ layout: ComposeLayout) { self.layout = layout.clamped() }

    /// 合成一帧：inputs 为各屏最新 BGRA/NV12 pixel buffer；输出 BGRA buffer（送编码器）
    public func compose(_ inputs: [UInt32: CVPixelBuffer]) -> CVPixelBuffer? {
        let canvas = layout.clamped().canvas
        guard !inputs.isEmpty else { return nil }
        if useCGFallback { return composeCG(inputs, canvas: canvas) }
        return composeMetal(inputs, canvas: canvas)
    }

    // MARK: - Metal 路径

    private func composeMetal(_ inputs: [UInt32: CVPixelBuffer], canvas: PixelSize) -> CVPixelBuffer? {
        guard let device, let pipeline, let commandQueue, let textureCache else { return nil }

        // CVMetalTextureGetTexture 返回的 MTLTexture 由其 CVMetalTexture 盒对象持有 backing；
        // 必须在 GPU 完成前保持这些盒存活，否则纹理失效 → 渲染全黑（本函数用 kept 数组持有）。
        var kept: [CVMetalTexture] = []

        // 输出像素缓冲来自池（BGRA、IOSurface 后端），包装为纹理后作为渲染目标
        let outPB = targetPixelBuffer(canvas: canvas)
        guard let outTexture = metalTexture(from: outPB, device: device, cache: textureCache,
                                            keep: &kept) else { return nil }

        let pass = MTLRenderPassDescriptor()
        pass.colorAttachments[0].texture = outTexture
        pass.colorAttachments[0].loadAction = .clear
        pass.colorAttachments[0].storeAction = .store
        pass.colorAttachments[0].clearColor = MTLClearColor(red: 0, green: 0, blue: 0, alpha: 1)

        guard let cmd = commandQueue.makeCommandBuffer(),
              let enc = cmd.makeRenderCommandEncoder(descriptor: pass) else { return nil }

        for placement in layout.placements {
            guard let src = inputs[placement.displayID] else { continue }
            guard let srcTex = metalTexture(from: src, device: device, cache: textureCache,
                                            keep: &kept) else { continue }
            let r = placement.pixelRect(canvas: canvas)
            // Metal viewport 只控制 NDC→像素映射，不自动裁剪：需显式 scissor 才能按布局定位，
            // 避免重叠/越界摆放时相邻屏相互覆盖。
            enc.setScissorRect(MTLScissorRect(x: r.x, y: canvas.height - r.y - r.h,
                                              width: max(1, r.w), height: max(1, r.h)))
            // Metal viewport 原点在左下：y 翻转
            enc.setViewport(MTLViewport(originX: Double(r.x), originY: Double(canvas.height - r.y - r.h),
                                         width: Double(r.w), height: Double(r.h),
                                         znear: 0, zfar: 1))
            enc.setRenderPipelineState(pipeline)
            enc.setFragmentTexture(srcTex, index: 0)
            enc.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 3)
        }
        enc.endEncoding()
        cmd.commit()
        // 等待 GPU 完成：保证返回的 outPB 已是成品帧，下游零拷贝编码器不会读到半成品
        // （方案第七节合并验收：各屏画面位置一致、≤1 帧对齐偏差）
        cmd.waitUntilCompleted()
        // waitUntilCompleted 之后再释放纹理盒：在此之前 kept 必须存活
        CVMetalTextureCacheFlush(textureCache, 0)
        kept.removeAll(keepingCapacity: false)
        return outPB
    }

    /// 输出用目标像素缓冲（由池分配，BGRA）
    private var outputPool: CVPixelBufferPool?
    private var poolKey = ""
    private func targetPixelBuffer(canvas: PixelSize) -> CVPixelBuffer {
        let key = "\(canvas.width)x\(canvas.height)"
        let attrs: [String: Any] = [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
            kCVPixelBufferWidthKey as String: canvas.width,
            kCVPixelBufferHeightKey as String: canvas.height,
            kCVPixelBufferMetalCompatibilityKey as String: true,
            kCVPixelBufferIOSurfacePropertiesKey as String: [:],
        ]
        if poolKey != key || outputPool == nil {
            var pool: CVPixelBufferPool?
            CVPixelBufferPoolCreate(kCFAllocatorDefault, nil, attrs as CFDictionary, &pool)
            outputPool = pool
            poolKey = key
        }
        var pb: CVPixelBuffer?
        if let pool = outputPool { CVPixelBufferPoolCreatePixelBuffer(kCFAllocatorDefault, pool, &pb) }
        if pb == nil {
            CVPixelBufferCreate(kCFAllocatorDefault, canvas.width, canvas.height,
                                kCVPixelFormatType_32BGRA, attrs as CFDictionary, &pb)
        }
        return pb!
    }

    private func metalTexture(from pb: CVPixelBuffer, device: MTLDevice,
                              cache: CVMetalTextureCache,
                              keep: inout [CVMetalTexture]) -> MTLTexture? {
        let w = CVPixelBufferGetWidth(pb), h = CVPixelBufferGetHeight(pb)
        let fmt = CVPixelBufferGetPixelFormatType(pb)
        // 合成路径约定输入为 BGRA（录制器在合并模式下将 SCStreamConfiguration.pixelFormat 设为 BGRA）
        guard fmt == kCVPixelFormatType_32BGRA else { return nil }
        var ref: CVMetalTexture?
        let st = CVMetalTextureCacheCreateTextureFromImage(kCFAllocatorDefault, cache, pb, nil, .bgra8Unorm, w, h, 0, &ref)
        guard st == noErr, let ref else { return nil }
        // 持有 CVMetalTexture 盒以保证返回的 MTLTexture backing 存活
        keep.append(ref)
        return CVMetalTextureGetTexture(ref)
    }

    // MARK: - CPU 回退路径

    private func composeCG(_ inputs: [UInt32: CVPixelBuffer], canvas: PixelSize) -> CVPixelBuffer? {
        var out: CVPixelBuffer?
        let attrs: [String: Any] = [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
            kCVPixelBufferIOSurfacePropertiesKey as String: [:],
        ]
        let st = CVPixelBufferCreate(kCFAllocatorDefault, canvas.width, canvas.height,
                                     kCVPixelFormatType_32BGRA, attrs as CFDictionary, &out)
        guard st == noErr, let out else { return nil }
        CVPixelBufferLockBaseAddress(out, [])
        defer { CVPixelBufferUnlockBaseAddress(out, []) }
        guard let base = CVPixelBufferGetBaseAddress(out),
              let ctx = CGContext(data: base, width: canvas.width, height: canvas.height,
                                  bitsPerComponent: 8, bytesPerRow: CVPixelBufferGetBytesPerRow(out),
                                  space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                  bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue
                                    | CGBitmapInfo.byteOrder32Little.rawValue) else { return out }
        ctx.setFillColor(.black)
        ctx.fill(CGRect(x: 0, y: 0, width: canvas.width, height: canvas.height))
        for placement in layout.placements {
            guard let src = inputs[placement.displayID] else { continue }
            guard let img = pixelBufferToCGImage(src) else { continue }
            let r = placement.pixelRect(canvas: canvas)
            // CG 坐标左下原点：y 翻转
            ctx.draw(img, in: CGRect(x: r.x, y: canvas.height - r.y - r.h, width: r.w, height: r.h))
        }
        return out
    }

    private func pixelBufferToCGImage(_ pb: CVPixelBuffer) -> CGImage? {
        let img = CIImage(cvPixelBuffer: pb)
        return Self.ciContext.createCGImage(img, from: img.extent)
    }

    private static let ciContext = CIContext()
}
