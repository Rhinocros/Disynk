import CoreGraphics
import CoreMedia
import Foundation

/// 视频帧时钟（纯函数化，可离线单测）。
///
/// 背景（「成片只有第一帧、之后黑屏」根因之一）：屏幕内容静止时 ScreenCaptureKit 只送
/// 首帧（后续为 idle 状态帧），若管线只在「新内容帧」时喂编码器，视频轨就停在 1 帧；
/// 播放器放完唯一一帧后画面即黑（音轨还在走）。解决办法是缺帧时按目标帧率「续帧」，
/// 而续帧必须有一条**单调、均匀**的时间轴，否则与真实帧 PTS 交错会破坏单调性 → 封装失败。
///
/// 规则：
/// - 首帧：透传源 PTS（与同文件音轨保持同一时间基）；无源 PTS 时从 0 起。
/// - 源 PTS 严格大于上一发出的 PTS：直接透传。
/// - 源 PTS 缺失/相等/回退（含合成帧 `source == nil`）：上一 PTS + 帧间隔顺延。
public struct FrameClock: Sendable {
    /// 目标帧间隔
    public let interval: CMTime
    /// 最近一次发出的 PTS
    public private(set) var lastEmitted: CMTime?

    /// - Parameter fps: 目标帧率；时间基默认 6000（30/60/120fps 均可整除，29.97 误差 <0.1%）
    public init(fps: Double, timescale: CMTimeScale = 6000) {
        let f = (fps.isFinite && fps >= 1) ? fps : 30
        let ticks = max(1.0, (Double(timescale) / f).rounded())
        self.interval = CMTime(value: CMTimeValue(ticks), timescale: timescale)
    }

    /// 取本帧应使用的 PTS 并推进时钟。`source == nil` 表示合成（续）帧。
    public mutating func next(source: CMTime?) -> CMTime {
        let t: CMTime
        if let last = lastEmitted {
            if let src = source, CMTimeCompare(src, last) > 0 {
                t = src
            } else {
                t = CMTimeAdd(last, interval)
            }
        } else {
            t = source ?? .zero
        }
        lastEmitted = t
        return t
    }

    /// 复位（一次录制结束时）
    public mutating func reset() { lastEmitted = nil }
}

/// 跨屏框选的几何换算（纯函数，可离线单测）。
/// 全局坐标系指 CG/AppKit 混合约定中的「左上原点、单位点」坐标（主屏左上为原点）。
public enum ScreenGeometry {
    /// 一块显示屏的信息：displayID + 全局左上原点矩形（点）
    public struct DisplayArea: Sendable, Equatable {
        public let id: UInt32
        public let frame: CGRect     // 全局、左上原点
        public init(id: UInt32, frame: CGRect) {
            self.id = id; self.frame = frame
        }
    }

    /// 所有屏幕帧的并集（框选遮罩窗口需要覆盖整个虚拟桌面）
    public static func union(_ frames: [CGRect]) -> CGRect {
        guard var u = frames.first else { return .zero }
        for f in frames.dropFirst() { u = u.union(f) }
        return u
    }

    /// AppKit 视图内矩形（左下原点）→ 全局左上原点矩形。
    /// - Parameters:
    ///   - rect: 视图 bounds 内的矩形（左下原点）
    ///   - viewGlobal: 该视图（窗口内容）在 AppKit 全局坐标系（左下原点）中的矩形
    ///   - topEdge: 全局坐标系顶边 y（AppKit 全局，即所有屏 frame.maxY 的最大值）
    public static func toGlobalTopLeft(rect: CGRect, viewGlobal: CGRect, topEdge: CGFloat) -> CGRect {
        let x = viewGlobal.minX + rect.minX
        let appKitY = viewGlobal.minY + rect.minY        // 全局左下原点 y
        return CGRect(x: x, y: topEdge - appKitY - rect.height, width: rect.width, height: rect.height)
    }

    /// 全局左上原点矩形 → 命中面积最大的显示屏，并把矩形裁剪到该屏内、换算为屏内左上原点坐标。
    /// 无相交（或矩形退化）返回 nil。
    public static func hitDisplay(_ rect: CGRect, in displays: [DisplayArea]) -> (UInt32, CGRect)? {
        guard rect.width > 0, rect.height > 0 else { return nil }
        var best: (UInt32, CGRect)?
        var bestArea: CGFloat = 0
        for d in displays {
            let inter = rect.intersection(d.frame)
            guard !inter.isNull, inter.width > 0, inter.height > 0 else { continue }
            let area = inter.width * inter.height
            if area > bestArea {
                bestArea = area
                best = (d.id, CGRect(x: inter.minX - d.frame.minX,
                                     y: inter.minY - d.frame.minY,
                                     width: inter.width, height: inter.height))
            }
        }
        return best
    }
}
