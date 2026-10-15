import DKCore
import Foundation
#if DISYNK_LIBVPX
import LibVPX
#endif

/// libvpx（VP8/VP9 软编）桥接——WebM 导出唯一的外部依赖实现。
///
/// 默认构建：未定义 `DISYNK_LIBVPX` → 本文件为空扩展，`WebMExporter.codecFactory` 保持 nil，
/// 导出 WebM 时按预期显式报错（提示需以 `DISYNK_WITH_LIBVPX=1` 重新构建）。
///
/// 装配构建：Scripts/build.sh 见 `Scripts/vendor/libvpx/{include/module.modulemap,lib/libvpx.11.dylib}`
/// 就位且 `DISYNK_WITH_LIBVPX=1` 时，追加 `-D DISYNK_LIBVPX` + `-Xcc -fmodule-map-file=...`，
/// 本文件被编译；`installLibVPXCodec()` 直接把真实 VP8/VP9 编码器注入 `WebMExporter.codecFactory`。
///
/// ABI 依据：libvpx v1.15.x `VPX_ENCODER_ABI_VERSION = 18 + (4+5) + 10 = 37`（本机 dylib 实测接受），
/// Swift 无法导入 C 宏 → 直接给 `vpx_codec_enc_init_ver` 传字面量 37。
public extension WebMExporter {
    #if DISYNK_LIBVPX
    /// 注入 libvpx VP8/VP9 编码工厂；调用后 `WebMExporter.export` 走真实软编路径。
    static func installLibVPXCodec() {
        WebMExporter.codecFactory = LibVPXBridge.makeCodec
        DKLog.export.info("libvpx 已装配：WebM 导出启用 VP8/VP9 软编（\(vpx_codec_version_str().map { String(cString: $0) } ?? "unknown", privacy: .public)）")
    }
    #else
    /// 未启用 libvpx 时的空实现：调用不改变任何状态，导出会显式报「未装配」。
    static func installLibVPXCodec() {
        DKLog.export.info("libvpx 未装配：WebM 导出不可用（重构建时置 DISYNK_WITH_LIBVPX=1）")
    }
    #endif
}

#if DISYNK_LIBVPX
/// vpx 编码器封装：一次会话对应一次 `WebMExporter.export` 调用（导出后台队列顺序使用，无并发）。
enum LibVPXBridge {
    /// libvpx v1.15.x 上 VPX_ENCODER_ABI_VERSION 展开值；`enc_init_ver` 校验参数。
    static let encoderABI: Int32 = 37

    /// vpx_codec_error_detail / vpx_codec_error 的 C 字符串安全转 Swift String。
    private static func cstring(_ p: UnsafePointer<CChar>?) -> String {
        p.map { String(cString: $0) } ?? "unknown"
    }

    /// 初始化失败时的占位 codec：`encodeFrame` 显式抛错，避免静默产出空 WebM。
    private static func failedCodec(_ name: String, reason: String) -> WebMExporter.WebMCodec {
        DKLog.export.error("libvpx \(name, privacy: .public) 装配失败：\(reason, privacy: .public)")
        return WebMExporter.WebMCodec(
            name: name,
            encodeFrame: { _, _, _, _, _, _, _ in throw DKError.other("libvpx 初始化失败：\(reason)") },
            finish: { [] })
    }

    /// 依 vendor 头实现：返回封装 vpx 编码会话的 WebMCodec（VP8 或 VP9）。
    static func makeCodec(_ size: PixelSize, _ fps: Double, _ crf: Int,
                          _ choice: ExportOptions.VPCodec) -> WebMExporter.WebMCodec {
        let name = choice == .vp9 ? "V_VP9" : "V_VP8"
        let iface = choice == .vp9 ? vpx_codec_vp9_cx() : vpx_codec_vp8_cx()
        var cfg = vpx_codec_enc_cfg_t()
        guard vpx_codec_enc_config_default(iface, &cfg, 0) == VPX_CODEC_OK else {
            return failedCodec(name, reason: "enc_config_default 失败")
        }
        cfg.g_w = UInt32(max(2, size.width & ~1))
        cfg.g_h = UInt32(max(2, size.height & ~1))
        cfg.g_timebase.num = 1
        cfg.g_timebase.den = Int32(max(1, fps.rounded()))
        cfg.g_lag_in_frames = 0                     // 逐帧即时出一包，简化 pts 与 flush
        // 不用 VPX_Q（cq_level 需变参 vpx_codec_control 设定，Swift 不可导入），
        // 改走 VPX_VBR + 从 crf 反推目标码率（crf 越高 → 码率越低）。
        cfg.rc_end_usage = VPX_VBR
        let crfClamped = Double(min(63, max(0, crf)))
        let bitsPerPixel = (64.0 - crfClamped) / 200.0     // 0–0.32 bpp，crf=32 时≈ 0.16 bpp
        let pixelsPerSec = Double(cfg.g_w) * Double(cfg.g_h) * max(1.0, fps)
        let kbps = max(200, Int(pixelsPerSec * bitsPerPixel / 1000.0))
        cfg.rc_target_bitrate = UInt32(kbps)
        cfg.rc_min_quantizer = UInt32(max(0, crf - 16))
        cfg.rc_max_quantizer = UInt32(min(63, max(0, crf)))
        cfg.kf_mode = VPX_KF_AUTO                   // 关键帧策略由编码器决定
        cfg.kf_max_dist = UInt32(max(1, fps.rounded()) * 10)

        let box = VPXSessionBox()
        let initRes = vpx_codec_enc_init_ver(box.ctx, iface, &cfg, 0, encoderABI)
        if initRes != VPX_CODEC_OK {
            let detail = cstring(vpx_codec_error_detail(box.ctx))
            return failedCodec(name, reason: "enc_init_ver(abi=\(encoderABI)) 失败：\(detail)")
        }
        // 变参 `vpx_codec_control` 宏在 Swift 不可导入；CPUUSED/ tune 缺省即库默认，导出路径可接受。

        return WebMExporter.WebMCodec(
            name: name,
            encodeFrame: { y, ys, u, us, v, vs, _ in
                // 直接把调用方给定的 I420 平面基址/stride 填入 vpx_image_t（无内存拷贝）。
                var img = vpx_image_t()
                img.fmt = VPX_IMG_FMT_I420
                img.cs = VPX_CS_BT_709
                img.range = VPX_CR_STUDIO_RANGE
                img.w = UInt32(size.width); img.h = UInt32(size.height)
                img.d_w = UInt32(size.width); img.d_h = UInt32(size.height)
                img.r_w = UInt32(size.width); img.r_h = UInt32(size.height)
                img.bit_depth = 8
                img.x_chroma_shift = 1; img.y_chroma_shift = 1
                img.bps = 8
                img.planes.0 = y;  img.stride.0 = Int32(ys)
                img.planes.1 = u;  img.stride.1 = Int32(us)
                img.planes.2 = v;  img.stride.2 = Int32(vs)
                img.planes.3 = nil; img.stride.3 = 0
                img.img_data = nil; img.img_data_owner = 0; img.self_allocd = 0
                let r = vpx_codec_encode(box.ctx, &img, box.pts, 1, 0, VPX_DL_GOOD_QUALITY)
                if r != VPX_CODEC_OK {
                    let detail = cstring(vpx_codec_error_detail(box.ctx))
                    throw DKError.other("vpx_codec_encode 失败(\(r.rawValue))：\(detail)")
                }
                box.pts += 1
                return box.drainFrame().data
            },
            finish: {
                var out: [Data] = []
                // lag=0 时通常无拖尾；仍 drain 到空以保正确。
                while true {
                    let r = vpx_codec_encode(box.ctx, nil, box.pts, 1, 0, VPX_DL_GOOD_QUALITY)
                    if r != VPX_CODEC_OK { break }
                    box.pts += 1
                    let drained = box.drainFrame()
                    if drained.frames == 0 && drained.data.isEmpty { break }
                    if !drained.data.isEmpty { out.append(drained.data) }
                }
                _ = vpx_codec_destroy(box.ctx)
                return out
            })
    }

    /// vpx_codec_ctx 堆持有者；导出后台队列顺序调用，无并发。
    final class VPXSessionBox: @unchecked Sendable {
        let ctx: UnsafeMutablePointer<vpx_codec_ctx_t>
        /// 逐帧递增的 PTS（原为局部 var，被 @Sendable 闭包捕获会报并发变更；收进同一串行域持有的盒子）
        var pts: Int64 = 0
        init() {
            ctx = UnsafeMutablePointer<vpx_codec_ctx_t>.allocate(capacity: 1)
            ctx.initialize(to: vpx_codec_ctx_t())
        }
        /// 抽取本帧所有 VPX_CODEC_CX_FRAME_PKT 分区拼成一个 Block 载荷。
        /// libvpx 默认单分区/帧；多分区时按 WebM 约定同块拼接（首字节分区标志由码流自带）。
        func drainFrame() -> (data: Data, frames: Int) {
            var data = Data()
            var n = 0
            var iter: UnsafeRawPointer?
            while let pkt = vpx_codec_get_cx_data(ctx, &iter) {
                if pkt.pointee.kind == VPX_CODEC_CX_FRAME_PKT {
                    let f = pkt.pointee.data.frame
                    if let base = f.buf {
                        data.append(UnsafeBufferPointer(start: base.assumingMemoryBound(to: UInt8.self),
                                                        count: Int(f.sz)))
                    }
                    n += 1
                }
            }
            return (data, n)
        }
        deinit { ctx.deinitialize(count: 1); ctx.deallocate() }
    }
}
#endif
