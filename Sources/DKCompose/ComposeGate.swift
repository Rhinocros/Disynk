import CoreMedia
import Foundation

/// 合并模式的「凑齐一帧」对齐门（方案 M2.5 / §七合并验收：各屏对齐偏差 ≤1 帧）。
///
/// 纯决策逻辑，只跟踪每屏最新帧的 PTS 与消费标志，不持有 `CVPixelBuffer`——
/// 像素缓冲留在上层（RecordingEngine）。因此可在无捕获/无 Metal 的环境下离线单测。
///
/// 语义与录制管线逐条对应：
/// - `note(_:pts:)`：某屏到达新帧，记录其 PTS 并标记为「未消费」。
/// - `isReady`：当且仅当所有期望屏都已登记且都持有未消费新帧时，才允许合成一帧。
/// - `mergedPTS`：合成帧时间戳取各屏最新帧 PTS 的最小值（对齐基准，偏差 ≤1 帧）。
/// - `markConsumed()`：本轮合成后把所有槽标记为已消费，等待各屏各自的下一新帧。
public struct ComposeGate: Sendable {
    /// 期望参与合成的屏集合（合并模式 ≥2 屏）。
    public let expected: Set<UInt32>

    private struct Slot {
        var pts: CMTime
        var consumed: Bool
    }
    private var slots: [UInt32: Slot] = [:]

    public init(expected: Set<UInt32>) {
        self.expected = expected
    }

    /// 记录某屏最新帧 PTS，并置为未消费（仅接受 expected 内的屏）。
    public mutating func note(_ displayID: UInt32, pts: CMTime) {
        guard expected.contains(displayID) else { return }
        slots[displayID] = Slot(pts: pts, consumed: false)
    }

    /// 所有期望屏均已登记且都持有未消费新帧 → 可合成。
    public var isReady: Bool {
        guard !expected.isEmpty else { return false }
        guard slots.count == expected.count else { return false }
        return expected.allSatisfy { slots[$0]?.consumed == false }
    }

    /// 合成帧时间戳 = 各屏最新帧 PTS 的最小值；未就绪时为 nil。
    public var mergedPTS: CMTime? {
        guard isReady else { return nil }
        var minPTS: CMTime?
        for id in expected {
            guard let p = slots[id]?.pts else { return nil }
            if let m = minPTS { if p < m { minPTS = p } } else { minPTS = p }
        }
        return minPTS
    }

    /// 本轮合成后标记全部已消费，等待各屏下一新帧再凑齐。
    public mutating func markConsumed() {
        for id in slots.keys { slots[id]?.consumed = true }
    }

    /// 复位（停止/重启时清空所有槽）。
    public mutating func reset() {
        slots.removeAll()
    }
}
