import Foundation

/// 跨串行域「移交所有权」传递非 Sendable 引用（CMSampleBuffer / AVCaptureSession 等）的薄盒。
/// 调用纪律：装入即交出原引用，同一实例只交给一个消费队列，消费后不复用；
/// 与帧路由「一次跳一队列、FIFO 保序」的现有模型一致，故 @unchecked Sendable 是安全的。
public struct SendableBox<T>: @unchecked Sendable {
    public let value: T
    public init(_ value: T) { self.value = value }
}

/// Disynk 统一错误类型
public enum DKError: Error, LocalizedError, Equatable {
    case permissionDenied(String)          // TCC 权限（录屏/麦克风/辅助功能）
    case noDisplaysAvailable               // SCShareableContent 未返回任何屏
    case displayNotFound(id: UInt32)
    case encoderSetup(String)              // VideoToolbox 会话建立失败
    case muxerFailure(String)              // 封装写入失败
    case captureStream(String)             // SCStream 启停异常
    case virtualDisplayUnsupported(String) // 私有 API 探测失败/系统版本不兼容
    case windowAutomation(String)          // 向虚拟屏拖放窗口（AX 自动化）失败/无权限
    case unsupportedForPhase(String)       // 当前阶段不支持的能力（如 WebM 需 libvpx）
    case diskTooSlow(warnMBs: Double)
    case other(String)

    public var errorDescription: String? {
        switch self {
        case .permissionDenied(let what): return "缺少权限：\(what)。请在「系统设置 → 隐私与安全性」中授权。"
        case .noDisplaysAvailable: return "未发现在录制的显示器。"
        case .displayNotFound(let id): return "显示器 \(id) 不存在或已被移除。"
        case .encoderSetup(let msg): return "编码器初始化失败：\(msg)"
        case .muxerFailure(let msg): return "封装写入失败：\(msg)"
        case .captureStream(let msg): return "捕获流异常：\(msg)"
        case .virtualDisplayUnsupported(let msg): return "虚拟屏不可用：\(msg)"
        case .windowAutomation(let msg): return "窗口自动化失败：\(msg)"
        case .unsupportedForPhase(let msg): return "当前版本不支持：\(msg)"
        case .diskTooSlow(let v): return String(format: "目标磁盘写入速度不足（实测 %.0f MB/s），可能掉帧。", v)
        case .other(let msg): return msg
        }
    }
}

/// 录制管线统计（供 UI 展示容量与掉帧告警）
public struct CaptureStats: Sendable, Equatable {
    /// 带像素缓冲的真实画面帧（可直接编码）
    public var framesIn: Int = 0
    public var framesEncoded: Int = 0
    public var framesDropped: Int = 0
    /// 「未生成新帧」投递（SCFrameStatusIdle 等，样本不带像素缓冲）：
    /// 静屏时 SCK 只发这种空壳样本，不能当画面帧入编码，否则时间轴与画面双双错乱
    public var framesIdle: Int = 0

    public init() {}
    public var dropRate: Double {
        framesIn == 0 ? 0 : Double(framesDropped) / Double(framesIn)
    }
}
