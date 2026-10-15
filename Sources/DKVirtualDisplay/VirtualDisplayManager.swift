import DKCore
import Foundation
import AppKit
import DVKObjC

/// 虚拟屏管理（方案 M5）：CGVirtualDisplay 私有 API 的 Swift 安全封装。
/// 生命周期：create → 获得 CGDirectDisplayID（可被 SCK 当普通屏录制）→ destroy。
/// 关键：CGVirtualDisplay 的创建/销毁（及其强引用释放）必须在**主线程**进行——
/// 它的 WindowServer mach port / runloop source 绑定主线程，在后台线程释放会导致
/// 堆损坏 / 崩溃（曾在 actor 后台执行器上 destroyAll 触发 EXC_BAD_ACCESS）。
/// 故本类型用 @MainActor 而非后台 actor，所有方法都在主线程串行执行。
@MainActor
public final class VirtualDisplayManager {
    public struct VirtualScreen: Sendable, Hashable {
        public var displayID: UInt32
        public var width: Int
        public var height: Int
        public var name: String
        public var hiDPI: Bool

        public init(displayID: UInt32, width: Int, height: Int, name: String, hiDPI: Bool = false) {
            self.displayID = displayID
            self.width = width
            self.height = height
            self.name = name
            self.hiDPI = hiDPI
        }
    }

    public enum Preset: Sendable {
        case fullHD, retina2K, fourK

        var size: (w: Int, h: Int) {
            switch self {
            case .fullHD: return (1920, 1080)
            case .retina2K: return (2560, 1440)
            case .fourK: return (3840, 2160)
            }
        }
        /// retina2K/fourK 预设默认开启 HiDPI（方案第三节：自定义分辨率与 HiDPI）。
        var defaultHiDPI: Bool {
            switch self {
            case .fullHD: return false
            case .retina2K, .fourK: return true
            }
        }
    }

    private(set) var created: [VirtualScreen] = []
    /// 同名同尺寸复用 serial（系统 ICC 记录关联，见调研笔记）
    private var serialByTitle: [String: UInt] = [:]
    private var nextSerial: UInt = 0xC0FFEE00

    public init() {}

    /// 私有 API 在当前系统是否可用（运行时探测；大版本更新可能失效 → UI 降级提示）
    public static func isSupported() -> Bool {
        DVKVirtualDisplayAvailable()
    }

    @discardableResult
    public func create(width: Int, height: Int, refreshHz: Double = 60, hiDPI: Bool = false,
                       name: String = "Disynk Virtual") throws -> VirtualScreen {
        guard Self.isSupported() else {
            throw DKError.virtualDisplayUnsupported("系统未暴露 CGVirtualDisplay 私有类")
        }
        // 偶数对齐 + serial 幂等
        let w = width - (width % 2), h = height - (height % 2)
        let title = "\(name) \(w)x\(h)"
        let serial = serialByTitle[title] ?? {
            let s = nextSerial
            nextSerial += 1
            return s
        }()
        serialByTitle[title] = serial

        var err: NSString?
        let id = DVKCreateVirtualDisplay(UInt(w), UInt(h), refreshHz, hiDPI,
                                         title, serial, &err)
        guard id != 0 else {
            throw DKError.virtualDisplayUnsupported(
                (err as String?) ?? "CGVirtualDisplay 创建失败(\(w)x\(h))")
        }
        // id 非 0 但仍可能未 online（SCK 列不出来）：把 C 层提示记入日志，便于排查。
        if let warning = err as String? {
            DKLog.virtualDisplay.info("虚拟屏提示：\(warning, privacy: .public)")
        }
        let screen = VirtualScreen(displayID: id, width: w, height: h, name: title, hiDPI: hiDPI)
        created.append(screen)
        DKLog.virtualDisplay.info("虚拟屏创建 #\(id, privacy: .public) \(w, privacy: .public)x\(h, privacy: .public)")
        return screen
    }

    public func create(preset: Preset, name: String = "Disynk Virtual") throws -> VirtualScreen {
        let s = preset.size
        return try create(width: s.w, height: s.h, hiDPI: preset.defaultHiDPI, name: name)
    }

    public func destroy(displayID: UInt32) throws {
        var err: NSString?
        let ok = DVKDestroyVirtualDisplay(displayID, &err)
        guard ok else {
            throw DKError.virtualDisplayUnsupported((err as String?) ?? "销毁失败")
        }
        created.removeAll { $0.displayID == displayID }
    }

    public func destroyAll() {
        // 逆序销毁，逐个从注册表移除强引用；每移除一个后让主 runloop 拍一拍，
        // 给 WindowServer 处理「显示器下线」事件的时间，避免与后续访问竞态。
        for s in created.reversed() {
            var err: NSString?
            _ = DVKDestroyVirtualDisplay(s.displayID, &err)
            RunLoop.current.run(until: Date(timeIntervalSinceNow: 0.05))
        }
        created.removeAll()
    }

    public func list() -> [VirtualScreen] { created }
}
