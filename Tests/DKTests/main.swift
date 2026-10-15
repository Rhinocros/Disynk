import AVFoundation
import CoreGraphics
import CoreMedia
import CoreVideo
import DKCapture
import DKCompose
import DKCore
import DKEncode
import DKExport
import DKMux
import DKOverlay
import DKSettings
import DKShot
import DKVirtualDisplay
import Foundation
import ImageIO

// Disynk 测试 harness：本机 CLT 无 XCTest framework，用轻量断言 runner。
// 覆盖方案第七节可离线自动化项：
//   授权四类路径（激活/心跳/宽限期/篡改拒绝）、布局模型、编码器（合成帧）、
//   MKV/MP4 封装冒烟（EBML magic / ftyp）、设置持久化、分辨率解析、
//   WebM libvpx VP8/VP9 真实编码、Metal 合成位置一致性、磁盘探测、覆盖层键组合、捕获帧率钳制。

// MARK: - 断言与同步桥

var passed = 0
var failed: [String] = []
let reportLock = NSLock()

func check(_ cond: Bool, _ name: String) {
    reportLock.lock(); defer { reportLock.unlock() }
    if cond { passed += 1; print("  ✔ \(name)") }
    else { failed.append(name); print("  ✘ \(name)") }
}
func checkThrows(_ name: String, _ block: () throws -> Void) {
    do { _ = try block(); check(false, name + "（应抛错但未抛）") }
    catch { check(true, name) }
}

/// 顶层桥：阻塞等待一个 async 闭包（harness 非 @main async 环境）
func bridgeSync(_ work: @escaping () async -> Void) {
    let sem = DispatchSemaphore(value: 0)
    Task {
        await work()
        sem.signal()
    }
    _ = sem.wait(timeout: .now() + 30)
}

// MARK: - 合成帧与封装冒烟

func makeSourceFrames(count: Int, size: PixelSize) throws -> [CMSampleBuffer] {
    var out: [CMSampleBuffer] = []
    for i in 0..<count {
        var pb: CVPixelBuffer?
        let st = CVPixelBufferCreate(kCFAllocatorDefault, size.width, size.height,
                                     kCVPixelFormatType_420YpCbCr8BiPlanarFullRange,
                                     [kCVPixelBufferMetalCompatibilityKey: true] as CFDictionary, &pb)
        guard st == kCVReturnSuccess, let pb else { throw DKError.other("pixel buffer 分配失败") }
        var fd: CMVideoFormatDescription?
        guard CMVideoFormatDescriptionCreateForImageBuffer(allocator: nil, imageBuffer: pb,
                                                           formatDescriptionOut: &fd) == noErr,
              let fd else { throw DKError.other("format desc 失败") }
        let pts = CMTime(value: CMTimeValue(i), timescale: 30)
        var timing = CMSampleTimingInfo(duration: CMTime(value: 1, timescale: 30),
                                        presentationTimeStamp: pts, decodeTimeStamp: .invalid)
        var sb: CMSampleBuffer?
        guard CMSampleBufferCreateForImageBuffer(allocator: nil, imageBuffer: pb, dataReady: true,
                                                 makeDataReadyCallback: nil, refcon: nil,
                                                 formatDescription: fd, sampleTiming: &timing,
                                                 sampleBufferOut: &sb) == noErr, let sb else {
            throw DKError.other("sample buffer 失败")
        }
        out.append(sb)
    }
    return out
}

func muxSmoke(container: ContainerFormat, name: String, frames: [CMSampleBuffer]) {
    bridgeSync {
        do {
            let size = PixelSize(width: 640, height: 480)
            let url = FileManager.default.temporaryDirectory
                .appendingPathComponent("dktest-\(UUID().uuidString.prefix(6)).\(container.rawValue)")
            let desc = MuxerFactory.VideoDescriptor(codec: .h264, pixelSize: size,
                                                    displaySize: size, fps: 30)
            let muxer = try MuxerFactory.make(container: container, video: desc,
                                              audioTracks: [], outputURL: url)
            for sb in frames { try await muxer.appendVideo(sb) }
            try await muxer.finish()
            let head = try Data(contentsOf: url).prefix(12)
            if container == .mkv {
                check(Array(head.prefix(4)) == [0x1A, 0x45, 0xDF, 0xA3], "MKV 以 EBML magic 开头")
            } else {
                check(head.count >= 12 && Array(head[4...7]) == Array("ftyp".utf8),
                      "MP4 以 ftyp box 开头")
            }
            let attrs = try FileManager.default.attributesOfItem(atPath: url.path)
            check(((attrs[.size] as? NSNumber)?.int64Value ?? 0) > 100, "\(name) 产物非空")
            // GIF 离线导出冒烟（仅 MP4 用例后）：录制产物 → GIF
            if container == .mp4 {
                let gifURL = url.appendingPathExtension("gif")
                let bytes = try await GIFExporter.export(input: url, to: gifURL, fps: 5, maxLongEdge: 320)
                check(bytes > 0,
                      "GIF 导出成功（\(bytes) 字节）")
            }
        } catch {
            check(false, "\(name) 封装冒烟异常：\(error.localizedDescription)")
        }
    }
}

// MARK: - 合成 PCM 音频样本缓冲（48kHz 立体声 Float32）

func makePCMFrameBuffer(frames: Int, startSecond: Double) -> CMSampleBuffer? {
    var asbd = AudioStreamBasicDescription(
        mSampleRate: 48_000, mFormatID: kAudioFormatLinearPCM,
        mFormatFlags: kLinearPCMFormatFlagIsFloat | kLinearPCMFormatFlagIsPacked,
        mBytesPerPacket: 8, mFramesPerPacket: 1, mBytesPerFrame: 8,
        mChannelsPerFrame: 2, mBitsPerChannel: 32, mReserved: 0)
    var fmtDesc: CMAudioFormatDescription?
    guard CMAudioFormatDescriptionCreate(allocator: kCFAllocatorDefault, asbd: &asbd,
                                         layoutSize: 0, layout: nil, magicCookieSize: 0,
                                         magicCookie: nil, extensions: nil,
                                         formatDescriptionOut: &fmtDesc) == noErr,
            let fmtDesc else { return nil }
    var samples = [Float](repeating: 0, count: frames * 2)
    for i in 0..<samples.count { samples[i] = Float(sin(Double(i) * 0.05)) * 0.3 }
    let bytes = samples.count * MemoryLayout<Float>.size

    var block: CMBlockBuffer?
    guard CMBlockBufferCreateWithMemoryBlock(allocator: kCFAllocatorDefault, memoryBlock: nil,
                                             blockLength: bytes, blockAllocator: kCFAllocatorDefault,
                                             customBlockSource: nil, offsetToData: 0, dataLength: bytes,
                                             flags: 0, blockBufferOut: &block) == kCMBlockBufferNoErr,
            let block else { return nil }
    var filled = false
    samples.withUnsafeMutableBytes { raw in
        if CMBlockBufferReplaceDataBytes(with: raw.baseAddress!, blockBuffer: block,
                                         offsetIntoDestination: 0, dataLength: bytes) == noErr {
            filled = true
        }
    }
    guard filled else { return nil }

    let scale: CMTimeScale = 48_000
    let pts = CMTime(value: CMTimeValue(startSecond * Double(scale)), timescale: scale)
    var timing = CMSampleTimingInfo(duration: CMTime(value: CMTimeValue(frames), timescale: scale),
                                    presentationTimeStamp: pts, decodeTimeStamp: .invalid)
    var sampleSize = bytes
    var sb: CMSampleBuffer?
    guard CMSampleBufferCreateReady(allocator: kCFAllocatorDefault, dataBuffer: block,
                                    formatDescription: fmtDesc, sampleCount: CMItemIndex(frames),
                                    sampleTimingEntryCount: 1, sampleTimingArray: &timing,
                                    sampleSizeEntryCount: 1, sampleSizeArray: &sampleSize,
                                    sampleBufferOut: &sb) == noErr, let sb else { return nil }
    return sb
}

/// 测试用压缩帧收集器：HardwareEncoder.outputHandler 是 @Sendable 闭包，而
/// CMSampleBuffer 非 Sendable——收/取均经这一个 @unchecked Sendable 容器（内部加锁），
/// 避免在闭包里改捕获变量、在 async 上下文直接使 NSLock。
final class FrameSink: @unchecked Sendable {
    private let lock = NSLock()
    private var frames: [CMSampleBuffer] = []
    func append(_ sb: CMSampleBuffer) { lock.lock(); frames.append(sb); lock.unlock() }
    var count: Int { lock.lock(); defer { lock.unlock() }; return frames.count }
    func take() -> [CMSampleBuffer] { lock.lock(); defer { lock.unlock() }; return frames }
}

// MARK: - MKV 音轨集成用例（方案第七节：H.264 + AAC 封装 MKV）

func mkvAudioTest() {
    let size = PixelSize(width: 640, height: 480)
    bridgeSync {
        do {
            let sink = FrameSink()
            let enc = try HardwareEncoder(
                config: .init(codec: .h264, size: size, frameRate: .p30, bitrateBps: 800_000),
                outputHandler: { sb, _ in sink.append(sb) })
            for f in try makeSourceFrames(count: 12, size: size) { enc.encode(f) }
            enc.flush(); enc.invalidate()
            let frames = sink.take()
            check(!frames.isEmpty, "MKV 音轨用例：获得压缩视频帧")

            var audioSBs: [CMSampleBuffer] = []
            for c in 0..<8 {
                if let a = makePCMFrameBuffer(frames: 1024, startSecond: Double(c) * (1024.0 / 48_000.0)) {
                    audioSBs.append(a)
                }
            }
            check(audioSBs.count == 8, "构造 8 段 48k 立体声 PCM 样本缓冲")

            let dir = FileManager.default.temporaryDirectory
            let desc = MuxerFactory.VideoDescriptor(codec: .h264, pixelSize: size,
                                                    displaySize: size, fps: 30)
            let urlA = dir.appendingPathComponent("dktest-audio-\(UUID().uuidString.prefix(6)).mkv")
            let muxA = try MuxerFactory.make(container: .mkv, video: desc,
                                             audioTracks: [.system], outputURL: urlA)
            for sb in frames { try await muxA.appendVideo(sb) }
            for a in audioSBs { try await muxA.appendAudio(a, track: .system) }
            try await muxA.finish()

            let urlV = dir.appendingPathComponent("dktest-video-\(UUID().uuidString.prefix(6)).mkv")
            let muxV = try MuxerFactory.make(container: .mkv, video: desc,
                                             audioTracks: [], outputURL: urlV)
            for sb in frames { try await muxV.appendVideo(sb) }
            try await muxV.finish()

            let dataA = try Data(contentsOf: urlA)
            let dataV = try Data(contentsOf: urlV)
            check(Array(dataA.prefix(4)) == [0x1A, 0x45, 0xDF, 0xA3], "MKV+音频以 EBML magic 开头")
            check(dataA.range(of: Data("A_AAC".utf8)) != nil, "MKV 写入 A_AAC 音轨条目")
            check(dataA.count > dataV.count + 200,
                  "MKV 含音轨体积显著大于纯视频（已写入 AAC 块 \(dataA.count - dataV.count) 字节）")
            // 结构回归：验证关键 EBML ID 与 Matroska 官方一致（历史上曾错写为 0x2586 81/0x55B0/0x55BA，
            // 导致 ffmpeg “Unknown entry”+“could not find codec parameters”）。参见 docs/ARCHITECTURE.md
            check(dataV.range(of: Data([0x25, 0x86, 0x81])) == nil,
                  "MKV 不再包含错用的 CodecPrivate ID 0x2586 81")
            check(dataV.range(of: Data([0x63, 0xA2])) != nil,
                  "MKV 写入规范的 CodecPrivate ID 0x63A2")
            check(dataV.range(of: Data([0x54, 0xB0])) != nil,
                  "MKV 写入规范的 DisplayWidth ID 0x54B0")
            check(dataV.range(of: Data([0x54, 0xBA])) != nil,
                  "MKV 写入规范的 DisplayHeight ID 0x54BA")
            check(dataV.range(of: Data([0x55, 0xB0])) == nil &&
                  dataV.range(of: Data([0x55, 0xBA])) == nil,
                  "MKV 不再包含错用的 0x55B0/0x55BA")
            // 持久化到稳定路径供 Scripts/verify_media.py 用 PyAV/ffmpeg 做外部解码验收
            // （§七「ffprobe/VLC 校验时长、音画同步」——无本地 ffprobe 时经镜像的 ffmpeg 探针核实
            //   该 MKV 确有 1 视频轨 + 1 A_AAC 音轨且时长 > 0，而非仅字节级结构断言）。
            if let fixed = ProcessInfo.processInfo.environment["DISYNK_MKV_AUDIO_FIXTURE"] {
                try? FileManager.default.removeItem(atPath: fixed)
                try Data(contentsOf: urlA).write(to: URL(fileURLWithPath: fixed))
                try? FileManager.default.removeItem(at: urlA)
                try? FileManager.default.removeItem(at: urlV)
            }
        } catch {
            check(false, "MKV 音轨用例异常：\(error.localizedDescription)")
        }
    }
}

// MARK: - 布局用例

func layoutTests() {
    let snapA = DisplaySnapshot(id: 1, name: "A", sourceSize: PixelSize(width: 1920, height: 1080),
                                refreshRateHz: 60, isVirtual: false, origin: .zero)
    let snapB = DisplaySnapshot(id: 2, name: "B", sourceSize: PixelSize(width: 2560, height: 1440),
                                refreshRateHz: 60, isVirtual: false, origin: .zero)
    let h = ComposeLayout.horizontal([snapA, snapB])
    check(h.placements.count == 2, "横向预设两 placement")
    check(h.placements.allSatisfy { $0.w > 0 && $0.h > 0 && $0.x >= -0.0001 && $0.x + $0.w <= 1.0001 },
          "横向预设归一化范围合法")
    let v = ComposeLayout.vertical([snapA, snapB])
    check(v.placements.count == 2, "竖向预设两 placement")
    let g = ComposeLayout.mixedGrid([snapA, snapB, snapA, snapB])
    check(g.placements.count == 4, "混合网格 4 屏")
    var moved = h
    moved.move(displayID: 1, x: 5.0, y: -3.0)
    if let p = moved.placements.first(where: { $0.displayID == 1 }) {
        check(p.x + p.w <= 1.0001 && p.y >= -0.0001, "move 越界被钳制")
    }
    let huge = ComposeLayout(canvasWidth: 16000, canvasHeight: 2000,
                             placements: [ComposeLayout.Placement(displayID: 1, x: 0, y: 0, w: 1, h: 1)])
    check(huge.clamped().canvasWidth <= 8192, "超 8K 宽画布自动钳制")

    // 增量同步：保留手动拖拽位，仅为新增屏补位 / 移除取消屏（方案：拖拽为主、按钮为预设）
    var manual = ComposeLayout(canvasWidth: 1920, canvasHeight: 1080,
                               placements: [ComposeLayout.Placement(displayID: 1, x: 0.07, y: 0.11, w: 0.5, h: 0.5)])
    manual.sync(to: [snapA, snapB])
    if let a = manual.placements.first(where: { $0.displayID == 1 }) {
        check(a.x == 0.07 && a.y == 0.11 && a.w == 0.5 && a.h == 0.5, "sync 不改变已有屏手动摆放")
    } else { check(false, "sync 不改变已有屏手动摆放") }
    check(manual.placements.contains { $0.displayID == 2 }, "sync 为新增屏补位")
    manual.sync(to: [snapB])
    check(manual.placements.count == 1 && manual.placements.first?.displayID == 2, "sync 移除已取消勾选的屏")

    // —— 真实像素 1:1 摆放 + 自由拖拽（旧版把单元格定死 1920x1080，且横排预设下块高 =
    //    画布高 → move 的钳制把 y 锁死在 0，表现为「摆不成上下排列」；2K 屏还被降级显示）。
    let k1 = DisplaySnapshot(id: 11, name: "K1", sourceSize: PixelSize(width: 2560, height: 1440),
                             refreshRateHz: 60, isVirtual: false, origin: .zero)
    let k2 = DisplaySnapshot(id: 12, name: "K2", sourceSize: PixelSize(width: 2560, height: 1440),
                             refreshRateHz: 60, isVirtual: false, origin: .zero)
    let hh = ComposeLayout.horizontal([k1, k2])
    check(hh.canvasWidth == 5120 && hh.canvasHeight == 2880,
          "横排预设：舞台按真实像素铺开 5120x2880（实得 \(hh.canvasWidth)x\(hh.canvasHeight)）")
    check(hh.placements.allSatisfy { $0.pixelSize(canvas: hh.canvas) == PixelSize(width: 2560, height: 1440) },
          "横排预设：每块仍是 2560x1440 真实分辨率（不再被缩成 1080p）")
    check(hh.placements.allSatisfy { $0.h < 0.999 },
          "横排预设：块高小于舞台高 → 纵向有拖拽余量（旧版被钳死在 y=0）")

    var stacked = hh
    stacked.dragTile(displayID: 12, x: 0, y: 0.9)     // 把第二块拖到第一块下方（越界）
    check(stacked.canvasHeight > hh.canvasHeight,
          "dragTile：拖出舞台边界自动扩大画布（高 \(hh.canvasHeight)→\(stacked.canvasHeight)）")
    check(stacked.placements.allSatisfy { abs(Double($0.pixelRect(canvas: stacked.canvas).h) - 1440) <= 2 },
          "dragTile：扩舞台不改变各块像素高（仍约 1440）")
    let cut = stacked.croppedToContent()
    check(cut.canvasWidth == 2560 && cut.canvasHeight > cut.canvasWidth,
          "croppedToContent：摆成上下排列 → 输出 \(cut.canvasWidth)x\(cut.canvasHeight)（高>宽，无黑边）")
    check(cut.placements.count == 2
            && cut.placements.allSatisfy { $0.x >= -0.0001 && $0.y >= -0.0001
                && $0.x + $0.w <= 1.0001 && $0.y + $0.h <= 1.0001 },
          "croppedToContent：各块完整落在输出画布内")
    check(cut.placements.allSatisfy { abs(Double($0.pixelRect(canvas: cut.canvas).h) - 1440) <= 2 },
          "croppedToContent：裁剪后每块仍约 1440 像素高（怎么摆就怎么合）")
    let untouched = hh.croppedToContent()   // 块已占满横向 → 只收成上下两条空白边
    check(untouched.canvasWidth == 5120 && untouched.canvasHeight == 1440,
          "croppedToContent：横排未拖动时只裁空白边距（5120x1440，实得 \(untouched.canvasWidth)x\(untouched.canvasHeight)）")
}

// MARK: - 编码/封装用例

func encodeMuxTests() {
    let size = PixelSize(width: 640, height: 480)
    let sink = FrameSink()
    do {
        let enc = try HardwareEncoder(
            config: .init(codec: .h264, size: size, frameRate: .p30, bitrateBps: 800_000),
            outputHandler: { sb, _ in
                sink.append(sb)
            })
        var okFrames = 0
        for f in try makeSourceFrames(count: 12, size: size) where enc.encode(f) {
            okFrames += 1
        }
        enc.flush()
        enc.invalidate()
        check(okFrames == 12, "12 帧全部送入编码器")
        let got = sink.count
        check(got > 0, "H.264 编码器产出压缩帧 \(got) 个")
        let frames = sink.take()
        muxSmoke(container: .mkv, name: "MKV", frames: frames)
        muxSmoke(container: .mp4, name: "MP4", frames: frames)
    } catch {
        check(false, "编码/封装冒烟异常：\(error.localizedDescription)")
    }
}

// HEVC 封装矩阵（对齐 §三「编码格式：H.264/HEVC/ProRes + 容器 MP4/MOV/MKV」）：
// VideoToolbox 支持 HEVC 硬编 → 验证 MKV(内置 EBML) + MOV(AVAssetWriter) 两路径产出非空。
// Apple Silicon 同时提供 HEVC 编码器；Intel 上此用例失败可接受（方案 §八 已标注 Intel 差异）。
func hevcMuxTests() {
    let size = PixelSize(width: 640, height: 480)
    let sink = FrameSink()
    bridgeSync {
        do {
            let enc = try HardwareEncoder(
                config: .init(codec: .hevc, size: size, frameRate: .p30, bitrateBps: 800_000),
                outputHandler: { sb, _ in sink.append(sb) })
            for f in try makeSourceFrames(count: 8, size: size) { _ = enc.encode(f) }
            enc.flush(); enc.invalidate()
            let frames = sink.take()
            check(!frames.isEmpty, "HEVC 编码器产出压缩帧 \(frames.count) 个")
            for (container, tag) in [(ContainerFormat.mkv, "HEVC/MKV"), (.mov, "HEVC/MOV")] {
                let url = FileManager.default.temporaryDirectory
                    .appendingPathComponent("dktest-hevc-\(UUID().uuidString.prefix(6)).\(container.rawValue)")
                let desc = MuxerFactory.VideoDescriptor(codec: .hevc, pixelSize: size,
                                                        displaySize: size, fps: 30)
                let mux = try MuxerFactory.make(container: container, video: desc,
                                                audioTracks: [], outputURL: url)
                for sb in frames { try await mux.appendVideo(sb) }
                try await mux.finish()
                let data = try Data(contentsOf: url)
                check(data.count > 100, "\(tag) 产物非空（\(data.count) 字节）")
                if container == .mkv {
                    check(Array(data.prefix(4)) == [0x1A, 0x45, 0xDF, 0xA3], "\(tag) EBML magic")
                    check(data.range(of: Data("V_MPEGH/ISO/HEVC".utf8)) != nil, "\(tag) codecID")
                    // 确保 CodecPrivate ID = 0x63A2 已就位（hvcC），与 H.264 用例同源回归保护
                    check(data.range(of: Data([0x63, 0xA2])) != nil, "\(tag) 写入规范 CodecPrivate ID 0x63A2")
                    // hvcC 实内容大小断言：包含 header(22B)+numOfArrays(1B)+≥ 一个 array（≥ 4B 头）
                    // 旧 stub 仅 16B（numOfArrays=0）会导致 ffmpeg 无法初始化 HEVC 解码器
                    let cpIdx = data.range(of: Data([0x63, 0xA2]))!.upperBound
                    let sizeByte = data[data.index(data.startIndex, offsetBy: cpIdx)]
                    let hvcSize = Int(sizeByte & 0x7F) // 假定 size 为单字节 VINT（hvcC 均 <128）
                    check(hvcSize >= 24, "\(tag) hvcC 大小 = \(hvcSize) 字节（包含参数集 array）")
                    // 落盘到稳定路径供 verify_media.py 外部解码验收（§七 HEVC-MKV）
                    if let fixed = ProcessInfo.processInfo.environment["DISYNK_MKV_HEVC_FIXTURE"] {
                        try? FileManager.default.removeItem(atPath: fixed)
                        try data.write(to: URL(fileURLWithPath: fixed))
                    }
                } else {
                    check(data.count >= 12 && Array(data[4...7]) == Array("ftyp".utf8), "\(tag) ftyp box")
                }
            }
        } catch {
            check(false, "HEVC 封装用例异常：\(error.localizedDescription)")
        }
    }
}

// ProRes 冒烟（§三：编码格式 ProRes 422）：VideoToolbox kCMVideoCodecType_ProRes422 硬/软编；
// 仅验证 MP4 容器产出（MKV 拒 ProRes，RecordingMuxer 已断例）。
func proResSmoke() {
    let size = PixelSize(width: 640, height: 480)
    bridgeSync {
        do {
            let sink = FrameSink()
            let enc = try HardwareEncoder(
                config: .init(codec: .proRes422, size: size, frameRate: .p30, bitrateBps: 0),
                outputHandler: { sb, _ in sink.append(sb) })
            for f in try makeSourceFrames(count: 6, size: size) { _ = enc.encode(f) }
            enc.flush(); enc.invalidate()
            let frames = sink.take()
            check(!frames.isEmpty, "ProRes 编码器产出压缩帧 \(frames.count) 个")
            let url = FileManager.default.temporaryDirectory
                .appendingPathComponent("dktest-prores-\(UUID().uuidString.prefix(6)).mov")
            let desc = MuxerFactory.VideoDescriptor(codec: .proRes422, pixelSize: size,
                                                    displaySize: size, fps: 30)
            let mux = try MuxerFactory.make(container: .mov, video: desc,
                                            audioTracks: [], outputURL: url)
            for sb in frames { try await mux.appendVideo(sb) }
            try await mux.finish()
            let data = try Data(contentsOf: url)
            check(data.count > 500, "ProRes/MOV 产物非空（\(data.count) 字节）")
        } catch {
            check(false, "ProRes 冒烟异常：\(error.localizedDescription)")
        }
    }
}

// MARK: - WebM 容器集成用例（注入假 libvpx codec，验证抽帧→编码→封装管线）

func webmContainerTest() {
    let size = PixelSize(width: 640, height: 480)
    bridgeSync {
        do {
            // 1) 造一个真实 MP4（供 AVAssetReader 解码出像素帧）
            let sink = FrameSink()
            let enc = try HardwareEncoder(
                config: .init(codec: .h264, size: size, frameRate: .p30, bitrateBps: 800_000),
                outputHandler: { sb, _ in sink.append(sb) })
            for f in try makeSourceFrames(count: 12, size: size) { enc.encode(f) }
            enc.flush(); enc.invalidate()
            let frames = sink.take()

            let dir = FileManager.default.temporaryDirectory
            let mp4 = dir.appendingPathComponent("dktest-webmsrc-\(UUID().uuidString.prefix(6)).mp4")
            let desc = MuxerFactory.VideoDescriptor(codec: .h264, pixelSize: size,
                                                    displaySize: size, fps: 30)
            let mux = try MuxerFactory.make(container: .mp4, video: desc,
                                            audioTracks: [], outputURL: mp4)
            for sb in frames { try await mux.appendVideo(sb) }
            try await mux.finish()

            // 2) 未注入 codec → 显式报错（真实开发环境基线）
            WebMExporter.codecFactory = nil
            var threwUnsupported = false
            do { try await WebMExporter.export(input: mp4, to: mp4.appendingPathExtension("webm"), codec: .vp8) }
            catch { threwUnsupported = true }
            check(threwUnsupported, "WebM 未注入 libvpx 时显式报错")

            // 3) 注入假 codec（真实环境替换为 vpx 编码），验证容器产出
            WebMExporter.codecFactory = { _, _, _, _ in
                WebMExporter.WebMCodec(
                    name: "V_VP8",
                    encodeFrame: { _, _, _, _, _, _, pts in
                        Data([0x00, 0x80, UInt8(clamping: Int(pts * 1000) & 0xFF), 0x7A])
                    },
                    finish: { return [Data([0x01, 0x02])] })
            }
            let webm = dir.appendingPathComponent("dktest-\(UUID().uuidString.prefix(6)).webm")
            try await WebMExporter.export(input: mp4, to: webm, codec: .vp8, crf: 32)
            let data = try Data(contentsOf: webm)
            check(Array(data.prefix(4)) == [0x1A, 0x45, 0xDF, 0xA3], "WebM 以 EBML magic 开头")
            check(data.range(of: Data("webm".utf8)) != nil, "WebM DocType=webm")
            check(data.range(of: Data("V_VP8".utf8)) != nil, "WebM 写入 V_VP8 codecID")
            check(data.count > 200, "WebM 容器非空（\(data.count) 字节）")
            WebMExporter.codecFactory = nil
        } catch {
            check(false, "WebM 容器用例异常：\(error.localizedDescription)")
        }
    }
}

#if DISYNK_LIBVPX
// MARK: - WebM 真实 libvpx VP8 编码集成用例（DISYNK_WITH_LIBVPX=1 时激活）
// 验证 DKExport/LibVPXBridge 接入真实 vpx_codec_enc_init_ver/_encode/_get_cx_data 后，
// 抽帧→编码→封装全链路能产出含关键帧起始码 (9D 01 2A) 的 VP8 码流。
func webmLibVPXRealTest() {
    let size = PixelSize(width: 320, height: 240)
    bridgeSync {
        do {
            // 1) 先造真实源 MP4（与假 codec 用例同模式）
            let sink = FrameSink()
            let enc = try HardwareEncoder(
                config: .init(codec: .h264, size: size, frameRate: .p30, bitrateBps: 800_000),
                outputHandler: { sb, _ in sink.append(sb) })
            for f in try makeSourceFrames(count: 8, size: size) { enc.encode(f) }
            enc.flush(); enc.invalidate()
            let frames = sink.take()

            let dir = FileManager.default.temporaryDirectory
            let mp4 = dir.appendingPathComponent("dktest-vpxsrc-\(UUID().uuidString.prefix(6)).mp4")
            let desc = MuxerFactory.VideoDescriptor(codec: .h264, pixelSize: size,
                                                    displaySize: size, fps: 30)
            let mux = try MuxerFactory.make(container: .mp4, video: desc,
                                            audioTracks: [], outputURL: mp4)
            for sb in frames { try await mux.appendVideo(sb) }
            try await mux.finish()

            // 2) 注入真实 libvpx factory，导出 VP8 + VP9 双码流
            //    方案第三/七节均要求「WebM（VP8/VP9）」，两者都需端到端产出有效容器。
            WebMExporter.installLibVPXCodec()
            check(WebMExporter.codecFactory != nil, "libvpx 真实 factory 已注入")

            // --- VP8：验 EBML/DocType/V_VP8/关键帧起始码 (9D 01 2A) ---
            let webm8 = dir.appendingPathComponent("dktest-realvp8-\(UUID().uuidString.prefix(6)).webm")
            try await WebMExporter.export(input: mp4, to: webm8, codec: .vp8, crf: 32)
            let data8 = try Data(contentsOf: webm8)
            check(Array(data8.prefix(4)) == [0x1A, 0x45, 0xDF, 0xA3], "真实 VP8 WebM 以 EBML 开头")
            check(data8.range(of: Data("webm".utf8)) != nil, "真实 VP8 DocType=webm")
            check(data8.range(of: Data("V_VP8".utf8)) != nil, "真实 VP8 codecID=V_VP8")
            check(data8.range(of: Data([0x9D, 0x01, 0x2A])) != nil,
                  "真实 VP8 关键帧起始码 9D 01 2A 存在（确认 vpx 产物非占位假数据）")
            check(data8.count > 400, "真实 VP8 WebM 体积 > 400B（\(data8.count) 字节）")
            if let fixed = ProcessInfo.processInfo.environment["DISYNK_WEBM_VP8_FIXTURE"] {
                try? FileManager.default.removeItem(atPath: fixed)
                try data8.write(to: URL(fileURLWithPath: fixed))
            }

            // --- VP9：验 EBML/DocType/V_VP9 + 真实码流体积（VP9 无 VP8 式固定同步码） ---
            let webm9 = dir.appendingPathComponent("dktest-realvp9-\(UUID().uuidString.prefix(6)).webm")
            try await WebMExporter.export(input: mp4, to: webm9, codec: .vp9, crf: 32)
            let data9 = try Data(contentsOf: webm9)
            check(Array(data9.prefix(4)) == [0x1A, 0x45, 0xDF, 0xA3], "真实 VP9 WebM 以 EBML 开头")
            check(data9.range(of: Data("webm".utf8)) != nil, "真实 VP9 DocType=webm")
            check(data9.range(of: Data("V_VP9".utf8)) != nil, "真实 VP9 codecID=V_VP9")
            check(data9.range(of: Data("V_VP8".utf8)) == nil, "真实 VP9 不误写 V_VP8 codecID")
            check(data9.count > 400, "真实 VP9 WebM 体积 > 400B（\(data9.count) 字节）")
            if let fixed = ProcessInfo.processInfo.environment["DISYNK_WEBM_VP9_FIXTURE"] {
                try? FileManager.default.removeItem(atPath: fixed)
                try data9.write(to: URL(fileURLWithPath: fixed))
            }

            // 3) 清理：保证后续假 codec 用例仍从 nil 基线开始
            WebMExporter.codecFactory = nil
        } catch {
            check(false, "真实 VP8/VP9 WebM 用例异常：\(error.localizedDescription)")
        }
    }
}
#endif

// MARK: - 合成坐标工具

func makeSolidBGRA(_ b: UInt8, _ g: UInt8, _ r: UInt8, _ a: UInt8,
                   width: Int, height: Int) -> CVPixelBuffer? {
    var pb: CVPixelBuffer?
    // 与真实 SCStream 输出一致：IOSurface 后端 + MetalCompatibility，
    // 否则 CVMetalTextureCacheCreateTextureFromImage 无法包装为纹理。
    let attrs = [
        kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
        kCVPixelBufferMetalCompatibilityKey as String: true,
        kCVPixelBufferIOSurfacePropertiesKey as String: [:],
    ] as CFDictionary
    guard CVPixelBufferCreate(kCFAllocatorDefault, width, height,
                              kCVPixelFormatType_32BGRA, attrs, &pb) == kCVReturnSuccess,
            let pb else { return nil }
    CVPixelBufferLockBaseAddress(pb, [])
    defer { CVPixelBufferUnlockBaseAddress(pb, []) }
    guard let base = CVPixelBufferGetBaseAddress(pb) else { return pb }
    let bpr = CVPixelBufferGetBytesPerRow(pb)
    for y in 0..<height {
        let row = base.advanced(by: y * bpr).assumingMemoryBound(to: UInt8.self)
        for x in 0..<width {
            let o = x * 4
            row[o] = b; row[o + 1] = g; row[o + 2] = r; row[o + 3] = a
        }
    }
    return pb
}

func samplePixel(_ pb: CVPixelBuffer, x: Int, y: Int) -> (b: Int, g: Int, r: Int, a: Int) {
    CVPixelBufferLockBaseAddress(pb, .readOnly)
    defer { CVPixelBufferUnlockBaseAddress(pb, .readOnly) }
    let base = CVPixelBufferGetBaseAddress(pb)!
    let bpr = CVPixelBufferGetBytesPerRow(pb)
    let p = base.advanced(by: y * bpr + x * 4).assumingMemoryBound(to: UInt8.self)
    return (Int(p[0]), Int(p[1]), Int(p[2]), Int(p[3]))
}

// MARK: - 合并合成集成用例（方案第七节：画面位置与布局一致、允许 ≤1 帧偏差）

func composeMergeTest() {
    var layout = ComposeLayout(canvasWidth: 640, canvasHeight: 480, placements: [
        ComposeLayout.Placement(displayID: 1, x: 0.0, y: 0.0, w: 0.5, h: 1.0),
        ComposeLayout.Placement(displayID: 2, x: 0.5, y: 0.0, w: 0.5, h: 1.0),
    ])
    guard let red = makeSolidBGRA(0, 0, 255, 255, width: 640, height: 480),
          let blue = makeSolidBGRA(255, 0, 0, 255, width: 640, height: 480) else {
        check(false, "合成用例：源像素缓冲创建"); return
    }
    let comp = MetalCompositor(layout: layout)
    guard let out = comp.compose([1: red, 2: blue]) else { check(false, "合成输出 nil"); return }
    let ow = CVPixelBufferGetWidth(out), oh = CVPixelBufferGetHeight(out)
    check(ow == 640 && oh == 480, "合成画布尺寸 640x480（\(ow)x\(oh)，Metal=\(comp.isMetalActive)）")
    let left = samplePixel(out, x: 20, y: 240)
    let right = samplePixel(out, x: 620, y: 240)
    check(left.r > 150 && left.b < 90, "左半来自屏1（红） r=\(left.r) b=\(left.b)")
    check(right.b > 150 && right.r < 90, "右半来自屏2（蓝） b=\(right.b) r=\(right.r)")

    // 强制 CPU 回退路径（方案 M2.5：无 GPU 时自动/可验证与 Metal 功能等价）
    let cgComp = MetalCompositor(layout: layout, forceCPUFallback: true)
    check(!cgComp.isMetalActive, "forceCPUFallback 下走 CPU 回退（isMetalActive=false）")
    if let cgOut = cgComp.compose([1: red, 2: blue]) {
        let cl = samplePixel(cgOut, x: 20, y: 240)
        let cr = samplePixel(cgOut, x: 620, y: 240)
        check(CVPixelBufferGetWidth(cgOut) == 640 && CVPixelBufferGetHeight(cgOut) == 480,
              "CPU 回退输出尺寸 640x480")
        check(cl.r > 150 && cl.b < 90, "CPU 回退左半=屏1（红） r=\(cl.r) b=\(cl.b)")
        check(cr.b > 150 && cr.r < 90, "CPU 回退右半=屏2（蓝） b=\(cr.b) r=\(cr.r)")
    } else {
        check(false, "CPU 回退合成输出 nil")
    }

    // 拖拽重排：交换两屏位置，画面随之交换
    layout.move(displayID: 1, x: 0.5, y: 0.0)
    layout.move(displayID: 2, x: 0.0, y: 0.0)
    comp.setLayout(layout)
    if let out2 = comp.compose([1: red, 2: blue]) {
        let l2 = samplePixel(out2, x: 20, y: 240)
        let r2 = samplePixel(out2, x: 620, y: 240)
        check(l2.b > 150 && r2.r > 150, "拖拽 move 后左右画面交换（位置随布局）")
    } else { check(false, "重排合成输出 nil") }
}

// 将（已合成的）CVPixelBuffer 包装为可入编码器的 CMSampleBuffer。
func sampleBuffer(fromPixel pb: CVPixelBuffer, pts: CMTime, duration: CMTime) -> CMSampleBuffer? {
    var fd: CMVideoFormatDescription?
    guard CMVideoFormatDescriptionCreateForImageBuffer(allocator: nil, imageBuffer: pb,
                                                       formatDescriptionOut: &fd) == noErr,
          let fd else { return nil }
    var timing = CMSampleTimingInfo(duration: duration, presentationTimeStamp: pts,
                                    decodeTimeStamp: .invalid)
    var sb: CMSampleBuffer?
    guard CMSampleBufferCreateForImageBuffer(allocator: nil, imageBuffer: pb, dataReady: true,
                                             makeDataReadyCallback: nil, refcon: nil,
                                             formatDescription: fd, sampleTiming: &timing,
                                             sampleBufferOut: &sb) == noErr, let sb else { return nil }
    return sb
}

// 方案第七节「合并模式验收：2~3 路…合成单文件」的端到端链路：
// 多路源屏 BGRA → MetalCompositor 按布局合成单帧 → H.264 编码 → MKV 封装为单个文件。
// 超越仅像素位置断言（composeMergeTest），坐实“合成→编码→封装单文件”真实产物可形
// 成有效容器（可选经 DISYNK_MKV_MERGE_FIXTURE 落盘供 verify_media.py 外部解码+颜色布局复核）。
func composeMergeToFileTest() {
    let canvas = PixelSize(width: 320, height: 160)
    let layout = ComposeLayout(canvasWidth: 320, canvasHeight: 160, placements: [
        ComposeLayout.Placement(displayID: 1, x: 0.0, y: 0.0, w: 0.5, h: 1.0),
        ComposeLayout.Placement(displayID: 2, x: 0.5, y: 0.0, w: 0.5, h: 1.0),
    ])
    guard let red = makeSolidBGRA(0, 0, 255, 255, width: 320, height: 160),
          let blue = makeSolidBGRA(255, 0, 0, 255, width: 320, height: 160) else {
        check(false, "合并单文件用例：源像素缓冲创建"); return
    }
    let comp = MetalCompositor(layout: layout)
    let frameCount = 8
    var composed: [CMSampleBuffer] = []
    for i in 0..<frameCount {
        guard let out = comp.compose([1: red, 2: blue]) else { check(false, "合并用例：合成输出 nil"); return }
        let pts = CMTime(value: CMTimeValue(i), timescale: 30)
        let dur = CMTime(value: 1, timescale: 30)
        if let sb = sampleBuffer(fromPixel: out, pts: pts, duration: dur) { composed.append(sb) }
    }
    check(composed.count == frameCount, "合成帧包装为样本缓冲 \(composed.count)/\(frameCount)")

    bridgeSync {
        do {
            let sink = FrameSink()
            let enc = try HardwareEncoder(
                config: .init(codec: .h264, size: canvas, frameRate: .p30, bitrateBps: 1_200_000,
                              allowFrameReordering: false, inputFormat: kCVPixelFormatType_32BGRA),
                outputHandler: { sb, _ in sink.append(sb) })
            for sb in composed { _ = enc.encode(sb) }
            enc.flush(); enc.invalidate()
            let cf = sink.take()
            check(!cf.isEmpty, "合并单文件用例：编码产出压缩帧 \(cf.count)")

            let dir = FileManager.default.temporaryDirectory
            let url = dir.appendingPathComponent("dktest-merge-\(UUID().uuidString.prefix(6)).mkv")
            let desc = MuxerFactory.VideoDescriptor(codec: .h264, pixelSize: canvas,
                                                    displaySize: canvas, fps: 30)
            let mux = try MuxerFactory.make(container: .mkv, video: desc,
                                            audioTracks: [], outputURL: url)
            for sb in cf { try await mux.appendVideo(sb) }
            try await mux.finish()
            let data = try Data(contentsOf: url)
            check(Array(data.prefix(4)) == [0x1A, 0x45, 0xDF, 0xA3], "合并单文件 MKV EBML magic")
            check(data.range(of: Data("V_MPEG4/ISO/AVC".utf8)) != nil, "合并单文件写入 H.264 codecID")
            check(data.count > 200, "合并单文件产物非空（\(data.count) 字节）")
            if let fixed = ProcessInfo.processInfo.environment["DISYNK_MKV_MERGE_FIXTURE"] {
                try? FileManager.default.removeItem(atPath: fixed)
                try data.write(to: URL(fileURLWithPath: fixed))
                try? FileManager.default.removeItem(at: url)
            }
        } catch {
            check(false, "合并单文件用例异常：\(error.localizedDescription)")
        }
    }
}

// MARK: - 合并对齐门（方案 M2.5/§七：≤ 1 帧偏差、“凑齐一帧”）

func composeGateTest() {
    func t(_ num: Int64) -> CMTime { CMTime(value: CMTimeValue(num), timescale: 60) }
    // 空期望集 → 永不就绪
    let empty = ComposeGate(expected: [])
    check(!empty.isReady && empty.mergedPTS == nil, "空期望集不就绪")

    // 两屏：仅一屏到达 → 不就绪
    var g = ComposeGate(expected: [1, 2])
    g.note(1, pts: t(60))
    check(!g.isReady, "仅一屏有帧时不就绪")
    // 非期望屏的帧被忽略
    g.note(99, pts: t(10))
    check(!g.isReady, "非期望屏帧被忽略")
    // 两屏齐 → 就绪，合成 PTS = 各屏 PTS 最小值
    g.note(2, pts: t(120))
    check(g.isReady, "两屏均有未消费新帧→就绪")
    check(g.mergedPTS == t(60), "合成 PTS 取两屏最小值 60/60s")
    // 合成后消费 → 再次不就绪（等待各屏下一新帧，偏差≤一帧）
    g.markConsumed()
    check(!g.isReady, "消费后不就绪（需等屏刷新帧）")
    // 屏1 连进两帧（追平落后帧），屏2 仍为已消费旧帧 → 不就绪（≤ 1 帧对齐保证）
    g.note(1, pts: t(180))
    check(!g.isReady, "一屏追帧但另一屏未更新→不就绪（≤一帧对齐）")
    // 屏2 刷新后重新就绪，PTS 取新一批最小值
    g.note(2, pts: t(180))
    check(g.isReady && g.mergedPTS == t(180), "两屏刷至 180 后就绪且 PTS=180")
    // reset 清空
    g.reset()
    check(!g.isReady, "reset 后不就绪")
}

// MARK: - 设置/类型用例

func settingsTests() {
    let defaults = UserDefaults(suiteName: "dktests.\(UUID().uuidString)")!
    let store = SettingsStore(defaults: defaults)
    bridgeSync {
        await store.mutate { s in
            s.recording.codec = .h264
            s.recording.overlayClickEffects = false
            s.outputDirectoryPath = "/tmp/disynk-test-out"
        }
        // 新实例从同 suite 重载 → 持久化 round-trip
        let reloaded = SettingsStore(defaults: defaults)
        let s = await reloaded.current()
        check(s.recording.codec == .h264 && !s.recording.overlayClickEffects &&
              s.outputDirectoryPath == "/tmp/disynk-test-out", "SettingsStore 持久化 round-trip")
        let per = s.effective(for: 99)
        var snap = s
        snap.perDisplay[99] = DisplayOverride(frameRate: .p30)
        let scoped = SettingsStore(defaults: defaults)
        await scoped.mutate { $0.perDisplay[99] = DisplayOverride(frameRate: .p30) }
        let eff = (await scoped.current()).effective(for: 99)
        check(eff.frameRate == .p30 && per.frameRate != .p30, "每屏覆盖生效")
    }
    let fit = ResolutionMode.preset(PixelSize(width: 1920, height: 1080))
        .resolve(source: PixelSize(width: 2560, height: 1600))
    check(fit.height == 1080 && fit.width == 1728 && fit.evenAligned, "16:10→16:9 保长宽比取框")
    check(FrameRate(fps: 999).fps == 240 && FrameRate(fps: 0.1).fps == 1, "帧率钳制 1~240")
}

// MARK: - 磁盘写入速度探测（方案第四节：高码率多路写机械盘启动前告警）

func diskProbeTest() {
    let dir = FileManager.default.temporaryDirectory
    let mbps = DiskProbe.measureWriteSpeedMBs(in: dir, totalBytes: 8 * 1024 * 1024, chunkBytes: 1024 * 1024)
    check((mbps ?? 0) > 0, "磁盘实测速度 > 0（\(String(format: "%.0f", mbps ?? -1)) MB/s）")

    // 多路 4K60 高码率（400MB/s = 3.2e9 bps）+ 实测慢盘 60MB/s → 应告警
    let warn = DiskProbe.warningIfNeeded(aggregateBitrateBps: 3_200_000_000, measuredMBs: 60)
    if case .diskTooSlow(let v)? = warn { check(v == 60, "高码率+慢盘→磁盘偏慢告警（\(v)MB/s）") }
    else { check(false, "高码率+慢盘→磁盘偏慢告警") }

    // 低码率（8Mbps=1MB/s）+ 快盘 500MB/s → 无告警
    check(DiskProbe.warningIfNeeded(aggregateBitrateBps: 8_000_000, measuredMBs: 500) == nil,
          "低码率+快盘→不告警")
    // 测不到（<=0）时不误告警
    check(DiskProbe.warningIfNeeded(aggregateBitrateBps: 3_200_000_000, measuredMBs: 0) == nil,
          "探测失败时不误告警")
}

// MARK: - DKShot 像素倍率纯函数 + PNG 落盘 round-trip（方案：截图存储路径 / Retina 倍率）

func shotScaleSaveTest() throws {
    check(Screenshotter.pixelScale(pixelWidth: 2880, pointWidth: 1440) == 2, "Retina 屏倍率 2x")
    check(Screenshotter.pixelScale(pixelWidth: 1920, pointWidth: 1920) == 1, "普通屏倍率 1x")
    check(Screenshotter.pixelScale(pixelWidth: 3440, pointWidth: 1720) == 2, "5K 宽四舍五入到 .5（=2x）")
    check(Screenshotter.pixelScale(pixelWidth: 0, pointWidth: 100) == 1, "像素宽为 0 回退 1x")
    check(Screenshotter.pixelScale(pixelWidth: 100, pointWidth: 0) == 1, "点宽为 0 回退 1x")

    // 造一张 8x8 红色 CGImage 落盘，并验证可被 ImageIO 重新解码（尺寸一致）
    let cs = CGColorSpaceCreateDeviceRGB()
    var data = [UInt8](repeating: 0, count: 8 * 8 * 4)
    for i in 0..<64 { data[i * 4] = 255; data[i * 4 + 3] = 255 }
    guard let ctx = CGContext(data: &data, width: 8, height: 8, bitsPerComponent: 8,
                              bytesPerRow: 8 * 4, space: cs,
                              bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue),
          let img = ctx.makeImage() else {
        check(false, "构造测试 CGImage"); return
    }
    let dir = FileManager.default.temporaryDirectory.appendingPathComponent("disynk-shot-\(UUID().uuidString)")
    let url = try Screenshotter.savePNG(img, to: dir, namePrefix: "test")
    let attrs = try FileManager.default.attributesOfItem(atPath: url.path)
    check(((attrs[.size] as? NSNumber)?.int64Value ?? 0) > 100, "PNG 落盘非空")
    check(url.pathExtension == "png", "保存文件扩展名为 png")
    let src = CGImageSourceCreateWithURL(url as CFURL, nil)
    let decoded = src.flatMap { CGImageSourceCreateImageAtIndex($0, 0, nil) }
    check(decoded != nil && decoded!.width == 8 && decoded!.height == 8, "PNG 可被 ImageIO 解码且尺寸一致")
    try? FileManager.default.removeItem(at: dir)
}

// MARK: - DKCore 像素几何纯函数（偶数对齐 / 选区尺寸）

func pixelMathTest() {
    check(PixelMath.evenSize(1025, 769) == PixelSize(width: 1024, height: 768), "奇数尺寸向下取偶")
    check(PixelMath.evenSize(1, 1) == PixelSize(width: 2, height: 2), "极小值抬到下限 2")
    check(PixelMath.evenSize(20000, 20000) == PixelSize(width: 8192, height: 8192), "超大钳到 8192")
    let r = CGRect(x: 0, y: 0, width: 100.4, height: 50.6)
    check(PixelMath.regionPixels(rect: r, scale: 2) == PixelSize(width: 200, height: 100), "选区×2 取偶（200x100）")
    check(PixelMath.regionPixels(rect: r, scale: 0) == PixelSize(width: 100, height: 50), "倍率为 0 回退 1x")
    check(PixelMath.regionPixels(rect: r, scale: .nan) == PixelSize(width: 100, height: 50), "倍率 NaN 回退 1x")
}

// MARK: - DKShot 滚动长截图拼接（方案：滚动截图；纯算法 + CGContext 合成分层验证）

/// 造一张每行纯色的 CGImage（data 首行=视觉顶行）：视觉行 y 填充全局行号 (start+y) 的唯一颜色。
/// 全局行号 → 颜色，保证跨帧同一全局行的像素完全一致（滚动重叠判定的关键）。
func makeRowImage(width: Int, start: Int, rows: Int) -> CGImage? {
    guard width > 0, rows > 0 else { return nil }
    var buf = [UInt8](repeating: 0, count: width * rows * 4)
    for y in 0..<rows {
        let g = start + y
        // 由全局行号派生稳定、互不相同的 RGB（每行等色，列无关）
        let r = UInt8(g % 251)
        let gr = UInt8((g * 7 + 13) % 251)
        let b = UInt8((g * 43 + 97) % 251)
        for x in 0..<width {
            let o = (y * width + x) * 4
            buf[o] = r; buf[o + 1] = gr; buf[o + 2] = b; buf[o + 3] = 255
        }
    }
    let cs = CGColorSpaceCreateDeviceRGB()
    guard let provider = CGDataProvider(data: Data(buf) as CFData) else { return nil }
    return CGImage(width: width, height: rows, bitsPerComponent: 8, bitsPerPixel: 32,
                   bytesPerRow: width * 4, space: cs,
                   bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue),
                   provider: provider, decode: nil, shouldInterpolate: false, intent: .defaultIntent)
}

func scrollStitchTest() {
    // 1) 重叠检测纯逻辑：前帧末尾 == 后帧开头 的最大行数
    check(ScrollStitch.overlap(prev: [1, 2, 3, 4, 5, 6], next: [4, 5, 6, 7, 8, 9], minRows: 1) == 3,
          "overlap：末尾 3 行与开头 3 行相同→3")
    check(ScrollStitch.overlap(prev: [1, 2, 3], next: [4, 5, 6], minRows: 1) == 0,
          "overlap：完全不相交→0")
    check(ScrollStitch.overlap(prev: [1, 2, 3, 4], next: [1, 2, 3, 4], minRows: 1) == 4,
          "overlap：两帧全同→整段重叠 4")
    check(ScrollStitch.overlap(prev: [1, 2, 3, 4, 5, 6], next: [4, 5, 6, 7], minRows: 4) == 0,
          "overlap：真实重叠 3 低于 minRows 4→视为无重叠")
    check(ScrollStitch.overlap(prev: [], next: [1, 2], minRows: 1) == 0, "overlap：空前帧→0")

    // 2) 顶部偏移堆叠：offsets[i] = 已堆叠高 − 与前一帧重叠
    let offs = ScrollStitch.topOffsets(heights: [100, 100, 100], overlaps: [20, 30])
    check(offs == [0, 80, 150], "topOffsets：[100×3] 重叠[20,30]→[0,80,150] 实得\(offs)")
    check(ScrollStitch.topOffsets(heights: [100], overlaps: []) == [0], "topOffsets：单帧→[0]")
    check(ScrollStitch.topOffsets(heights: [], overlaps: []).isEmpty, "topOffsets：空→空")

    // 3) stitch 端到端：A=全局行 0..39、B=全局行 30..69（视觉重叠 10 行）→ 重建高 70
    let W = 16
    guard let a = makeRowImage(width: W, start: 0, rows: 40),
          let b = makeRowImage(width: W, start: 30, rows: 40) else {
        check(false, "stitch：构造行图失败"); return
    }
    if let out = ScrollStitch.stitch([a, b], minRows: 6) {
        check(out.width == W && out.height == 70,
              "stitch：两帧(40+40)重叠10→70 高 实得\(out.width)x\(out.height)")
    } else { check(false, "stitch：两帧合成输出 nil") }

    // 4) 单帧原样返回、空输入返回 nil
    if let single = ScrollStitch.stitch([a]) { check(single.height == 40, "stitch：单帧原样返回") }
    else { check(false, "stitch：单帧原样返回") }
    check(ScrollStitch.stitch([]) == nil, "stitch：空输入→nil")

    // 5) 固定 UI 带（窗口标题栏 / 浏览器地址栏）：各帧首尾完全一致的行应被识别并裁掉，
    //    否则整图里会一遍遍重复出现工具栏。
    let chromeA = makeScrollFrame(width: 16, chromeTop: 6, bodyRows: 30, bodyStart: 0, chromeBottom: 4)
    let chromeB = makeScrollFrame(width: 16, chromeTop: 6, bodyRows: 30, bodyStart: 22, chromeBottom: 4)
    if let ca = chromeA, let cb = chromeB {
        let da = ScrollStitch.analyze(of: ca), db = ScrollStitch.analyze(of: cb)
        let bands = ScrollStitch.staticBands([da, db])
        check(bands.top == 6 && bands.bottom == 4,
              "staticBands：识别出顶部 6 行 / 底部 4 行固定 UI（实得 \(bands.top)/\(bands.bottom)）")
        if let rep = ScrollStitch.stitchDetailed([ca, cb], minRows: 6) {
            check(rep.trimmedTop == 6 && rep.trimmedBottom == 4 && rep.zeroOverlapPairs == 0
                    && rep.image.height == 52,
                  "stitchDetailed：裁掉固定 UI 后按正文重叠 8 行堆叠→30+22=52 高（实得 \(rep.image.height)）")
        } else { check(false, "stitchDetailed：固定 UI 两帧合成输出 nil") }
    } else { check(false, "staticBands：构造固定 UI 帧失败") }

    // 6) 容差重叠：滚动后应用重新栅格化，同一行像素只差几阶灰度 → 行哈希不再相等，
    //    精确匹配返回 0（旧行为：重叠完全没去掉），行剖面容差匹配仍能检出真实重叠。
    let nA = makeScrollFrame(width: 16, chromeTop: 0, bodyRows: 40, bodyStart: 0, chromeBottom: 0,
                             jitter: 2, salt: 0)
    let nB = makeScrollFrame(width: 16, chromeTop: 0, bodyRows: 40, bodyStart: 30, chromeBottom: 0,
                             jitter: 2, salt: 1)
    if let xa = nA, let xb = nB {
        let da = ScrollStitch.analyze(of: xa), db = ScrollStitch.analyze(of: xb)
        check(ScrollStitch.overlap(prev: da.sigs, next: db.sigs, minRows: 3) == 0,
              "容差：行哈希拖动后精确重叠→0（回归护栏）")
        check(ScrollStitch.tolerantOverlap(prev: da, next: db, minRows: 3) == 10,
              "容差：同一片重叠仍检出 10 行")
        if let rep = ScrollStitch.stitchDetailed([xa, xb], minRows: 3) {
            check(rep.image.height == 70 && rep.zeroOverlapPairs == 0,
                  "stitchDetailed：容差重叠生效→40+30=70 高（实得 \(rep.image.height)）")
        } else { check(false, "stitchDetailed：容差两帧合成输出 nil") }
    } else { check(false, "容差重叠：构造拖动帧失败") }

    // 7) 固定栏里的“闪烁行”（地址栏光标 / 动图 favicon）：旧版一行不同就截断识别，
    //    导致工具栏只裁掉上半截 → 剩下半截逐屏重复。现在允许带内极少量闪烁行。
    let flickA = makeScrollFrame(width: 16, chromeTop: 6, bodyRows: 30, bodyStart: 0,
                                 chromeBottom: 4, caret: 3)
    let flickB = makeScrollFrame(width: 16, chromeTop: 6, bodyRows: 30, bodyStart: 22, chromeBottom: 4)
    if let fa = flickA, let fb = flickB {
        let bands = ScrollStitch.staticBands([ScrollStitch.analyze(of: fa),
                                              ScrollStitch.analyze(of: fb)])
        check(bands.top == 6 && bands.bottom == 4,
              "staticBands：固定栏内有 1 行闪烁仍整条识别为固定 UI（实得 \(bands.top)/\(bands.bottom)）")
        if let rep = ScrollStitch.stitchDetailed([fa, fb], minRows: 6) {
            check(rep.image.height == 52 && rep.zeroOverlapPairs == 0,
                  "stitchDetailed：闪烁行不影响去重堆叠→ 52 高（实得 \(rep.image.height)）")
        } else { check(false, "stitchDetailed：闪烁行两帧合成输出 nil") }
    } else { check(false, "staticBands：构造闪烁帧失败") }

    // 8) 逐对固定带 + 内容区位移搜索：只要两帧同址相等就是没滚动的部分，
    //    2 帧会话也能用；位移 Δ 直接就是本帧新增行数（不再依赖“后缀=前缀”）。
    if let ca = chromeA, let cb = chromeB {
        let da = ScrollStitch.analyze(of: ca), db = ScrollStitch.analyze(of: cb)
        let pb = ScrollStitch.pairStaticBands(prev: da, next: db)
        check(pb.top == 6 && pb.bottom == 4,
              "pairStaticBands：两帧同址静止带 6/4（实得 \(pb.top)/\(pb.bottom)）")
        let d = ScrollStitch.bestShift(prev: da, next: db, skip: pb, minAligned: 4)
        check(d == 22, "bestShift：内容区里求出真实滚动步长 Δ=22（实得 \(String(describing: d))）")
    } else { check(false, "pairStaticBands：构造帧失败") }

    // 8b) 内容区中部的 sticky 固定条（如电商筛选栏）：同址静止行在任何 Δ 下都“命中”，
    //     会稀释真实 Δ 命中率致漏判（→整屏重复）。现在计分前剔除这类行，仍能求出真实步长。
    if let sa16 = makeScrollFrame(width: 16, chromeTop: 0, bodyRows: 40, bodyStart: 0,
                                  chromeBottom: 0, sticky: 10...13),
       let sb16 = makeScrollFrame(width: 16, chromeTop: 0, bodyRows: 40, bodyStart: 26,
                                  chromeBottom: 0, sticky: 10...13) {
        let da = ScrollStitch.analyze(of: sa16), db = ScrollStitch.analyze(of: sb16)
        let d = ScrollStitch.bestShift(prev: da, next: db, skip: (0, 0), minAligned: 4)
        check(d == 26, "bestShift：中部 sticky 静止行不参与计分，仍求出 Δ=26（实得 \(String(describing: d))）")
    } else { check(false, "bestShift sticky：构造帧失败") }

    // 9) 不勾选「包含标题栏」时拼接管线裁左右固定栏（修复浏览器竖排标签栏残留）：
    //    严格版判定 = 逐帧列哈希全同（原生固定栏不参与重栅格化、逐帧像素级一致）。
    if let sa = makeSideFrame(width: 40, height: 40, sideW: 8, bodyStart: 0),
       let sb = makeSideFrame(width: 40, height: 40, sideW: 8, bodyStart: 13) {
        let (cl, cr) = ScrollStitch.staticColumns([sa, sb])
        check(cl == 8 && cr == 8, "staticColumns：识别左右各 8 列逐帧全同固定栏（实得 \(cl)/\(cr)）")
        if let rep = ScrollStitch.stitchDetailed([sa, sb], options: .init(includeTitlebar: false), minRows: 4) {
            check(rep.trimmedLeft == 8 && rep.trimmedRight == 8 && rep.image.width == 24,
                  "stitchDetailed(不含标题栏)：裁掉左右固定栏 8/8 → 宽 24（实得 \(rep.trimmedLeft)/\(rep.trimmedRight)/\(rep.image.width)）")
        } else { check(false, "stitchDetailed(不含标题栏)：两帧合成输出 nil") }
    } else { check(false, "staticColumns：构造侧栏帧失败") }

    // 9c) 随页滚动的正文列（列哈希逐帧变）不会被当固定栏裁掉（v0.1.50 tol 误判的回归护栏）。
    if let ca = chromeA, let cb = chromeB {
        let (sl, sr) = ScrollStitch.staticColumns([ca, cb])
        check(sl == 0 && sr == 0, "staticColumns：整幅滚动正文无固定列可裁（实得 \(sl)/\(sr)）")
        if let rep = ScrollStitch.stitchDetailed([ca, cb], options: .init(includeTitlebar: false), minRows: 6) {
            check(rep.trimmedLeft == 0 && rep.trimmedRight == 0,
                  "stitchDetailed(不含标题栏)：滚动正文不裁左右（实得 \(rep.trimmedLeft)/\(rep.trimmedRight)）")
        } else { check(false, "stitchDetailed(不含标题栏)：固定 UI 两帧合成输出 nil") }
    } else { check(false, "staticColumns：构造滚动帧失败") }

    // 9b) 页面空白边距（平坦列）不应被当作固定侧栏裁掉（修复“左侧裁太多、连空白也裁”）。
    if let ba = makeSideFrame(width: 40, height: 40, sideW: 8, bodyStart: 0, flat: true),
       let bb = makeSideFrame(width: 40, height: 40, sideW: 8, bodyStart: 13, flat: true) {
        let (fl, fr) = ScrollStitch.staticColumns([ba, bb])
        check(fl == 0 && fr == 0, "staticColumns：纯白留白边距（平坦列）不被裁（实得 \(fl)/\(fr)）")
    } else { check(false, "staticColumns：构造留白帧失败") }

    // 9d) 重叠完全漏判的帧对（典型：懒加载图瞬间刷新使重叠区面目全非）：
    //     用其余帧滚动步长 Δ 的中位数兜底估算重叠，不再整屏重复堆进长图。
    if let fa = makeScrollFrame(width: 16, chromeTop: 0, bodyRows: 40, bodyStart: 0, chromeBottom: 0),
       let fb = makeScrollFrame(width: 16, chromeTop: 0, bodyRows: 40, bodyStart: 20, chromeBottom: 0),
       let fc = makeScrollFrame(width: 16, chromeTop: 0, bodyRows: 40, bodyStart: 40, chromeBottom: 0),
       let fd = makeScrollFrame(width: 16, chromeTop: 0, bodyRows: 40, bodyStart: 60, chromeBottom: 0,
                                corrupt: 0...19) {
        if let rep = ScrollStitch.stitchDetailed([fa, fb, fc, fd], minRows: 4) {
            check(rep.stepRescuedPairs == 1 && rep.zeroOverlapPairs == 0 && rep.image.height == 100,
                  "stitchDetailed：漏判对按步长中位数兜底→ 40+20×3=100 高（实得 \(rep.stepRescuedPairs)/\(rep.zeroOverlapPairs)/\(rep.image.height)）")
        } else { check(false, "stitchDetailed：步长兜底四帧合成输出 nil") }
    } else { check(false, "stitchDetailed：构造步长兜底帧失败") }

    // 10) BrowserViewport.cropRect：由 AXWebArea 视口全局矩形 + 窗口全局矩形换算整窗截图（像素）裁剪矩形。
    //     窗口全局 (100,80) 起、1000×800 点；Retina 整窗截图 2000×1600 像素（倍率 2）。
    //     视口去掉顶部标签栏/地址栏(高 120 点)与左侧深色侧栏(宽 60 点)：原点 (160,200)、尺寸 940×680 点。
    do {
        let win = CGRect(x: 100, y: 80, width: 1000, height: 800)
        let web = CGRect(x: 160, y: 200, width: 940, height: 680)
        let expect = CGRect(x: 120, y: 240, width: 1880, height: 1360)   // ((160-100)*2,(200-80)*2,940*2,680*2)
        let got = BrowserViewport.cropRect(webArea: web, windowBounds: win, imageWidth: 2000, imageHeight: 1600)
        check(got == expect, "cropRect：视口偏移×倍率换算像素裁剪矩形（期望 \(expect)，实得 \(String(describing: got))）")
        // 视口右下角超出图像 → 钳制到图像边界（不裁出界）。
        let over = CGRect(x: 900, y: 700, width: 400, height: 400)
        let clamped = BrowserViewport.cropRect(webArea: over, windowBounds: win, imageWidth: 2000, imageHeight: 1600)
        check(clamped.map { $0.maxX <= 2000 && $0.maxY <= 1600 && $0.minX >= 0 && $0.minY >= 0 } == true,
              "cropRect：视口越界时钳制到图像范围内（实得 \(String(describing: clamped))）")
        // 退化视口（宽或高 < 8 像素）→ nil。
        check(BrowserViewport.cropRect(webArea: CGRect(x: 160, y: 200, width: 2, height: 680),
                                       windowBounds: win, imageWidth: 2000, imageHeight: 1600) == nil,
              "cropRect：退化视口（宽≈0）返回 nil 以触发整窗回退")
    }
}

/// 行色哈希派生（相邻全局行差异大，便于区分「真重叠」与「碰巧相邻」）。
func hashRowByte(_ g: Int, _ k: Int) -> Int {
    var x = UInt64(bitPattern: Int64(g &+ 1)) &* 0x9E37_79B9_7F4A_7C15
    x ^= UInt64(k &+ 11) &* 0xBF58_476D_1CE4_E5B9
    x = (x ^ (x >> 29)) &* 0x94D0_49BB_1331_11EB
    x = x ^ (x >> 32)
    return Int(x % 256)
}

/// 造一帧「固定 UI + 滚动正文」测试图：顶部 chromeTop 行与底部 chromeBottom 行为不随滚动
/// 变化的工具栏色，中间正文行色由 bodyStart 起的全局行号派生。
/// jitter>0 且 salt 不同时，同一全局行会有小幅确定性偏移，模拟重新栅格化。
/// sticky：指定绝对行号段染固定灰（与 bodyStart 无关）→ 模拟页面中部不滚动的 sticky 条。
/// corrupt：指定绝对行号段染与 bodyStart 无关的哈希色 → 模拟懒加载图瞬间刷新使重叠区面目全非。
func makeScrollFrame(width: Int, chromeTop: Int, bodyRows: Int, bodyStart: Int,
                     chromeBottom: Int, jitter: Int = 0, salt: Int = 0,
                     caret: Int = -1, sticky: ClosedRange<Int>? = nil,
                     corrupt: ClosedRange<Int>? = nil) -> CGImage? {
    let rows = chromeTop + bodyRows + chromeBottom
    guard width > 0, rows > 0 else { return nil }
    var buf = [UInt8](repeating: 0, count: width * rows * 4)
    for y in 0..<rows {
        var r = 0, gr = 0, b = 0
        if y < chromeTop {
            (r, gr, b) = (250, 12, 12)                       // 顶部固定工具栏
        } else if y >= rows - chromeBottom {
            (r, gr, b) = (12, 12, 250)                       // 底部固定栏
        } else if let s = sticky, s.contains(y) {
            (r, gr, b) = (77, 77, 77)                        // 中部 sticky 静止条（不随滚动变）
        } else if let cp = corrupt, cp.contains(y) {
            r = hashRowByte(y &+ 9973, 0); gr = hashRowByte(y &+ 9973, 1); b = hashRowByte(y &+ 9973, 2)
        } else {
            let g = bodyStart + (y - chromeTop)
            let d = jitter == 0 ? 0 : ((g * 7 + salt * 31) % (2 * jitter + 1)) - jitter
            r = hashRowByte(g, 0) + d
            gr = hashRowByte(g, 1) + d
            b = hashRowByte(g, 2) + d
        }
        let clamped = (UInt8(max(0, min(255, r + (y == caret ? 90 : 0)))),
                       UInt8(max(0, min(255, gr + (y == caret ? 90 : 0)))),
                       UInt8(max(0, min(255, b + (y == caret ? 90 : 0)))))
        for x in 0..<width {
            let o = (y * width + x) * 4
            buf[o] = clamped.0; buf[o + 1] = clamped.1; buf[o + 2] = clamped.2; buf[o + 3] = 255
        }
    }
    let cs = CGColorSpaceCreateDeviceRGB()
    guard let provider = CGDataProvider(data: Data(buf) as CFData) else { return nil }
    return CGImage(width: width, height: rows, bitsPerComponent: 8, bitsPerPixel: 32,
                   bytesPerRow: width * 4, space: cs,
                   bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue),
                   provider: provider, decode: nil, shouldInterpolate: false, intent: .defaultIntent)
}

/// 造一帧带「左右固定侧栏 + 中间滚动正文」的测试图：两侧 sideW 列不随 bodyStart 变（静止）。
/// flat=false 时侧栏列纵向有结构（模拟图标/文字/分隔线，非平坦）；flat=true 时为纯白留白（平坦）。
/// 中间列按全局行号派生 → bodyStart 不同时中间列变化。供 staticColumns 区分固定侧栏 vs 页面留白。
func makeSideFrame(width: Int, height: Int, sideW: Int, bodyStart: Int, flat: Bool = false) -> CGImage? {
    guard width > 2 * sideW + 8, height > 0 else { return nil }
    var buf = [UInt8](repeating: 0, count: width * height * 4)
    for y in 0..<height {
        for x in 0..<width {
            var r = 0, g = 0, b = 0
            if x < sideW || x >= width - sideW {
                if flat {
                    (r, g, b) = (255, 255, 255)                            // 平坦空白边距
                } else {
                    let v = (y % 6 < 3) ? 40 : 200                         // 纵向有结构且不随滚动变
                    (r, g, b) = (v, v, v)
                }
            } else {
                let row = bodyStart + y
                r = hashRowByte(row, 0); g = hashRowByte(row, 1); b = hashRowByte(row, 2)
            }
            let o = (y * width + x) * 4
            buf[o] = UInt8(r); buf[o + 1] = UInt8(g); buf[o + 2] = UInt8(b); buf[o + 3] = 255
        }
    }
    let cs = CGColorSpaceCreateDeviceRGB()
    guard let provider = CGDataProvider(data: Data(buf) as CFData) else { return nil }
    return CGImage(width: width, height: height, bitsPerComponent: 8, bitsPerPixel: 32,
                   bytesPerRow: width * 4, space: cs,
                   bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue),
                   provider: provider, decode: nil, shouldInterpolate: false, intent: .defaultIntent)
}

// MARK: - 虚拟屏集成冒烟（方案第五节 M5 / 第七节：DKVirtualDisplay 因依赖真机 GUI 仅提供集成冒烟测试）

/// 默认仅执行非侵入的运行时能力探测（校验 DVKObjC 桥接与私有类解析是否就位）；
/// 真正的创建/删除会改动本机在线显示器列表，故仅在显式 `DISYNK_RUN_GUI_SMOKE=1` 时执行，
/// 避免在日常回归里意外干扰用户当前显示会话。
func virtualDisplaySmokeTest() {
    // VirtualDisplayManager 现为 @MainActor（CGVirtualDisplay 必须主线程创建/销毁），
    // 故能力探测与创建/销毁均需经 MainActor.run 回主隔离域调用（这些方法已同步）。
    var supported = false
    bridgeSync { supported = await MainActor.run { VirtualDisplayManager.isSupported() } }
    check(true, "虚拟屏能力探测未崩溃（CGVirtualDisplay 私有类可用=\(supported)）")

    guard ProcessInfo.processInfo.environment["DISYNK_RUN_GUI_SMOKE"] == "1" else {
        print("  ○ 跳过虚拟屏创建/删除（设 DISYNK_RUN_GUI_SMOKE=1 且处于 GUI 会话时执行真机集成冒烟）")
        return
    }
    guard supported else {
        check(false, "GUI 冒烟已开启但系统未暴露 CGVirtualDisplay 私有类")
        return
    }
    bridgeSync {
        await MainActor.run {
            let mgr = VirtualDisplayManager()
            do {
                let screen = try mgr.create(preset: .fullHD)
                check(screen.displayID != 0, "虚拟屏创建返回非零 displayID（#\(screen.displayID)）")
                check(screen.width == 1920 && screen.height == 1080, "虚拟屏尺寸为 1920x1080")
                check(screen.hiDPI == false, "fullHD 预设默认非 HiDPI")
                let listing = mgr.list()
                check(listing.contains { $0.displayID == screen.displayID }, "虚拟屏已登记在管理列表")
                try mgr.destroy(displayID: screen.displayID)
                // 自定义分辨率 + HiDPI（方案第三节）：校验标志位透传
                let hi = try mgr.create(width: 2560, height: 1440, hiDPI: true)
                check(hi.hiDPI == true && hi.width == 2560 && hi.height == 1440,
                      "自定义 2560x1440 + HiDPI 标志位透传")
                try mgr.destroy(displayID: hi.displayID)
                let after = mgr.list()
                check(!after.contains { $0.displayID == screen.displayID }, "销毁后从管理列表移除")
                // 注：是否真正“上线”可被 SCK 录制需进程具备活跃 GUI/WindowServer 会话（启动的 .app）；
                //     纯 CLI 测试环境常只分配到 displayID 而不 online，属方案第七节已声明的真机 GUI 依赖。
            } catch {
                check(false, "虚拟屏集成冒烟异常：\(error.localizedDescription)")
            }
        }
    }
}

/// DKOverlay 按键横幅组合解析（方案 M4/§七：修饰键顺序 + 特殊键映射 + 普通字符回退）
func overlayComboTest() {
    // 修饰键固定按 ⌘⌃⌥⇧ 顺序拼接（Apple HIG）
    let all: CGEventFlags = [.maskCommand, .maskControl, .maskAlternate, .maskShift]
    check(OverlayController.comboString(flags: all, code: 19, charFallback: "c") == "⌘⌃⌥⇧C",
          "四修饰键按 ⌘⌃⌥⇧ 顺序拼接且普通字符大写")
    // 仅 ⌘⇧ + 数字 2（键码 19 的 unicode 回退为 '2'）
    check(OverlayController.comboString(flags: [.maskCommand, .maskShift], code: 19, charFallback: "2") == "⌘⇧2",
          "⌘⇧ + 字符 → '⌘⇧2'（截图快捷键典型组合）")
    // 无修饰键的普通字符
    check(OverlayController.comboString(flags: [], code: 0, charFallback: "a") == "A",
          "无修饰键普通字符大写输出")
    // 特殊键映射：Esc(53)/F1(122)/回车(36)/左箭头(123)/空格(49)
    check(OverlayController.mappedKeyName(code: 53) == "⎋", "Esc 键映射为 ⎋")
    check(OverlayController.mappedKeyName(code: 122) == "F1", "F1 键码映射正确")
    check(OverlayController.mappedKeyName(code: 36) == "↩", "回车映射为 ↩")
    check(OverlayController.mappedKeyName(code: 123) == "←", "左箭头映射为 ←")
    check(OverlayController.mappedKeyName(code: 49) == "␣", "空格映射为 ␣")
    // 特殊键优先于 unicode 回退（键码 53 即便带修饰也不走 fallback）
    check(OverlayController.comboString(flags: .maskCommand, code: 53, charFallback: nil) == "⌘⎋",
          "特殊键走映射表而非字符回退")
    // 未知键码且无回退字符 → 占位 '?'
    check(OverlayController.comboString(flags: [], code: 999, charFallback: nil) == "?",
          "未知键码无回退时输出占位 ?")
}

/// DKCapture 帧率钳制纯逻辑（方案第四节：SCK 输出帧率不超过源屏刷新率）
func captureClampTest() {
    // 请求高于刷新率→降至 刷新率-0.5
    check(DisplayCapture.clampedFPS(requested: 60, refreshHz: 30) == 29.5,
          "请求 60fps 但屏刷新 30Hz→钳制 29.5")
    // 请求低于上限→保留用户值
    check(DisplayCapture.clampedFPS(requested: 30, refreshHz: 60) == 30,
          "请求 30fps 且屏刷新 60Hz→保留 30")
    // 高刷新屏（120Hz）取用户 60
    check(DisplayCapture.clampedFPS(requested: 60, refreshHz: 120) == 60,
          "120Hz 屏上 60fps 不受限")
    // 刷新率探测失败（0Hz）兜底不低于 1fps
    check(DisplayCapture.clampedFPS(requested: 30, refreshHz: 0) == 1,
          "刷新率未知(0Hz)→兜底 1fps不归零")
    check(DisplayCapture.clampedFPS(requested: 0.5, refreshHz: 0) == 0.5,
          "极端低请求值与1fps 取小仍不为负")
}

// 覆盖层「入画/不入画」排除决策纯函数（§三独立开关 + §七覆盖层关闭时不入画）。
func overlayExclusionTest() {
    // 录入画面 → 不排除任何窗口（面板可见于录制）
    check(DisplayCapture.overlayExcludedWindowIDs(included: true, panelWindowID: 42).isEmpty,
          "入画模式不排除窗口")
    // 不入画且面板已创建 → 排除该面板窗口
    check(DisplayCapture.overlayExcludedWindowIDs(included: false, panelWindowID: 42) == [42],
          "不入画模式排除面板窗口 42")
    // 不入画但面板尚未创建（windowNumber 无效）→ 无可排除，不产生 bogus ID
    check(DisplayCapture.overlayExcludedWindowIDs(included: false, panelWindowID: 0).isEmpty,
          "不入画但无面板窗口→空集")
    check(DisplayCapture.overlayExcludedWindowIDs(included: false, panelWindowID: -1).isEmpty,
          "负窗口 ID 视为无效→空集")
}

/// DKShot 识别文本导出（方案第三节：截图即 OCR → 导出 TXT/MD；纯文件逻辑，无需真机）
func shotExportTest() throws {
    let r = Screenshotter.OCRResult(lines: ["第一行", "second line", "第三行"], confidenceAvg: 0.92)
    // text 计算属性：行以 \n 连接
    check(r.text == "第一行\nsecond line\n第三行", "OCRResult.text 以换行拼接各行的")

    let dir = NSTemporaryDirectory()
    // TXT 导出：内容 == text
    let txt = URL(fileURLWithPath: dir).appendingPathComponent("dkshot-\(UUID().uuidString).txt")
    try Screenshotter.writeText(r, to: txt, markdown: false)
    let txtBody = try String(contentsOf: txt, encoding: .utf8)
    check(txtBody == r.text, "writeText(markdown:false) 产出逐行 TXT")

    // Markdown 导出：含 # 标题且以空行分段
    let md = URL(fileURLWithPath: dir).appendingPathComponent("dkshot-\(UUID().uuidString).md")
    try Screenshotter.writeText(r, to: md, markdown: true)
    let mdBody = try String(contentsOf: md, encoding: .utf8)
    check(mdBody.hasPrefix("# 识别文本"), "writeText(markdown:true) 以 Markdown 标题开头")
    check(mdBody.contains("第一行\n\nsecond line"), "Markdown 导出行间以空行分段")

    try? FileManager.default.removeItem(at: txt)
    try? FileManager.default.removeItem(at: md)
}

/// 编码会话容量估算（方案第四节：3~5 路硬编上限 / ProRes 软编多路）
func encodeCapacityTest() {
    // separateFiles：N 屏=N 会话
    check(EncodeCapacity.sessionCount(displayCount: 3, mode: .separateFiles) == 3, "独立模式 3 屏=3 会话")
    // composedOnly：≥2 屏合为 1 会话
    check(EncodeCapacity.sessionCount(displayCount: 3, mode: .composedOnly) == 1, "合并模式 3 屏=1 会话")
    check(EncodeCapacity.sessionCount(displayCount: 1, mode: .composedOnly) == 0, "合并模式 1 屏=0（无合成意义）")
    // both：N 独立 + 1 合成
    check(EncodeCapacity.sessionCount(displayCount: 2, mode: .both) == 3, "两者模式 2 屏=2+1=3 会话")
    // 0 屏→无会话
    check(EncodeCapacity.sessionCount(displayCount: 0, mode: .both) == 0, "0 屏→无会话")

    // 硬编且会话≤上限→info
    check(EncodeCapacity.advise(displayCount: 3, mode: .separateFiles, codec: .hevc) == .info,
          "3 路 HEVC 硬编→info")
    // 会话数超上限→overHardwareLimit（both 5 屏=6 会话>4）
    check(EncodeCapacity.advise(displayCount: 5, mode: .both, codec: .h264) == .overHardwareLimit,
          "5 路 H.264 两者模式=6 会话>上限→降级告警")
    // ProRes 多路→软编告警（优先级高于上限）
    check(EncodeCapacity.advise(displayCount: 2, mode: .separateFiles, codec: .proRes422) == .softwareMultiSession,
          "2 路 ProRes→软编多路告警")
    // ProRes 单路→不告警（sessions=1）
    check(EncodeCapacity.advise(displayCount: 1, mode: .separateFiles, codec: .proRes422) == .info,
          "单路 ProRes→info（不抹软编多路）")
}

/// 引导重新授权命令（方案 M7 路径 A：cdhash 变更 → tccutil 重置提示 + 隐私面板）
func permissionsReauthTest() {
    // 服务 token 映射与 Apple 规范一致
    check(ScreenPermissions.tccutilService(for: .screenRecording) == "ScreenCapture",
          "tccutil 服务名 ScreenCapture")
    check(ScreenPermissions.tccutilService(for: .microphone) == "Microphone",
          "tccutil 服务名 Microphone")
    check(ScreenPermissions.tccutilService(for: .accessibility) == "Accessibility",
          "tccutil 服务名 Accessibility")
    // 含 bundleID → 命令携带包标识
    let h = ScreenPermissions.reauthorizationHint(bundleID: "com.disynk.app", pane: .screenRecording)
    check(h.command == "tccutil reset ScreenCapture com.disynk.app",
          "重授权命令含 bundleID（\(h.command)）")
    check(h.serviceToken == "ScreenCapture" && h.pane == .screenRecording,
          "ReauthHint 携带 serviceToken/pane")
    // 空 bundleID（命令行/测试环境）→ 省略参数且无尾随空格
    check(ScreenPermissions.reauthorizationHint(bundleID: "", pane: .accessibility).command
          == "tccutil reset Accessibility",
          "空 bundleID → 全量重置该服务（无尾随空格）")
    // 纯空白 bundleID 经 trim 后同于空
    check(ScreenPermissions.reauthorizationHint(bundleID: "   \n", pane: .microphone).command
          == "tccutil reset Microphone",
          "空白 bundleID 经 trim 回退全量重置")
}

// 方案第三节「向虚拟屏拖放窗口」：WindowArranger 纯几何落点（居中/钳制/多屏偏移）。
// 真正 AX 移动窗口依赖辅助功能权限与前台 App（真机 GUI 门控），此处只验可离线证明的几何逻辑。
func windowArrangerTest() {
    // 1) 小窗口居中（保持尺寸）
    let vis = CGRect(x: 0, y: 0, width: 1920, height: 1080)
    let c = WindowArranger.place(windowSize: CGSize(width: 800, height: 600), in: vis)
    check(c.size == CGSize(width: 800, height: 600), "居中放置保持期望尺寸")
    check(c.origin == CGPoint(x: 560, y: 240), "1920x1080 内 800x600 居中→(560,240) 实得(\(Int(c.minX)),\(Int(c.minY)))")

    // 2) 窗口大于可见区：钳制到可见区并保留边距，完整落在屏内
    let small = CGRect(x: 0, y: 0, width: 1000, height: 800)
    let big = WindowArranger.place(windowSize: CGSize(width: 5000, height: 5000), in: small, margin: 20)
    check(big.width == 960 && big.height == 760, "超限窗口钳制为 960x760（可见区扣双边距）实得 \(Int(big.width))x\(Int(big.height))")
    check(big.minX >= small.minX && big.maxX <= small.maxX && big.minY >= small.minY && big.maxY <= small.maxY,
          "钳制后窗口完整落在可见区内")

    // 3) 多屏偏移：第二块屏 (1920,0) 上的居中 x 应含屏原点偏移
    let second = CGRect(x: 1920, y: 0, width: 1920, height: 1080)
    let off = WindowArranger.place(windowSize: CGSize(width: 800, height: 600), in: second)
    check(off.origin == CGPoint(x: 2480, y: 240), "副屏居中 x 含屏偏移→(2480,240) 实得(\(Int(off.minX)),\(Int(off.minY)))")

    // 4) globalFrame 对不存在的 displayID 不崩溃（返回某矩形或零）
    let g = WindowArranger.globalFrame(ofDisplay: 0xDEADBEEF)
    check(g == .zero || g.width >= 0, "globalFrame 对未知 displayID 安全返回")
}

// MARK: - 主流程

print("▶ ComposeLayout（预设/钳制/8K 兜底）")
layoutTests()
print("▶ DKEncode + DKMux（合成帧 → H.264 → MKV/MP4 冒烟）")
encodeMuxTests()
print("▶ DKEncode HEVC → MKV/MOV 封装矩阵")
hevcMuxTests()
print("▶ DKEncode ProRes → MOV 冒烟")
proResSmoke()
print("▶ DKMux MKV 音轨（H.264 + 内置 AAC 编码双路径）")
mkvAudioTest()
print("▶ DKExport WebM 容器（假 libvpx codec 注入→抽帧→封装）")
webmContainerTest()
#if DISYNK_LIBVPX
print("▶ DKExport WebM 真实 libvpx VP8/VP9 编码（vpx_codec_encode → 有效容器）")
webmLibVPXRealTest()
#endif
print("▶ DKCompose Metal 实时合成（画面位置与布局一致性）")
composeMergeTest()
print("▶ DKCompose 合并→编码→封装单文件端到端（§七 合并模式验收：合成单文件）")
composeMergeToFileTest()
print("▶ DKCompose 合并对齐门（≤一帧偏差凑齐一帧/最小 PTS）")
composeGateTest()
print("▶ DKSettings（持久化 round-trip / 分辨率解析）")
settingsTests()
print("▶ DKCore 磁盘写入速度探测（F_FULLFSYNC 实测 + 告警阈值）")
diskProbeTest()
print("▶ DKShot 识别文本导出（TXT/Markdown round-trip）")
try shotExportTest()
print("▶ DKShot 像素倍率纯函数 + PNG 落盘 round-trip（方案：截图存储路径）")
try shotScaleSaveTest()
print("▶ DKCore 像素几何纯函数（偶数对齐/选区尺寸，单目标录制用）")
pixelMathTest()
print("▶ DKShot 滚动长截图拼接（重叠检测/偏移堆叠/stitch 端到端）")
scrollStitchTest()
print("▶ DKCore 编码会话容量估算（§四：硬编上限/ProRes 软编）")
encodeCapacityTest()
print("▶ DKCapture 帧率钳制（方案第四节：不超源屏刷新率）")
captureClampTest()
print("▶ DKCapture 覆盖层入画/不入画排除决策（§三独立开关 + §七关闭时不入画）")
overlayExclusionTest()
print("▶ DKCapture 引导重新授权（方案 M7 路径 A：tccutil 提示 + 隐私面板）")
permissionsReauthTest()
print("▶ DKOverlay 快捷键横幅组合解析（修饰键顺序/特殊键映射/字符回退）")
overlayComboTest()
print("▶ DKVirtualDisplay 集成冒烟（能力探测；创建/删除需 DISYNK_RUN_GUI_SMOKE=1）")
virtualDisplaySmokeTest()
print("▶ DKVirtualDisplay 向虚拟屏拖放窗口纯几何（居中/钳制/多屏偏移）")
windowArrangerTest()

// MARK: - 帧时钟（缺帧续帧）与跨屏框选几何

func frameClockTest() {
    var clk = FrameClock(fps: 30)
    let p0 = CMTime(seconds: 1000, preferredTimescale: 6000)
    let p1 = CMTime(seconds: 1000.1, preferredTimescale: 6000)
    check(clk.next(source: p0) == p0, "首帧透传源 PTS")
    check(clk.next(source: p1) == p1, "递增源 PTS 透传")
    let syn = clk.next(source: nil)
    check(CMTimeCompare(syn, p1) > 0, "合成帧（无源 PTS）顺延且单调")
    check(clk.next(source: p0) == CMTimeAdd(syn, clk.interval), "回退源 PTS 被拒→顺延一个间隔")
    var prev = clk.next(source: nil)
    var mono = true
    for _ in 0..<10 {
        let n = clk.next(source: nil)
        if CMTimeCompare(n, prev) <= 0 { mono = false }
        prev = n
    }
    check(mono, "连续续帧严格单调递增")
    let iv = FrameClock(fps: 30).interval
    check(abs(CMTimeGetSeconds(iv) - 1.0 / 30.0) < 1e-9, "30fps 帧间隔 = 1/30s")
    check(abs(CMTimeGetSeconds(FrameClock(fps: 60).interval) - 1.0 / 60.0) < 1e-9, "60fps 帧间隔 = 1/60s")
    check(abs(CMTimeGetSeconds(FrameClock(fps: 0).interval) - 1.0 / 30.0) < 1e-9, "非法帧率回退 30fps")
    var r = FrameClock(fps: 25)
    _ = r.next(source: p1)
    r.reset()
    check(r.lastEmitted == nil, "reset 后时钟清空")
}

/// 帧取舍回归（成片「只剩开头几秒」的真因）：
/// SCK 的 .idle 样本是「画面未生成」的信号，不带像素缓冲；旧实现当它入编码并当作
/// 「最近一帧」存下 → 续帧定时器拿空壳补帧全被拒 → 静屏期间视频轨零增长。
func framePictureTest() {
    // 不带像素缓冲：无论何种状态（含 idle / 状态缺失）都不算画面帧
    check(DisplayCapture.deliversPicture(status: .idle, hasPixelBuffer: false) == false, "idle 无像素→不入帧")
    check(DisplayCapture.deliversPicture(status: nil, hasPixelBuffer: false) == false, "状态缺失且无像素→不入帧")
    check(DisplayCapture.deliversPicture(status: .complete, hasPixelBuffer: false) == false, "声称 complete 但无像素→不入帧")
    // 带像素缓冲：complete / started / idle 均可用（idle 带画面时也不应错杀）
    check(DisplayCapture.deliversPicture(status: .complete, hasPixelBuffer: true) == true, "complete 带像素→入帧")
    check(DisplayCapture.deliversPicture(status: .started, hasPixelBuffer: true) == true, "started 带像素→入帧")
    check(DisplayCapture.deliversPicture(status: .idle, hasPixelBuffer: true) == true, "idle 带像素→入帧")
    check(DisplayCapture.deliversPicture(status: nil, hasPixelBuffer: true) == true, "状态未知带像素→入帧")
    // 真无画面的状态即使带了残留像素也不可用
    check(DisplayCapture.deliversPicture(status: .blank, hasPixelBuffer: true) == false, "blank→不入帧")
    check(DisplayCapture.deliversPicture(status: .suspended, hasPixelBuffer: true) == false, "suspended→不入帧")
    check(DisplayCapture.deliversPicture(status: .stopped, hasPixelBuffer: true) == false, "stopped→不入帧")
}

func screenGeometryTest() {
    let main = ScreenGeometry.DisplayArea(id: 1, frame: CGRect(x: 0, y: 0, width: 1920, height: 1080))
    let second = ScreenGeometry.DisplayArea(id: 2, frame: CGRect(x: 1920, y: 0, width: 2560, height: 1440))
    let ds = [main, second]

    check(ScreenGeometry.union([main.frame, second.frame])
            == CGRect(x: 0, y: 0, width: 4480, height: 1440), "并集覆盖两屏")

    // 副屏内选区：全局 → 屏内左上坐标
    if let hit = ScreenGeometry.hitDisplay(CGRect(x: 2000, y: 100, width: 400, height: 300), in: ds) {
        check(hit.0 == 2, "选区在副屏→回报副屏 displayID")
        check(hit.1 == CGRect(x: 80, y: 100, width: 400, height: 300), "选区换算为屏内左上坐标")
    } else { check(false, "选区在副屏→回报副屏 displayID") }

    // 跨屏缝隙：取相交面积最大的一块并裁剪
    if let hit = ScreenGeometry.hitDisplay(CGRect(x: 1890, y: 10, width: 40, height: 100), in: ds) {
        check(hit.0 == 1, "跨屏选区取相交最大屏")
        check(hit.1 == CGRect(x: 1890, y: 10, width: 30, height: 100), "跨屏选区裁剪到屏内")
    } else { check(false, "跨屏选区取相交最大屏") }

    check(ScreenGeometry.hitDisplay(.zero, in: ds) == nil, "退化选区无命中")
    check(ScreenGeometry.hitDisplay(CGRect(x: 5000, y: 0, width: 10, height: 10), in: ds) == nil,
          "完全在屏外无命中")

    // AppKit 视图矩形 → 全局左上（副屏在主屏下方、窗口覆盖并集的场景）
    let viewGlobal = CGRect(x: 0, y: -1080, width: 1920, height: 2160)   // AppKit 并集（左下原点）
    let g = ScreenGeometry.toGlobalTopLeft(rect: CGRect(x: 100, y: 100, width: 200, height: 300),
                                           viewGlobal: viewGlobal, topEdge: 1080)
    check(g == CGRect(x: 100, y: 1760, width: 200, height: 300), "视图矩形→全局左上原点换算")
}

// v0.1.14 新增设置字段的编解码 + 旧配置宽容解码（缺键不重置）
func settingsV2CodableTest() {
    var s = AppSettingsSnapshot()
    s.recording.recordDelaySeconds = 5
    s.recording.windowBackground = .customImage("/tmp/wp.png")
    s.shortcuts = [.record: KeyCombo(keyCode: 15, modifiers: 1179648),
                   .shotRegion: KeyCombo(keyCode: 4, modifiers: 1179648)]
    s.ocrEnabled = true
    do {
        let data = try JSONEncoder().encode(s)
        let back = try JSONDecoder().decode(AppSettingsSnapshot.self, from: data)
        check(back.recording.recordDelaySeconds == 5, "recordDelaySeconds 往返")
        if case .customImage(let p) = back.recording.windowBackground { check(p == "/tmp/wp.png", "windowBackground 往返") }
        else { check(false, "windowBackground 往返") }
        check(back.shortcuts.count == 2
                && back.shortcuts[.record]?.keyCode == 15
                && back.shortcuts[.shotRegion]?.modifiers == 1179648, "shortcuts 字典往返")
        check(back.ocrEnabled == true, "ocrEnabled 往返")
    } catch { check(false, "设置 v2 编码异常：\(error)") }

    // 旧 JSON：无 recordDelaySeconds/windowBackground/shortcuts → 取默认且 decode 不抛
    let legacy = "{\"recording\":{\"codec\":\"hevc\"}}"
    if let d = legacy.data(using: .utf8),
       let decoded = try? JSONDecoder().decode(AppSettingsSnapshot.self, from: d) {
        check(decoded.recording.recordDelaySeconds == 0, "旧配置缺键→延迟默认 0")
        check(decoded.recording.windowBackground == .transparent, "旧配置缺键→背景默认透明")
        check(decoded.shortcuts.isEmpty, "旧配置缺键→无快捷键")
        check(decoded.ocrEnabled == false, "旧配置缺键→OCR 默认关")
    } else { check(false, "旧配置缺键应宽容解码不报错") }

    // WindowBackground / ShortcutAction 自身编解码
    do {
        let wb = try JSONEncoder().encode(WindowBackground.transparent)
        let wb2 = try JSONDecoder().decode(WindowBackground.self, from: wb)
        check(wb2 == .transparent, "WindowBackground.transparent 往返")
        // v0.1.17 新增：开面板/开录屏面板/按格式录制 三个快捷键（旧键位 rawValue 不变，保证旧配置仍有义）
        check(ShortcutAction.allCases.count == 10, "ShortcutAction 十个操作")
        check(ShortcutAction.record.rawValue == "record", "record rawValue 向后兼容")
        check(ShortcutAction.allCases.allSatisfy { !$0.displayName.isEmpty }, "每个快捷键都有中文名")
        check(Set(ShortcutAction.allCases.map { $0.rawValue }).count == ShortcutAction.allCases.count, "快捷键 rawValue 没有重复")
    } catch { check(false, "枚举编码异常：\(error)") }
}

// v0.1.57：截图保存格式枚举的编解码 + 旧配置宽容
func shotFormatCodableTest() {
    var s = AppSettingsSnapshot()
    s.screenshotFormat = .webp
    do {
        let data = try JSONEncoder().encode(s)
        let back = try JSONDecoder().decode(AppSettingsSnapshot.self, from: data)
        check(back.screenshotFormat == .webp, "screenshotFormat 往返")
    } catch { check(false, "screenshotFormat 编码异常：\(error)") }
    let legacy = "{\"recording\":{\"codec\":\"hevc\"}}"
    if let d = legacy.data(using: .utf8),
       let decoded = try? JSONDecoder().decode(AppSettingsSnapshot.self, from: d) {
        check(decoded.screenshotFormat == .png, "旧配置缺键→截图格式默认 PNG")
    } else { check(false, "旧配置缺键应宽容解码不报错") }

    check(ShotFormat.png.fileExtension == "png" && ShotFormat.jpeg.fileExtension == "jpg"
            && ShotFormat.heic.fileExtension == "heic" && ShotFormat.webp.fileExtension == "webp",
          "ShotFormat 扩展名映射（jpeg → jpg）")
    check(ShotFormat.png.imageIOType == "public.png"
            && ShotFormat.jpeg.imageIOType == "public.jpeg"
            && ShotFormat.heic.imageIOType == "public.heic"
            && ShotFormat.webp.imageIOType == nil, "imageIOType 映射（webp 不走 ImageIO）")
    check(!ShotFormat.png.isLossy && ShotFormat.jpeg.isLossy
            && ShotFormat.heic.isLossy && ShotFormat.webp.isLossy, "仅 PNG 无损")
    check(Set(ShotFormat.allCases.map(\.rawValue)) == ["png", "jpeg", "heic", "webp"],
          "ShotFormat rawValue 集合稳定")
}

/// 小尺寸双色渐变 + 半透明块（验证各格式与 alpha 压平路径）
func makeShotTestImage(width: Int = 64, height: Int = 48) -> CGImage {
    let cs = CGColorSpaceCreateDeviceRGB()
    let ctx = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                        space: cs, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
    ctx.setFillColor(CGColor(red: 0.2, green: 0.4, blue: 0.8, alpha: 1))
    ctx.fill(CGRect(x: 0, y: 0, width: width, height: height / 2))
    ctx.setFillColor(CGColor(red: 0.9, green: 0.6, blue: 0.1, alpha: 1))
    ctx.fill(CGRect(x: 0, y: height / 2, width: width, height: height / 2))
    ctx.setFillColor(CGColor(red: 1, green: 0, blue: 0, alpha: 0.5))
    ctx.fill(CGRect(x: width / 4, y: height / 4, width: width / 2, height: height / 2))
    return ctx.makeImage()!
}

// v0.1.57：Screenshotter 按格式保存分发（png/jpeg/heic 真写盘回读；webp 门控 libvpx）
func screenshotFormatSaveTest() {
    let dir = URL(fileURLWithPath: NSTemporaryDirectory())
        .appendingPathComponent("dkshots.\(UUID().uuidString)")
    let img = makeShotTestImage()
    for fmt: ShotFormat in [.png, .jpeg, .heic] {
        do {
            let url = try Screenshotter.save(img, format: fmt, to: dir, namePrefix: "t")
            check(url.pathExtension == fmt.fileExtension, "\(fmt.rawValue) 保存扩展名")
            let decoded = CGImageSourceCreateWithURL(url as CFURL, nil)
                .flatMap { CGImageSourceCreateImageAtIndex($0, 0, nil) }
            check(decoded != nil && decoded!.width == img.width && decoded!.height == img.height,
                  "\(fmt.rawValue) 可解码回读且尺寸一致")
        } catch { check(false, "\(fmt.rawValue) 保存异常：\(error)") }
    }
    #if DISYNK_LIBVPX
    do {
        let url = try Screenshotter.save(img, format: .webp, to: dir, namePrefix: "t")
        let data = try Data(contentsOf: url)
        let magic = [UInt8](data.prefix(4)), riffTag = [UInt8](data[8..<12]), fourcc = [UInt8](data[12..<16])
        check(magic == Array("RIFF".utf8) && riffTag == Array("WEBP".utf8) && fourcc == Array("VP8 ".utf8),
              "WebP RIFF/WEBP + VP8 魔数")
        let decoded = CGImageSourceCreateWithURL(url as CFURL, nil)
            .flatMap { CGImageSourceCreateImageAtIndex($0, 0, nil) }
        check(decoded != nil && decoded!.width == img.width && decoded!.height == img.height,
              "WebP 可被 ImageIO 解码回读且尺寸一致")
    } catch { check(false, "WebP 保存异常：\(error)") }
    #else
    checkThrows("未装配 libvpx 时 WebP 保存抛错（调用方回退 PNG）") {
        _ = try Screenshotter.save(img, format: .webp, to: dir, namePrefix: "t")
    }
    #endif
    try? FileManager.default.removeItem(at: dir)
}

// v0.1.57：旧默认 .custom(1920×1080) 一次性迁移原生；其他自定义值与其他用户选择不动
func resolutionMigrationTest() {
    let defaults = UserDefaults(suiteName: "dktests.\(UUID().uuidString)")!
    var legacy = AppSettingsSnapshot()
    legacy.recording.resolution = .custom(PixelSize(width: 1920, height: 1080))
    defaults.set(try! JSONEncoder().encode(legacy), forKey: "disynk.settings.v1")
    let migrated = SettingsStore(defaults: defaults)
    bridgeSync {
        let s = await migrated.current()
        if case .native = s.recording.resolution { check(true, "旧 custom(1920×1080) 一次性迁移为原生") }
        else { check(false, "旧 custom(1920×1080) 一次性迁移为原生") }

        // 非 1080p 的自定义（用户主动选的）不能被误改
        var keep = AppSettingsSnapshot()
        keep.recording.resolution = .custom(PixelSize(width: 2560, height: 1440))
        let suite2 = UserDefaults(suiteName: "dktests.\(UUID().uuidString)")!
        suite2.set(try! JSONEncoder().encode(keep), forKey: "disynk.settings.v1")
        let s2 = await SettingsStore(defaults: suite2).current()
        if case .custom(let px) = s2.recording.resolution {
            check(px.width == 2560 && px.height == 1440, "非 1080p 自定义分辨率保持不变")
        } else { check(false, "非 1080p 自定义分辨率保持不变") }

        // 迁移只发生一次：之后用户再选回 1080p 自定义应被尊重
        await migrated.mutate { $0.recording.resolution = .custom(PixelSize(width: 1920, height: 1080)) }
        let s3 = await SettingsStore(defaults: defaults).current()
        if case .custom = s3.recording.resolution { check(true, "迁移后仍尊重用户自定义选择") }
        else { check(false, "迁移后仍尊重用户自定义选择") }
    }
}

print("▶ DKCapture 帧取舍（idle 空壳样本不入编码，黑屏真因回归）")
framePictureTest()

print("▶ DKCore 帧时钟（静屏缺帧续帧的单调 PTS，修「只有一帧后黑屏」）")
frameClockTest()
print("▶ DKCore 跨屏框选几何（副屏选区命中与坐标换算）")
screenGeometryTest()
print("▶ DKSettings v0.1.14 新字段编解码（延迟/背景/快捷键）+ 旧配置宽容")
settingsV2CodableTest()
print("▶ DKSettings v0.1.57 截图格式 ShotFormat 编解码 + 映射")
shotFormatCodableTest()
print("▶ DKShot v0.1.57 按格式保存分发（PNG/JPG/HEIC/WebP）")
screenshotFormatSaveTest()
print("▶ DKSettings v0.1.57 旧默认 1920×1080 自定义→原生一次性迁移")
resolutionMigrationTest()

print("\n结果：\(passed) 通过 / \(failed.count) 失败")
if !failed.isEmpty {
    for f in failed { print("  FAIL: \(f)") }
    exit(1)
}
print("ALL PASS")
exit(0)
