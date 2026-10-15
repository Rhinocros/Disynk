import Foundation

/// 视频编码格式（方案第三节：H.264 / HEVC / ProRes 422；AV1/VP9 硬件编码不可行已排除）
public enum VideoCodec: String, Sendable, CaseIterable, Codable, Identifiable {
    case h264
    case hevc
    case proRes422

    public var id: String { rawValue }

    public var displayName: String {
        switch self {
        case .h264: return "H.264"
        case .hevc: return "HEVC (H.265)"
        case .proRes422: return "ProRes 422"
        }
    }

    /// ProRes 为 CPU 软编路径，多屏同录时 UI 需提示（方案第四节）
    public var isHardwareAccelerated: Bool { self != .proRes422 }
}

/// 封装容器（MP4/MOV 走 AVAssetWriter；MKV 走 DKMux 内置 EBML 写手）
public enum ContainerFormat: String, Sendable, CaseIterable, Codable, Identifiable {
    case mp4
    case mov
    case mkv

    public var id: String { rawValue }
    public var fileExtension: String { rawValue }
    public var displayName: String { rawValue.uppercased() }
}

/// 多屏输出模式（方案第三节）
public enum OutputMode: String, Sendable, CaseIterable, Codable {
    case separateFiles   // 每屏一个文件
    case composedOnly    // 仅合并为单个视频
    case both            // 两者同时

    public var displayName: String {
        switch self {
        case .separateFiles: return "多路独立文件"
        case .composedOnly: return "合并单文件"
        case .both: return "两者同时"
        }
    }
}

/// 编码容量建议（方案第四节：并发编码会话数接近媒体引擎上限 / ProRes 软编多路 → UI 显式提示）。
public enum EncodeCapacityAdvice: Sendable, Equatable {
    case info
    case softwareMultiSession
    case overHardwareLimit
}

/// 多屏编码会话容量估算（纯逻辑，UI 与引擎共用单一真相；方案第四节）。
public enum EncodeCapacity {
    /// Apple Silicon 媒体引擎并发硬编经验上限（超过即建议降级；方案：3~5 路 4K60）。
    public static let hardwareSessionLimit = 4

    /// 预计并发编码会话数：separate=displayCount，composed 在 ≥2 屏时合为 1 路。
    public static func sessionCount(displayCount: Int, mode: OutputMode) -> Int {
        guard displayCount > 0 else { return 0 }
        let separate = (mode != .composedOnly) ? displayCount : 0
        let merged = (mode != .separateFiles && displayCount >= 2) ? 1 : 0
        return separate + merged
    }

    /// 综合会话数与编解码硬编属性给出容量建议。
    public static func advise(displayCount: Int, mode: OutputMode, codec: VideoCodec) -> EncodeCapacityAdvice {
        let sessions = sessionCount(displayCount: displayCount, mode: mode)
        if !codec.isHardwareAccelerated && sessions > 1 { return .softwareMultiSession }
        if sessions > hardwareSessionLimit { return .overHardwareLimit }
        return .info
    }
}

/// 码率质量档（映射到平均比特率）
public enum QualityTier: String, Sendable, CaseIterable, Codable {
    case high, medium, low

    /// 按像素与帧率估算平均比特率（bps），H.264 基准；HEVC 取其 0.65 倍
    public func bitrateBps(size: PixelSize, fps: Double, codec: VideoCodec) -> Double {
        let base = Double(size.pixels) * fps * 0.15 // ~0.15 bit/pixel 经验值
        let tierFactor: Double
        switch self {
        case .high: tierFactor = 1.6
        case .medium: tierFactor = 1.0
        case .low: tierFactor = 0.55
        }
        let codecFactor: Double
        switch codec {
        case .h264: codecFactor = 1.0
        case .hevc: codecFactor = 0.65
        case .proRes422: return Double(size.pixels) * fps * 8.0 / 4.0 // ProRes 按 VBR 通道估算
        }
        return base * tierFactor * codecFactor
    }
}
