import AppKit
import CoreGraphics
import DKCore
import DKSettings
import Foundation
import ImageIO
import ScreenCaptureKit
@preconcurrency import Vision

/// 截图（方案 M4：全屏/窗口/区域）+ 即时 OCR（Vision，离线中英）
public enum Screenshotter {
    /// 计算某屏的像素倍率（Retina=2、普通=1），避免硬编码 2x。
    /// = CGDisplayMode 像素宽 ÷ CGDisplayBounds 点宽（四舍五入到 .5），非正/异常回退 1。
    /// 纯映射，可离线单测（真机像素/点值依赖显示配置）。
    public static func pixelScale(pixelWidth: Int, pointWidth: Int) -> Double {
        guard pixelWidth > 0, pointWidth > 0 else { return 1 }
        let raw = Double(pixelWidth) / Double(pointWidth)
        guard raw.isFinite, raw > 0 else { return 1 }
        return (raw * 2).rounded() / 2   // 对齐到 0.5 倍（常见 1/2/3）
    }

    /// 整屏截图（按实际像素倍率输出原生分辨率）
    public static func captureDisplay(displayID: UInt32) async throws -> CGImage {
        let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
        guard let display = content.displays.first(where: { $0.displayID == displayID }) else {
            throw DKError.displayNotFound(id: displayID)
        }
        let config = SCStreamConfiguration()
        let scale = Self.scale(for: displayID)
        config.width = display.width * Int(scale.rounded())
        config.height = display.height * Int(scale.rounded())
        let filter = SCContentFilter(display: display, excludingWindows: [])
        return try await SCScreenshotManager.captureImage(contentFilter: filter, configuration: config)
    }

    /// 该屏当前像素倍率（像素宽/点宽），异常回退 1x。
    private static func scale(for displayID: UInt32) -> Double {
        guard let mode = CGDisplayCopyDisplayMode(displayID) else { return 1 }
        let pointW = Int(CGDisplayBounds(displayID).width)
        return pixelScale(pixelWidth: mode.pixelWidth, pointWidth: pointW)
    }

    /// 指定窗口截图
    public static func captureWindow(windowID: CGWindowID) async throws -> CGImage {
        let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
        guard let window = content.windows.first(where: { $0.windowID == windowID }) else {
            throw DKError.other("窗口不存在或已关闭")
        }
        let config = SCStreamConfiguration()
        let filter = SCContentFilter(desktopIndependentWindow: window)
        return try await SCScreenshotManager.captureImage(contentFilter: filter, configuration: config)
    }

    /// 区域截图（全局桌面坐标，左上原点；通常来自框选 UI）——按实际像素倍率输出
    public static func captureRegion(_ rect: CGRect, onDisplay displayID: UInt32) async throws -> CGImage {
        let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
        guard let display = content.displays.first(where: { $0.displayID == displayID }) else {
            throw DKError.displayNotFound(id: displayID)
        }
        let config = SCStreamConfiguration()
        // sourceRect 单位为点；输出按实际倍率放大到像素
        let scale = Self.scale(for: displayID)
        config.sourceRect = rect
        config.width = Int(rect.width * scale)
        config.height = Int(rect.height * scale)
        let filter = SCContentFilter(display: display, excludingWindows: [])
        return try await SCScreenshotManager.captureImage(contentFilter: filter, configuration: config)
    }

    // MARK: - 保存到磁盘（方案：截图产物落输出目录）

    /// 将 CGImage 以 PNG 写入目录，返回实际文件 URL。文件名 = 前缀 + 时间戳（避免覆盖）。
    public static func savePNG(_ image: CGImage, to directory: URL, namePrefix: String) throws -> URL {
        try save(image, format: .png, to: directory, namePrefix: namePrefix)
    }

    /// 按指定格式保存截图，返回实际文件 URL。
    /// png/jpeg/heic 走系统 ImageIO（jpeg 不支持 alpha → 压平白底）；
    /// webp 走 libvpx VP8 单帧编码（需 DISYNK_WITH_LIBVPX=1 装配构建，否则抛错由调用方回退 PNG）。
    @discardableResult
    public static func save(_ image: CGImage, format: ShotFormat, to directory: URL, namePrefix: String) throws -> URL {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let fmt = DateFormatter(); fmt.dateFormat = "yyyyMMdd-HHmmss"
        let url = directory.appendingPathComponent("\(namePrefix)-\(fmt.string(from: Date())).\(format.fileExtension)")
        if let type = format.imageIOType {
            // JPEG 无 alpha 通道：透明像素先压平到白底，否则 ImageIO 输出发黑/带伪影
            let target = (format == .jpeg) ? flatten(image, on: .white) : image
            guard let dest = CGImageDestinationCreateWithURL(url as CFURL, type as CFString, 1, nil) else {
                throw DKError.other("无法创建 \(format.displayName) 导出目标")
            }
            var props: [CFString: Any] = [:]
            if format.isLossy { props[kCGImageDestinationLossyCompressionQuality] = 0.92 }
            CGImageDestinationAddImage(dest, target, props as CFDictionary)
            guard CGImageDestinationFinalize(dest) else {
                throw DKError.other("\(format.displayName) 写入失败")
            }
            return url
        }
        // WebP：libvpx 产字节流直写文件
        let data = try WebPEncoder.encode(image)
        try data.write(to: url, options: .atomic)
        return url
    }

    /// 透明图像压平到指定底色（JPEG/HEIC 有损路径共用）。
    static func flatten(_ image: CGImage, on color: CGColor) -> CGImage {
        guard let ctx = CGContext(data: nil, width: image.width, height: image.height,
                                  bitsPerComponent: 8, bytesPerRow: 0,
                                  space: CGColorSpaceCreateDeviceRGB(),
                                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return image }
        ctx.setFillColor(color)
        ctx.fill(CGRect(x: 0, y: 0, width: image.width, height: image.height))
        ctx.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
        return ctx.makeImage() ?? image
    }

    // MARK: - OCR（截图即文字，方案第三节）

    public struct OCRResult: Sendable {
        public var lines: [String]
        public var confidenceAvg: Double
        public var text: String { lines.joined(separator: "\n") }
        public init(lines: [String], confidenceAvg: Double = 0) {
            self.lines = lines
            self.confidenceAvg = confidenceAvg
        }
    }

    /// 多语言离线识别（Vision Live Text 风格）；中英混排优先
    public static func recognizeText(in image: CGImage) async throws -> OCRResult {
        let request = VNRecognizeTextRequest()
        request.recognitionLevel = .accurate
        request.usesLanguageCorrection = true
        request.recognitionLanguages = ["zh-Hans", "zh-Hant", "en-US"]

        let handler = VNImageRequestHandler(cgImage: image, options: [:])
        // Vision 请求对象非 Sendable：装盒后移交全局队列（一次性使用，不复用）
        let job = SendableBox((handler, request))
        return try await withCheckedThrowingContinuation { (cont: CheckedContinuation<OCRResult, Error>) in
            DispatchQueue.global(qos: .userInitiated).async {
                do {
                    try job.value.0.perform([job.value.1])
                    cont.resume(returning: Self.buildResult(job.value.1.results ?? []))
                } catch {
                    cont.resume(throwing: DKError.other("OCR 失败：\(error.localizedDescription)"))
                }
            }
        }
    }

    private static func buildResult(_ observations: [VNRecognizedTextObservation]) -> OCRResult {
        var lines: [String] = []
        var confSum = 0.0
        for obs in observations {
            guard let cand = obs.topCandidates(1).first else { continue }
            lines.append(cand.string)
            confSum += Double(cand.confidence)
        }
        let avg = observations.isEmpty ? 0.0 : confSum / Double(observations.count)
        return OCRResult(lines: lines, confidenceAvg: avg)
    }

    /// 剪贴板图像 OCR（方案：剪贴板截图识别）
    public static func recognizeClipboard() async throws -> OCRResult {
        guard let img = readPasteboardImage() else {
            throw DKError.other("剪贴板中没有图像")
        }
        return try await recognizeText(in: img)
    }

    static func readPasteboardImage() -> CGImage? {
        let pb = NSPasteboard.general
        guard let items = pb.readObjects(forClasses: [NSImage.self], options: nil) as? [NSImage],
              let ns = items.first,
              let tiff = ns.tiffRepresentation,
              let rep = NSBitmapImageRep(data: tiff) else { return nil }
        return rep.cgImage
    }

    /// 导出识别文本：TXT 逐行；Markdown 加标题段并以空行分段（方案第三节「导出 TXT/MD」）。
    public static func writeText(_ result: OCRResult, to url: URL, markdown: Bool) throws {
        let body: String
        if markdown {
            body = "# 识别文本\n\n" + result.lines.joined(separator: "\n\n") + "\n"
        } else {
            body = result.text
        }
        try body.data(using: .utf8)?.write(to: url)
    }
}
