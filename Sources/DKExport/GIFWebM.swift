import AVFoundation
import Accelerate
import CoreGraphics
import CoreImage
import CoreVideo
import DKCore
import DKMux
import Foundation
import ImageIO
import UniformTypeIdentifiers

/// 离线导出（方案 M6/DKExport）：GIF 走 CGImageDestination；
/// WebM 需 VP8/VP9 软编（VideoToolbox 无此编码器）→ libvpx 桥接，见 WebMExporter 说明。
public enum ExportOptions: Sendable {
    case gif(fps: Int = 12, maxLongEdge: Int = 800)
    case webm(codec: VPCodec = .vp8, crf: Int = 32)

    public enum VPCodec: String, Sendable { case vp8, vp9 }
}

public enum GIFExporter {
    /// 录制产物 → GIF（限帧率/尺寸/区域；抽帧解码在后台队列，不占实时管线）
    /// 返回产物字节数（UI 预估体积并警告，方案第四节：默认 ≤15fps、长边 ≤800px）
    public static func export(input: URL, to output: URL,
                              fps: Int = 12, maxLongEdge: Int = 800,
                              crop: CGRect? = nil,
                              progress: (@Sendable (Double) -> Void)? = nil) async throws -> Int64 {
        let asset = AVURLAsset(url: input)
        guard let track = try await asset.loadTracks(withMediaType: .video).first else {
            throw DKError.other("视频文件无视频轨")
        }
        let size = try await track.load(.naturalSize)
        let natural = try await asset.load(.duration)
        guard size.width > 0, size.height > 0 else { throw DKError.other("无法解析源尺寸") }

        // 目标尺寸（长边钳制 + 偶数）
        let scale = min(1.0, Double(maxLongEdge) / Double(max(size.width, size.height)))
        let outW = Int(size.width * scale) & ~1
        let outH = Int(size.height * scale) & ~1

        let reader = try AVAssetReader(asset: asset)
        let outputSettings: [String: Any] = [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
            kCVPixelBufferWidthKey as String: outW,
            kCVPixelBufferHeightKey as String: outH,
        ]
        let trackOutput = AVAssetReaderTrackOutput(track: track, outputSettings: outputSettings)
        reader.add(trackOutput)
        reader.startReading()

        let fpsCap = min(fps, 15)                       // 方案：GIF 默认限 ≤15fps
        let frameInterval = 1.0 / Double(max(1, fpsCap))
        var nextEmit = 0.0
        var frames: [CGImage] = []
        let ci = CIContext()

        while reader.status == .reading {
            guard let sb = trackOutput.copyNextSampleBuffer() else { break }
            let pts = CMTimeGetSeconds(CMSampleBufferGetPresentationTimeStamp(sb))
            guard pts >= nextEmit else { continue }
            nextEmit = pts + frameInterval
            guard let pb = CMSampleBufferGetImageBuffer(sb) else { continue }
            let img0 = CIImage(cvPixelBuffer: pb)
            guard var img = ci.createCGImage(img0, from: img0.extent) else { continue }
            if let crop {
                // crop 为点坐标（显示空间）→ 输出像素线性映射
                let sx = Double(outW) / Double(size.width), sy = Double(outH) / Double(size.height)
                let scaled = CGRect(x: crop.minX * sx, y: crop.minY * sy,
                                    width: crop.width * sx, height: crop.height * sy)
                if let c = img.cropping(to: scaled) { img = c }
            }
            frames.append(img)
            let total = max(natural.seconds, 0.001)
            progress?(min(1, pts / total))
        }
        guard reader.status == .completed || reader.status == .reading else {
            throw DKError.other("解码失败：\(reader.error?.localizedDescription ?? "未知")")
        }
        guard !frames.isEmpty else { throw DKError.other("未抽到任何帧") }

        guard let dest = CGImageDestinationCreateWithURL(
            output as CFURL, UTType.gif.identifier as CFString, frames.count, nil) else {
            throw DKError.other("无法创建 GIF 输出")
        }
        CGImageDestinationSetProperties(dest, [
            kCGImagePropertyGIFDictionary: [kCGImagePropertyGIFLoopCount: 0],
        ] as CFDictionary)
        let frameProps = [
            kCGImagePropertyGIFDictionary: [kCGImagePropertyGIFDelayTime: frameInterval],
        ] as CFDictionary
        for img in frames {
            CGImageDestinationAddImage(dest, img, frameProps)
        }
        guard CGImageDestinationFinalize(dest) else { throw DKError.other("GIF 写入失败") }
        let attrs = try FileManager.default.attributesOfItem(atPath: output.path)
        let bytes = (attrs[.size] as? NSNumber)?.int64Value ?? 0
        DKLog.export.info("GIF 导出 \(frames.count) 帧 → \(bytes / 1_048_576, privacy: .public)MB")
        return bytes
    }
}

/// WebM 导出（方案：捆绑 libvpx VP8/VP9 软编 + EBML 封装）。
/// 本开发环境无 libvpx（不可下载）：容器/封装/抽帧/I420 转换均为真实代码，
/// 唯一外部缺口是 VP8/VP9 比特流生成——通过 `codecFactory` 注入点装配。
/// 管线：AVAssetReader(I420) 抽帧 → codec.encodeFrame → WebM EBML（BlockGroup/Block）。
/// 未注入 libvpx 时显式报错而非静默降级。
public enum WebMExporter {
    /// libvpx 桥接工厂：给定尺寸/帧率/质量/编码选择（VP8 vs VP9）返回编码器（构建标志 -lvpx 装配后注入）
    nonisolated(unsafe) public static var codecFactory:
        ((PixelSize, Double, Int, ExportOptions.VPCodec) -> WebMCodec)?

    /// 单帧软编码接口：I420 平面 → 一帧 VP8/VP9 分区数据
    public struct WebMCodec: Sendable {
        public var name: String        // "V_VP8" / "V_VP9"
        /// 输入 I420（y/u/v 平面基址与 stride），输出单帧载荷
        public var encodeFrame: @Sendable (
            _ y: UnsafeMutablePointer<UInt8>, _ yStride: Int,
            _ u: UnsafeMutablePointer<UInt8>, _ uStride: Int,
            _ v: UnsafeMutablePointer<UInt8>, _ vStride: Int,
            _ ptsSeconds: Double) throws -> Data
        public var finish: @Sendable () throws -> [Data]   // 剩余 flush 帧

        public init(name: String,
                    encodeFrame: @escaping @Sendable (UnsafeMutablePointer<UInt8>, Int,
                        UnsafeMutablePointer<UInt8>, Int, UnsafeMutablePointer<UInt8>, Int,
                        Double) throws -> Data,
                    finish: @escaping @Sendable () throws -> [Data]) {
            self.name = name; self.encodeFrame = encodeFrame; self.finish = finish
        }
    }

    public static func export(input: URL, to output: URL, codec: ExportOptions.VPCodec,
                              crf: Int = 32) async throws {
        guard let factory = codecFactory else {
            throw DKError.unsupportedForPhase(
                "WebM 需捆绑 libvpx（VP8/VP9 软编）：Scripts/vendor/libvpx 就位并以 DISYNK_WITH_LIBVPX=1 重新构建")
        }
        let asset = AVURLAsset(url: input)
        guard let track = try await asset.loadTracks(withMediaType: .video).first else {
            throw DKError.other("视频文件无视频轨")
        }
        let naturalSize = try await track.load(.naturalSize)
        let w = max(2, Int(naturalSize.width) & ~1)
        let h = max(2, Int(naturalSize.height) & ~1)
        let nominal = try await track.load(.nominalFrameRate)
        let fps = nominal > 0 ? Double(nominal) : 30

        let reader = try AVAssetReader(asset: asset)
        let settings: [String: Any] = [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_420YpCbCr8Planar,
        ]
        let trackOutput = AVAssetReaderTrackOutput(track: track, outputSettings: settings)
        reader.add(trackOutput)
        guard reader.startReading() else {
            throw DKError.other("WebM 解码启动失败：\(reader.error?.localizedDescription ?? "未知")")
        }

        let enc = factory(PixelSize(width: w, height: h), fps, crf, codec)
        let writer = WebMContainer(url: output, codecName: enc.name,
                                   width: w, height: h, fps: fps)
        let interval = 1.0 / max(1, fps)
        var nextPTS = 0.0
        var encodedCount = 0
        while reader.status == .reading {
            guard let sb = trackOutput.copyNextSampleBuffer() else { break }
            let pts = CMTimeGetSeconds(CMSampleBufferGetPresentationTimeStamp(sb))
            guard let pb = CMSampleBufferGetImageBuffer(sb) else { continue }
            CVPixelBufferLockBaseAddress(pb, .readOnly)
            let planeCount = CVPixelBufferGetPlaneCount(pb)
            defer { CVPixelBufferUnlockBaseAddress(pb, .readOnly) }
            guard planeCount >= 3,
                  let yp = CVPixelBufferGetBaseAddressOfPlane(pb, 0),
                  let up = CVPixelBufferGetBaseAddressOfPlane(pb, 1),
                  let vp = CVPixelBufferGetBaseAddressOfPlane(pb, 2) else { continue }
            let ys = CVPixelBufferGetBytesPerRowOfPlane(pb, 0)
            let us = CVPixelBufferGetBytesPerRowOfPlane(pb, 1)
            let vs = CVPixelBufferGetBytesPerRowOfPlane(pb, 2)
            let payload = try enc.encodeFrame(
                yp.assumingMemoryBound(to: UInt8.self), ys,
                up.assumingMemoryBound(to: UInt8.self), us,
                vp.assumingMemoryBound(to: UInt8.self), vs, pts)
            writer.appendFrame(payload, ptsSeconds: pts)
            encodedCount += 1
            nextPTS = pts + interval
        }
        for payload in try enc.finish() {
            writer.appendFrame(payload, ptsSeconds: nextPTS)
            nextPTS += interval
            encodedCount += 1
        }
        guard reader.status == .completed || reader.status == .reading else {
            throw DKError.other("WebM 解码失败：\(reader.error?.localizedDescription ?? "未知")")
        }
        guard encodedCount > 0 else { throw DKError.other("WebM 未编码任何帧") }
        try writer.finish()

        let attrs = try FileManager.default.attributesOfItem(atPath: output.path)
        let bytes = (attrs[.size] as? NSNumber)?.int64Value ?? 0
        DKLog.export.info("WebM 导出 \(encodedCount, privacy: .public) 帧 → \(bytes / 1_048_576, privacy: .public)MB（codec \(enc.name, privacy: .public)）")
    }
}

/// WebM 容器写手（视频单轨）：WebM 属 Matroska 家族，复用 DKMux/EBML 原语。
/// 与 MKV 差异：DocType="webm"、codecID=V_VP8/V_VP9、视频块必须置于 BlockGroup（禁 SimpleBlock）。
/// Segment 未知长度，Duration 占位写入并在 finish() 回写，Cues 收尾追加。
final class WebMContainer {
    private let url: URL
    private let codecName: String
    private let width: Int, height: Int, fps: Double
    private var file: FileHandle?
    private var offset: UInt64 = 0
    private var headerWritten = false
    private var baseSeconds: Double = 0
    private let frameMs: Double
    private var clusterBlocks = Data()
    private var clusterStartMs: UInt64 = 0
    private var cueEntries: [(ms: UInt64, pos: UInt64)] = []
    private var lastBlockEndMs: Double = 0
    private var durationValueFileOffset: UInt64?
    private static let clusterIntervalMs: Double = 10_000

    init(url: URL, codecName: String, width: Int, height: Int, fps: Double) {
        self.url = url
        self.codecName = codecName
        self.width = width
        self.height = height
        self.fps = fps
        self.frameMs = 1000.0 / max(1, fps)
    }

    private func write(_ data: Data) throws {
        if file == nil {
            FileManager.default.createFile(atPath: url.path, contents: nil)
            guard let h = FileHandle(forWritingAtPath: url.path) else {
                throw DKError.other("无法打开 WebM 输出: \(url.path)")
            }
            file = h
        }
        file?.write(data)
        offset += UInt64(data.count)
    }

    func appendFrame(_ payload: Data, ptsSeconds: Double) {
        if !headerWritten {
            baseSeconds = ptsSeconds
            try? writeHeader()
            headerWritten = true
        }
        let tsMs = UInt64(max(0, (ptsSeconds - baseSeconds) * 1000).rounded())
        if !clusterBlocks.isEmpty, Double(tsMs - clusterStartMs) >= Self.clusterIntervalMs {
            try? flushCluster()
        }
        if clusterBlocks.isEmpty { clusterStartMs = tsMs }
        lastBlockEndMs = max(lastBlockEndMs, Double(tsMs) + frameMs)
        clusterBlocks.append(Self.blockGroup(track: 1, relativeMs: Int(tsMs - clusterStartMs),
                                             payload: payload))
    }

    /// BlockGroup{ Block }：Block = 轨VINT + 相对时间码(int16 BE) + 标志(0x00) + 载荷
    static func blockGroup(track: Int, relativeMs: Int, payload: Data) -> Data {
        var block = Data()
        block.append(UInt8(0x80 | track))
        let rel = Int16(max(-32768, min(32767, relativeMs)))
        block.append(UInt8((UInt16(bitPattern: rel)) >> 8))
        block.append(UInt8(UInt16(bitPattern: rel) & 0xFF))
        block.append(0x00)
        block.append(payload)
        let blockElem = EBML.element(id: MkID.block, block)
        return EBML.master(id: MkID.blockGroup, blockElem)
    }

    private func flushCluster() throws {
        guard !clusterBlocks.isEmpty else { return }
        var payload = Data()
        payload.append(EBML.uint(id: MkID.timecode, clusterStartMs, byteWidth: 3))
        payload.append(clusterBlocks)
        cueEntries.append((ms: clusterStartMs, pos: offset))
        try write(EBML.element(id: MkID.cluster, payload))
        clusterBlocks = Data()
    }

    private func writeHeader() throws {
        var header = Data()
        header.append(EBML.uint(id: MkID.ebmlVersion, 1))
        header.append(EBML.uint(id: MkID.ebmlReadVersion, 1))
        header.append(EBML.uint(id: MkID.ebmlMaxIDLength, 4))
        header.append(EBML.uint(id: MkID.ebmlMaxSizeLength, 8))
        header.append(EBML.string(id: MkID.docType, "webm"))
        header.append(EBML.uint(id: MkID.docTypeVersion, 2))
        header.append(EBML.uint(id: MkID.docTypeReadVersion, 2))
        try write(EBML.master(id: MkID.ebml, header))

        try write(Data(MkID.segment) + EBML.unknownSize)

        var info = Data()
        var uid = Data(count: 16)
        for i in 0..<16 { uid[i] = UInt8.random(in: 0...255) }
        info.append(EBML.binary(id: MkID.segmentUID, uid))
        info.append(EBML.uint(id: MkID.timecodeScale, 1_000_000)) // 1ms
        info.append(EBML.string(id: MkID.muxingApp, "Disynk"))
        info.append(EBML.string(id: MkID.writingApp, "Disynk"))
        let durationElem = EBML.float64(id: MkID.duration, 0)
        let durationValueOffsetInPayload = info.count + durationElem.count - 8
        info.append(durationElem)
        let infoPayloadSize = EBML.encodedSize(info.count)
        durationValueFileOffset = offset + UInt64(4 + infoPayloadSize.count)
            + UInt64(durationValueOffsetInPayload)
        try write(EBML.element(id: MkID.info, info))

        var track = Data()
        track.append(EBML.uint(id: MkID.trackNumber, 1))
        track.append(EBML.uint(id: MkID.trackUID, 0x1853_8067))
        track.append(EBML.uint(id: MkID.trackType, 1))
        track.append(EBML.uint(id: MkID.flagLacing, 0))
        track.append(EBML.string(id: MkID.language, "und"))
        track.append(EBML.string(id: MkID.codecID, codecName))
        track.append(EBML.uint(id: MkID.defaultDuration, UInt64((1_000_000_000 / fps).rounded())))
        var videoElem = Data()
        videoElem.append(EBML.uint(id: MkID.pixelWidth, UInt64(width)))
        videoElem.append(EBML.uint(id: MkID.pixelHeight, UInt64(height)))
        videoElem.append(EBML.uint(id: MkID.displayWidth, UInt64(width)))
        videoElem.append(EBML.uint(id: MkID.displayHeight, UInt64(height)))
        track.append(EBML.master(id: MkID.video, videoElem))
        try write(EBML.master(id: MkID.tracks, EBML.master(id: MkID.trackEntry, track)))
    }

    func finish() throws {
        guard headerWritten, file != nil else {
            try? FileManager.default.removeItem(at: url)
            return
        }
        try flushCluster()

        var cues = Data()
        for entry in cueEntries {
            var positions = Data()
            positions.append(EBML.uint(id: MkID.cueTrack, 1))
            positions.append(EBML.uint(id: MkID.cueClusterPosition, entry.pos))
            var point = Data()
            point.append(EBML.uint(id: MkID.cueTime, entry.ms))
            point.append(EBML.master(id: MkID.cueTrackPositions, positions))
            cues.append(EBML.master(id: MkID.cuePoint, point))
        }
        if !cues.isEmpty { try write(EBML.master(id: MkID.cues, cues)) }

        if let pos = durationValueFileOffset {
            var bits = lastBlockEndMs.bitPattern
            var be = Data(capacity: 8)
            for _ in 0..<8 { be.append(UInt8(bits & 0xFF)); bits >>= 8 }
            be.reverse()
            file?.seek(toFileOffset: pos)
            file?.write(be)
        }
        try? file?.close()
        file = nil
    }
}
