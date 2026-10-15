@preconcurrency import AVFoundation
import AppKit
import DKCore

/// 摄像头小窗（方案第三节：AVCaptureDevice 摄像头小窗）
/// 浮动预览窗，不入录制管线（SCK 采屏自然可见，所见即所得）
@MainActor
final class CameraWindowController {
    static let shared = CameraWindowController()

    private var window: NSWindow?
    /// AVCaptureSession 非 Sendable：装进 SendableBox 后只在 sessionQueue 串行域使用
    private let session = SendableBox(AVCaptureSession())
    private let sessionQueue = DispatchQueue(label: "com.disynk.camera")

    func toggle() {
        if let window, window.isVisible {
            window.orderOut(nil)
            let box = session
            sessionQueue.async { box.value.stopRunning() }
            return
        }
        open()
    }

    private func open() {
        if window == nil {
            let panel = NSPanel(contentRect: NSRect(x: 0, y: 0, width: 320, height: 240),
                                styleMask: [.titled, .closable, .miniaturizable],
                                backing: .buffered, defer: false)
            panel.title = "摄像头"
            panel.level = .floating
            panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
            panel.isReleasedWhenClosed = false
            panel.isOpaque = false        // 透出桌面：窗体非不透明（vibrancy 边衬）
            panel.backgroundColor = .clear
            panel.hasShadow = true
            panel.setContentSize(NSSize(width: 320, height: 240))
            if let screen = NSScreen.main {
                let f = screen.frame
                panel.setFrameTopLeftPoint(NSPoint(x: f.minX + 40, y: f.maxY - 120))
            }

            // vibrancy 作外层边衬（透出桌面），预览层保持不透明铺满内区（画面需清晰）。
            let preview = AVCaptureVideoPreviewLayer(session: session.value)
            preview.videoGravity = .resizeAspectFill
            let effect = NSVisualEffectView(frame: NSRect(x: 0, y: 0, width: 320, height: 240))
            effect.material = .hudWindow
            effect.blendingMode = .behindWindow
            effect.state = .active
            effect.wantsLayer = true
            effect.layer?.cornerRadius = 12
            effect.layer?.masksToBounds = true
            preview.frame = effect.bounds.insetBy(dx: 6, dy: 6)
            preview.autoresizingMask = [.layerWidthSizable, .layerHeightSizable]
            effect.layer?.addSublayer(preview)
            panel.contentView = effect
            window = panel

            let box = session
            sessionQueue.async {
                let session = box.value
                session.beginConfiguration()
                session.sessionPreset = .high
                if let device = AVCaptureDevice.default(for: .video),
                   let input = try? AVCaptureDeviceInput(device: device),
                   session.canAddInput(input) {
                    session.addInput(input)
                }
                session.commitConfiguration()
                if session.inputs.isEmpty {
                    DKLog.capture.error("摄像头不可用（检查隐私与安全性→摄像头权限）")
                } else {
                    session.startRunning()   // 阻塞调用，置于非主队列
                }
            }
        }
        window?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }
}
