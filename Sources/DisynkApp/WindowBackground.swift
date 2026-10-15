import CoreGraphics
import CoreImage
import CoreVideo
import DKCore
import ImageIO

/// 窗口录制「自定义壁纸背景」合成器（CPU/CoreGraphics，兼容 macOS 14）：
/// 把窗口帧（BGRA，配合 isBackgroundTransparent 时其外框为透明）按等比居中画到壁纸之上，
/// 输出与编码尺寸一致的 BGRA 帧。仅用于单窗口录制路径；纯采集性能敏感的多屏合成仍走 MetalCompositor。
final class WindowBGCompositor: @unchecked Sendable {
    private let wallpaper: CGImage
    private let width: Int
    private let height: Int
    private var pool: CVPixelBufferPool?
    private static let ci = CIContext()

    /// wallpaperPath 无法解码为图片时返回 nil（调用方回退不合成）。
    init?(wallpaperPath: String, size: PixelSize) {
        let src = CGImageSourceCreateWithURL(URL(fileURLWithPath: wallpaperPath) as CFURL, nil)
        guard let img = src.flatMap({ CGImageSourceCreateImageAtIndex($0, 0, nil) }) else { return nil }
        self.wallpaper = img
        self.width = max(2, size.width)
        self.height = max(2, size.height)
    }

    /// 合成一帧：壁纸铺满画布，窗口等比缩放居中叠加（alpha 混合）。
    func composite(_ windowPB: CVPixelBuffer) -> CVPixelBuffer? {
        guard let out = dequeue() else { return nil }
        CVPixelBufferLockBaseAddress(out, [])
        defer { CVPixelBufferUnlockBaseAddress(out, []) }
        guard let base = CVPixelBufferGetBaseAddress(out),
              let cs = CGColorSpace(name: CGColorSpace.sRGB),
              let ctx = CGContext(data: base, width: width, height: height, bitsPerComponent: 8,
                                  bytesPerRow: CVPixelBufferGetBytesPerRow(out), space: cs,
                                  bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue
                                    | CGBitmapInfo.byteOrder32Little.rawValue)
        else { return out }

        ctx.draw(wallpaper, in: CGRect(x: 0, y: 0, width: width, height: height))

        let ci = CIImage(cvPixelBuffer: windowPB)
        if let win = Self.ci.createCGImage(ci, from: ci.extent) {
            let scale = min(Double(width) / Double(win.width), Double(height) / Double(win.height))
            let dw = max(1, Int(Double(win.width) * scale))
            let dh = max(1, Int(Double(win.height) * scale))
            let r = CGRect(x: (width - dw) / 2, y: (height - dh) / 2, width: dw, height: dh)
            ctx.setBlendMode(.normal)
            ctx.draw(win, in: r)
        }
        return out
    }

    private func dequeue() -> CVPixelBuffer? {
        let attrs: [String: Any] = [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
            kCVPixelBufferWidthKey as String: width,
            kCVPixelBufferHeightKey as String: height,
            kCVPixelBufferIOSurfacePropertiesKey as String: [:],
        ]
        if pool == nil {
            var p: CVPixelBufferPool?
            CVPixelBufferPoolCreate(kCFAllocatorDefault, nil, attrs as CFDictionary, &p)
            pool = p
        }
        var pb: CVPixelBuffer?
        if let pool { CVPixelBufferPoolCreatePixelBuffer(kCFAllocatorDefault, pool, &pb) }
        else { CVPixelBufferCreate(kCFAllocatorDefault, width, height, kCVPixelFormatType_32BGRA, attrs as CFDictionary, &pb) }
        return pb
    }
}
