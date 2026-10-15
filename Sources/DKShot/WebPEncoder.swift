import CoreGraphics
import DKCore
import Foundation
#if DISYNK_LIBVPX
import LibVPX
#endif

/// 单帧 WebP（lossy / VP8）编码：libvpx VP8 软编一个强制关键帧，包进 RIFF/WEBP 容器。
///
/// 背景：macOS 15 的 ImageIO 实测**不能**编码 WebP（`CGImageDestinationCreateWithURL("public.webp")`
/// 返回 nil），而项目已为 WebM 导出 vendor 了 libvpx——WebP 的 VP8 码流与 WebM 的 VP8 关键帧
/// 同属一种比特流格式（WebP 规范即「VP8 Lossy」chunk），故复用 libvpx 编一张静帧、
/// 手写 20 字节 RIFF 头即可产出标准 WebP，无需引入 libwebp。
///
/// 限制：VP8 有损 chunk 不带 alpha（透明像素压平白底）；宽高须偶数（VP8 宏块约束，奇数裁 1 像素）。
/// 未装配 libvpx 的构建（默认 `swift build`）：`isAvailable=false`，`encode` 显式抛错，调用方回退 PNG。
public enum WebPEncoder {
    /// 本构建是否具备 WebP 编码能力（libvpx 装配门控，见 Scripts/build.sh）。
    public static var isAvailable: Bool {
        #if DISYNK_LIBVPX
        return true
        #else
        return false
        #endif
    }

    /// 编码为 WebP 字节流。quality 0–100（映射到 VP8 量化器，80≈日常截图清晰度）。
    public static func encode(_ image: CGImage, quality: Int = 80) throws -> Data {
        #if DISYNK_LIBVPX
        let w = max(2, image.width & ~1)
        let h = max(2, image.height & ~1)
        guard w >= 2, h >= 2, w <= 16382, h <= 16382 else {
            throw DKError.other("WebP 尺寸超限（须 ≤16383）：\(image.width)×\(image.height)")
        }
        var yuv = [UInt8]()
        try rgbaToI420(image, width: w, height: h, into: &yuv)

        let iface = vpx_codec_vp8_cx()
        var cfg = vpx_codec_enc_cfg_t()
        guard vpx_codec_enc_config_default(iface, &cfg, 0) == VPX_CODEC_OK else {
            throw DKError.other("WebP：libvpx 默认配置失败")
        }
        cfg.g_w = UInt32(w)
        cfg.g_h = UInt32(h)
        cfg.g_timebase.num = 1
        cfg.g_timebase.den = 1000
        cfg.g_lag_in_frames = 0
        // 恒定质量走 VBR + qmin=qmax 钉死：libvpx 码控对所有模式都把每帧量化器
        // 钳在 [rc_min_quantizer, rc_max_quantizer] 内，min=max 即恒定量化的 CQ 效果。
        // （不能用 VPX_Q：其校验默认 cq_level=0 会落在区间外报“cq_level out of range”，
        //  而 cq_level 只能经变参宏 vpx_codec_control 设置，Swift 无法导入。）
        cfg.rc_end_usage = VPX_VBR
        let q = min(100, max(0, quality))
        // VP8 量化器范围 0…127；min=max 钉死→单帧输出量化器恒为映射值（与 libwebp 同族曲线）。
        let quant = UInt32((100 - q) * 127 / 100)
        cfg.rc_min_quantizer = quant
        cfg.rc_max_quantizer = quant
        cfg.rc_target_bitrate = 100_000     // qmin=qmax 下仅作占位，防码控路径除零
        cfg.kf_mode = VPX_KF_AUTO

        let ctx = UnsafeMutablePointer<vpx_codec_ctx_t>.allocate(capacity: 1)
        ctx.initialize(to: vpx_codec_ctx_t())
        defer { ctx.deinitialize(count: 1); ctx.deallocate() }
        guard vpx_codec_enc_init_ver(ctx, iface, &cfg, 0, LibVPXABI.abi) == VPX_CODEC_OK else {
            let detail = vpx_codec_error_detail(ctx).map { String(cString: $0) } ?? "unknown"
            throw DKError.other("WebP：libvpx 初始化失败：\(detail)")
        }
        defer { _ = vpx_codec_destroy(ctx) }

        // 单帧：强制关键帧（WebP 的 VP8 chunk 必须是 intra 帧），BEST_QUALITY 不限时。
        var img = vpx_image_t()
        yuv.withUnsafeMutableBytes { ptr in
            // 按 UInt8 重新绑定：vpx_image_t.planes 是 UnsafeMutablePointer<UInt8>? 元组，
            // 直接塞 RawPointer 类型不匹配（与 LibVPXBridge 同一写法）。
            guard let b = ptr.bindMemory(to: UInt8.self).baseAddress else { return }
            img.fmt = VPX_IMG_FMT_I420
            img.cs = VPX_CS_BT_601
            img.range = VPX_CR_FULL_RANGE               // WebP 约定全范围（libwebp 同款换算）
            img.w = UInt32(w); img.h = UInt32(h)
            img.d_w = UInt32(w); img.d_h = UInt32(h)
            img.r_w = UInt32(w); img.r_h = UInt32(h)
            img.bit_depth = 8; img.bps = 8
            img.x_chroma_shift = 1; img.y_chroma_shift = 1
            img.planes.0 = b                            // Y
            img.planes.1 = b + w * h                    // U
            img.planes.2 = b + w * h * 5 / 4            // V
            img.planes.3 = nil
            img.stride.0 = Int32(w); img.stride.1 = Int32(w / 2); img.stride.2 = Int32(w / 2)
            img.stride.3 = 0
            img.img_data = b; img.img_data_owner = 0; img.self_allocd = 0
        }
        guard vpx_codec_encode(ctx, &img, 0, 1,
                               vpx_enc_frame_flags_t(VPX_EFLAG_FORCE_KF),  // C 宏导入为 Int32，转 long
                               VPX_DL_BEST_QUALITY) == VPX_CODEC_OK else {
            let detail = vpx_codec_error_detail(ctx).map { String(cString: $0) } ?? "unknown"
            throw DKError.other("WebP：编码失败：\(detail)")
        }
        var payload = Data()
        var iter: UnsafeRawPointer?
        while let pkt = vpx_codec_get_cx_data(ctx, &iter) {
            if pkt.pointee.kind == VPX_CODEC_CX_FRAME_PKT, let base = pkt.pointee.data.frame.buf {
                payload.append(UnsafeBufferPointer(start: base.assumingMemoryBound(to: UInt8.self),
                                                   count: Int(pkt.pointee.data.frame.sz)))
            }
        }
        guard !payload.isEmpty else { throw DKError.other("WebP：编码产出空码流") }
        // flush（lag=0 理论无拖尾，保险起见）
        while vpx_codec_encode(ctx, nil, 1, 1, 0, VPX_DL_BEST_QUALITY) == VPX_CODEC_OK {
            var drained = false
            var it2: UnsafeRawPointer?
            while let pkt = vpx_codec_get_cx_data(ctx, &it2) {
                if pkt.pointee.kind == VPX_CODEC_CX_FRAME_PKT, let base = pkt.pointee.data.frame.buf {
                    payload.append(UnsafeBufferPointer(start: base.assumingMemoryBound(to: UInt8.self),
                                                       count: Int(pkt.pointee.data.frame.sz)))
                    drained = true
                }
            }
            if !drained { break }
        }
        return wrapRIFF(payload)
        #else
        throw DKError.other("WebP 需以 DISYNK_WITH_LIBVPX=1 构建（当前构建未装配 libvpx）")
        #endif
    }

    #if DISYNK_LIBVPX
    /// 与 LibVPXBridge 同一 ABI 常量（v1.15.x 实测值）。
    enum LibVPXABI { static let abi: Int32 = 37 }

    /// RGBA(CGImage 渲染) → I420（BT.601 全范围，libwebp 同款系数），透明像素压平白底。
    /// 宽高传偶数（奇数图会被裁掉最右列/最下行 1 像素）。
    private static func rgbaToI420(_ image: CGImage, width w: Int, height h: Int,
                                   into yuv: inout [UInt8]) throws {
        let cs = CGColorSpaceCreateDeviceRGB()
        var rgba = [UInt8](repeating: 0, count: w * h * 4)
        guard let ctx = rgba.withUnsafeMutableBytes({ ptr in
            CGContext(data: ptr.baseAddress, width: w, height: h, bitsPerComponent: 8,
                      bytesPerRow: w * 4, space: cs,
                      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
        }) else { throw DKError.other("WebP：无法创建位图上下文") }
        ctx.setFillColor(CGColor(red: 1, green: 1, blue: 1, alpha: 1))   // 白底压平 alpha
        ctx.fill(CGRect(x: 0, y: 0, width: w, height: h))
        let src = (image.width != w || image.height != h)
            ? (image.cropping(to: CGRect(x: 0, y: 0, width: w, height: h)) ?? image) : image
        ctx.draw(src, in: CGRect(x: 0, y: 0, width: w, height: h))

        yuv = [UInt8](repeating: 0, count: w * h + w * h / 2)
        let yBase = 0, uBase = w * h, vBase = w * h + w * h / 4
        func clamp(_ v: Int) -> UInt8 { UInt8(max(0, min(255, v))) }
        var oy = 0
        while oy < h {
            var ox = 0
            while ox < w {
                // 2×2 块的四像素
                var y0 = 0, y1 = 0, y2 = 0, y3 = 0
                var su = 0, sv = 0
                for (dy, ky) in [(0, 0), (0, 1), (1, 0), (1, 1)] {
                    let p = ((oy + dy) * w + (ox + ky)) * 4
                    let r = Int(rgba[p]), g = Int(rgba[p + 1]), b = Int(rgba[p + 2])
                    // BT.601 全范围：Y=.299R+.587G+.114B；U/V 半采样取块均值
                    let yy = (19595 * r + 38470 * g + 7471 * b + 0x8000) >> 16
                    let uu = (-11059 * r - 21709 * g + 32768 * b + 0x800000) >> 16
                    let vv = (32768 * r - 27439 * g - 5329 * b + 0x800000) >> 16
                    switch (dy, ky) {
                    case (0, 0): y0 = yy; su = uu; sv = vv
                    case (0, 1): y1 = yy; su += uu; sv += vv
                    case (1, 0): y2 = yy; su += uu; sv += vv
                    default:     y3 = yy; su += uu; sv += vv
                    }
                }
                yuv[yBase + oy * w + ox] = clamp(y0)
                yuv[yBase + oy * w + ox + 1] = clamp(y1)
                yuv[yBase + (oy + 1) * w + ox] = clamp(y2)
                yuv[yBase + (oy + 1) * w + ox + 1] = clamp(y3)
                let cxy = oy / 2 * (w / 2) + ox / 2
                yuv[uBase + cxy] = clamp(su / 4 + 128)
                yuv[vBase + cxy] = clamp(sv / 4 + 128)
                ox += 2
            }
            oy += 2
        }
    }

    /// RIFF/WEBP 封装：`RIFF <size> WEBP "VP8 " <len> <payload> [pad]`（payload 奇数长度补 1 字节）。
    static func wrapRIFF(_ payload: Data) -> Data {
        func le32(_ v: UInt32) -> [UInt8] {
            [UInt8(v & 0xff), UInt8((v >> 8) & 0xff), UInt8((v >> 16) & 0xff), UInt8((v >> 24) & 0xff)]
        }
        var out = Data()
        let chunkLen = UInt32(payload.count)
        let riffSize = 4 /*WEBP*/ + 8 /*VP8 头*/ + chunkLen + (chunkLen & 1)
        out.append(contentsOf: Array("RIFF".utf8))
        out.append(contentsOf: le32(riffSize))
        out.append(contentsOf: Array("WEBP".utf8))
        out.append(contentsOf: Array("VP8 ".utf8))
        out.append(contentsOf: le32(chunkLen))
        out.append(payload)
        if chunkLen & 1 == 1 { out.append(0) }
        return out
    }
    #endif
}
