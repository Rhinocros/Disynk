import CoreGraphics
import Foundation

/// 输出像素尺寸（偶数对齐，编码器硬要求）
public struct PixelSize: Sendable, Hashable, Codable {
    public var width: Int
    public var height: Int

    public init(width: Int, height: Int) {
        // VideoToolbox 要求偶数宽高，构造时向下取偶
        self.width = max(2, width - (width % 2))
        self.height = max(2, height - (height % 2))
    }

    public var evenAligned: Bool { width % 2 == 0 && height % 2 == 0 }
    public var pixels: Int { width * height }
}

/// 分辨率模式：内置预设或自定义（方案第三节「分辨率选择」）
public enum ResolutionMode: Sendable, Hashable, Codable {
    case native                       // 跟随源屏（HiDPI 2x）
    case preset(PixelSize)            // 1080p / 1440p / 4K …
    case custom(PixelSize)

    private enum CodingKeys: String, CodingKey { case kind, width, height }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        switch try c.decode(String.self, forKey: .kind) {
        case "native": self = .native
        case "preset": self = .preset(PixelSize(width: try c.decode(Int.self, forKey: .width),
                                                height: try c.decode(Int.self, forKey: .height)))
        default: self = .custom(PixelSize(width: try c.decode(Int.self, forKey: .width),
                                          height: try c.decode(Int.self, forKey: .height)))
        }
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case .native: try c.encode("native", forKey: .kind)
        case .preset(let s):
            try c.encode("preset", forKey: .kind)
            try c.encode(s.width, forKey: .width); try c.encode(s.height, forKey: .height)
        case .custom(let s):
            try c.encode("custom", forKey: .kind)
            try c.encode(s.width, forKey: .width); try c.encode(s.height, forKey: .height)
        }
    }

    /// 常用预设（保持 16:9；实际输出时按源屏长宽比适配，见 scaleToFit）
    public static let presets16x9: [PixelSize] = [
        PixelSize(width: 1280, height: 720),
        PixelSize(width: 1920, height: 1080),
        PixelSize(width: 2560, height: 1440),
        PixelSize(width: 3840, height: 2160),
    ]

    /// 将目标模式解析为相对源尺寸的具体输出像素（保持长宽比、偶数对齐）
    public func resolve(source sourceSize: PixelSize) -> PixelSize {
        let target: PixelSize
        switch self {
        case .native: target = sourceSize
        case .preset(let s), .custom(let s): target = s
        }
        return Self.scaleToFit(source: sourceSize, into: target)
    }

    /// 在 target 框内按源长宽比取最大矩形（偶数对齐）
    public static func scaleToFit(source: PixelSize, into target: PixelSize) -> PixelSize {
        let scale = min(Double(target.width) / Double(source.width),
                        Double(target.height) / Double(source.height))
        return PixelSize(width: Int(Double(source.width) * scale),
                         height: Int(Double(source.height) * scale))
    }
}

/// 帧率（秒/帧，直接映射 SCStreamConfiguration.minimumFrameInterval 与 VT 时基）
public struct FrameRate: Sendable, Hashable, Codable {
    public var fps: Double

    public init(fps: Double) { self.fps = max(1, min(fps, 240)) }

    public static let p30 = FrameRate(fps: 30)
    public static let p60 = FrameRate(fps: 60)
    public static let builtinPresets: [FrameRate] = [.p30, .p60]

    /// SCK 取帧间隔（timescale 取 1000 以便 29.97 等非整数帧率近似）
    public var minimumFrameInterval: (value: Int64, timescale: Int32) {
        (value: Int64((1000.0 / fps).rounded()), timescale: 1000)
    }
}

/// 显示器快照（物理屏或虚拟屏统一模型）
public struct DisplaySnapshot: Sendable, Hashable, Identifiable {
    public var id: UInt32            // CGDirectDisplayID
    public var name: String
    public var sourceSize: PixelSize // 采集源像素尺寸（含 HiDPI 倍率）
    public var refreshRateHz: Double // 屏刷新率，帧率上限探测用
    public var isVirtual: Bool
    public var origin: CGPoint       // 全局桌面坐标（左上）

    public init(id: UInt32, name: String, sourceSize: PixelSize,
                refreshRateHz: Double, isVirtual: Bool, origin: CGPoint) {
        self.id = id
        self.name = name
        self.sourceSize = sourceSize
        self.refreshRateHz = refreshRateHz
        self.isVirtual = isVirtual
        self.origin = origin
    }
}

/// 可录制窗口快照（窗口录制下拉列表用）
public struct WindowSnapshot: Sendable, Hashable, Identifiable {
    public var id: UInt32            // CGWindowID
    public var title: String
    public var appName: String
    public var size: PixelSize

    public init(id: UInt32, title: String, appName: String, size: PixelSize) {
        self.id = id
        self.title = title
        self.appName = appName
        self.size = size
    }

    /// 列表展示名：应用 — 标题
    public var displayLabel: String {
        let t = title.isEmpty ? "（无标题）" : title
        return "\(appName) — \(t)"
    }
}
