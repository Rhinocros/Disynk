import AppKit
import DKSettings
import SwiftUI

/// 快捷键页：每个核心操作一行，点录制框后按下组合键即绑定（存 keyCode + 修饰键）。
/// 全局生效依赖「辅助功能」权限；本应用在前景时也经本地监听生效。
struct ShortcutsTab: View {
    @EnvironmentObject var model: AppModel

    var body: some View {
        EPGridCardStack {
            VStack(alignment: .leading, spacing: 10) {
                    ForEach(ShortcutAction.allCases) { action in
                        HStack(spacing: 10) {
                            Text(action.displayName)
                            Spacer()
                            KeyRecorder(combo: binding(for: action))
                                .frame(width: 170, height: 26)
                            Button("清除") { model.mutateSettings { $0.shortcuts[action] = nil } }
                                .disabled(model.snapshot.shortcuts[action] == nil)
                                .epButton(small: true)
                        }
                    }
                    Text("未设置时保留默认：⌘⇧R = 开始/停止录制。修改即时生效。")
                        .font(.caption).foregroundStyle(.secondary)
                }
                .card("全局快捷键", subtitle: "点击录制框后按下组合键绑定；需「辅助功能」权限")
        }
    }

    private func binding(for action: ShortcutAction) -> Binding<KeyCombo?> {
        Binding(get: { model.snapshot.shortcuts[action] },
                set: { v in model.mutateSettings { $0.shortcuts[action] = v } })
    }
}

/// NSViewRepresentable 包装的按键录制控件。
struct KeyRecorder: NSViewRepresentable {
    @Binding var combo: KeyCombo?

    func makeNSView(context: Context) -> KeyRecorderView {
        let v = KeyRecorderView()
        v.combo = combo
        v.onChange = { combo = $0 }
        return v
    }

    func updateNSView(_ nsView: KeyRecorderView, context: Context) {
        nsView.combo = combo
    }
}

final class KeyRecorderView: NSView {
    var onChange: ((KeyCombo?) -> Void)?
    var combo: KeyCombo? { didSet { needsDisplay = true } }
    private var recording = false { didSet { needsDisplay = true } }

    override var acceptsFirstResponder: Bool { true }

    override func mouseDown(with event: NSEvent) {
        window?.makeFirstResponder(self)
        recording = true
    }

    override func resignFirstResponder() -> Bool {
        recording = false
        return true
    }

    override func keyDown(with event: NSEvent) {
        guard recording else { super.keyDown(with: event); return }
        if event.keyCode == 53 {                       // Esc 清除
            onChange?(nil)
            recording = false
            return
        }
        let mods = event.modifierFlags.intersection([.command, .option, .control, .shift])
        guard mods.contains(.command) || mods.contains(.control) || mods.contains(.option) else {
            NSSound.beep()                             // 要求至少一个功能修饰键，避免占用普通按键
            return
        }
        onChange?(KeyCombo(keyCode: event.keyCode, modifiers: mods.rawValue))
        recording = false
    }

    override func draw(_ dirtyRect: NSRect) {
        let path = NSBezierPath(roundedRect: bounds.insetBy(dx: 0.5, dy: 0.5),
                                xRadius: EP.radius, yRadius: EP.radius)
        // EP 输入框观感：常态实底 + border-color 描边，聚焦/录制时换主色浅底 + 主色描边。
        let fill = recording ? EP.dyn(EP.rgb(0xECF5FF), EP.mix(EP.rgb(0x1D1E1F), EP.rgb(0x409EFF), 0.16))
                             : EP.dyn(EP.rgb(0xFFFFFF), EP.rgb(0x1D1E1F))
        fill.setFill()
        path.fill()
        (recording ? EP.rgb(0x409EFF) : EP.dyn(EP.rgb(0xDCDFE6), EP.rgb(0x4C4D4F))).setStroke()
        path.lineWidth = 1
        path.stroke()
        let text = recording ? "按下组合键…" : (combo.map(KeyDisplay.describe) ?? "未设置")
        let attrs: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: 11, weight: .medium),
            .foregroundColor: (combo == nil && !recording) ? NSColor.secondaryLabelColor : NSColor.labelColor,
        ]
        let s = NSAttributedString(string: text, attributes: attrs)
        let sz = s.size()
        s.draw(at: CGPoint(x: (bounds.width - sz.width) / 2, y: (bounds.height - sz.height) / 2))
    }
}

/// keyCode + 修饰键 → 可读串（Apple 虚拟键码 ANSI 布局，覆盖常用键；未知回退「键N」）。
enum KeyDisplay {
    static func describe(_ c: KeyCombo) -> String {
        let m = NSEvent.ModifierFlags(rawValue: c.modifiers)
        var str = ""
        if m.contains(.control) { str += "⌃" }
        if m.contains(.option) { str += "⌥" }
        if m.contains(.shift) { str += "⇧" }
        if m.contains(.command) { str += "⌘" }
        str += keyName(c.keyCode)
        return str
    }

    static func keyName(_ code: UInt16) -> String {
        map[Int(code)] ?? "键\(code)"
    }

    private static let map: [Int: String] = [
        0: "A", 1: "S", 2: "D", 3: "F", 4: "H", 5: "G", 6: "Z", 7: "X", 8: "C", 9: "V",
        11: "B", 12: "Q", 13: "W", 14: "E", 15: "R", 16: "Y", 17: "T",
        18: "1", 19: "2", 20: "3", 21: "4", 22: "6", 23: "5", 24: "=", 25: "9", 26: "7",
        27: "-", 28: "8", 29: "0", 30: "]", 31: "O", 32: "U", 33: "[", 34: "I", 35: "P",
        36: "↩", 37: "L", 38: "J", 39: "'", 40: "K", 41: ";", 42: "\\", 43: ",", 44: "/",
        45: "N", 46: "M", 47: ".", 48: "⇥", 49: "Space", 51: "⌫", 53: "⎋",
        96: "F5", 97: "F6", 98: "F7", 99: "F3", 100: "F8", 101: "F9", 103: "F11",
        109: "F10", 111: "F12", 118: "F4", 120: "F2", 122: "F1",
        123: "←", 124: "→", 125: "↓", 126: "↑",
    ]
}
