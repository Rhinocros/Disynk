import AppKit
import CoreGraphics
import DKCore
import Foundation
import ScreenCaptureKit

/// 显示器枚举：SCShareableContent（可录屏的权威列表）+ NSScreen/CGDisplay 补充名称与刷新率
public enum DisplayEnumerator {
    /// 返回当前所有可录制显示器快照。
    /// - Parameter includeVirtual: 是否包含虚拟屏（虚拟屏同样是 CGDirectDisplayID，SCK 可直接录）
    public static func available(includeVirtual: Bool = true) async throws -> [DisplaySnapshot] {
        let content: SCShareableContent
        do {
            content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
        } catch {
            DKLog.capture.error("SCShareableContent 获取失败: \(error.localizedDescription, privacy: .public)")
            throw DKError.captureStream("无法获取可录制内容：\(error.localizedDescription)")
        }

        var screensByName: [String: NSScreen] = [:]
        for s in NSScreen.screens {
            screensByName[s.localizedName] = s
        }

        var result: [DisplaySnapshot] = []
        for display in content.displays {
            let did = display.displayID
            // 虚拟屏判定：非内置且无厂商 ID（CGVirtualDisplay 创建的屏）
            let isVirtual = CGDisplayIsBuiltin(did) == 0 && CGDisplayVendorNumber(did) == 0

            let name = displayName(for: did, scDisplay: display, nsScreens: screensByName)
            if isVirtual && !includeVirtual { continue }

            let w: Int, h: Int
            if let mode = CGDisplayCopyDisplayMode(did), mode.pixelWidth > 0 {
                // 像素尺寸（含 HiDPI 倍率）
                w = Int(mode.pixelWidth)
                h = Int(mode.pixelHeight)
            } else {
                w = Int(CGDisplayPixelsWide(did))
                h = Int(CGDisplayPixelsHigh(did))
            }
            let sourceSize = PixelSize(width: w, height: h)
            let refresh = refreshRateHz(for: did)
            let origin = globalOrigin(for: did, nsScreens: screensByName)

            result.append(DisplaySnapshot(id: did,
                                          name: name,
                                          sourceSize: sourceSize,
                                          refreshRateHz: refresh,
                                          isVirtual: isVirtual,
                                          origin: origin))
        }
        if result.isEmpty { throw DKError.noDisplaysAvailable }
        return result
    }

    private static func displayName(for did: CGDirectDisplayID,
                                    scDisplay: SCDisplay,
                                    nsScreens: [String: NSScreen]) -> String {
        for (name, screen) in nsScreens {
            let screenID = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? UInt32
            if screenID == did { return name }
        }
        return "Display \(did)"
    }

    /// 刷新率探测：CGDisplayMode.refreshRate（很多内置屏返回 0，兜底 60Hz）
    private static func refreshRateHz(for did: CGDirectDisplayID) -> Double {
        guard let mode = CGDisplayCopyDisplayMode(did) else { return 60 }
        let hz = mode.refreshRate
        return hz > 0 ? hz : 60
    }

    /// 全局桌面坐标左上角（CG 坐标已是左上原点）
    private static func globalOrigin(for did: CGDirectDisplayID,
                                     nsScreens: [String: NSScreen]) -> CGPoint {
        for screen in nsScreens.values {
            let screenID = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? UInt32
            if screenID == did {
                // NSScreen.frame 是左下原点，转换为全局左上：主屏高度差
                let primaryHeight = NSScreen.screens.first?.frame.height ?? screen.frame.height
                return CGPoint(x: screen.frame.origin.x,
                               y: primaryHeight - screen.frame.origin.y - screen.frame.height)
            }
        }
        return .zero
    }
}
