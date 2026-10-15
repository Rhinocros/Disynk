import AppKit
import DKCapture
import DKCore
import DKSettings
import SwiftUI

/// App 壳：菜单栏常驻（.regular + 状态栏）+ 全局快捷键 + 主窗口/录制面板调度。
/// 状态栏菜单参考 CleanShot：图标+文字一行一功能，分隔条分组，子菜单带当前选中勾选。
@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate {
    let model = AppModel.shared
    private var statusItem: NSStatusItem?
    private var hotMonitor: Any?
    private var localMonitor: Any?

    func applicationDidFinishLaunching(_ notification: Notification) {
        WebMLibvpxAssembler.install()   // 有 libvpx 时装配 WebM codecFactory（默认无操作）
        setupMainMenu()                 // 标准 App 菜单（⌘Q 退出 / 编辑菜单供文本框复制粘贴）
        setupStatusItem()
        setupGlobalHotkey()
        Task { await model.bootstrap() }
        // 首次运行：先弹「权限说明 + 引导」，完成屏幕录制 + 辅助功能授权后才进入使用（麦克风可跳过）。
        // 非首次运行：保留旧兜底——无录屏权限时打开主窗口引导。
        if !OnboardingController.shared.presentIfNeeded(model: model) {
            if !ScreenPermissions.hasScreenRecording() {
                MainWindowController.show(model: model)
            }
        }
    }

    /// 关闭主窗口不退出 App（仍保留 Dock 图标 + 状态栏常驻），重开可经 Dock/状态栏。
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }

    /// 点击 Dock 图标（窗口已全部关闭）重新打开主窗口。
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        if !flag { MainWindowController.show(model: model) }
        return true
    }

    func applicationWillTerminate(_ notification: Notification) {
        if let hotMonitor { NSEvent.removeMonitor(hotMonitor) }
        if let localMonitor { NSEvent.removeMonitor(localMonitor) }
        if model.isRecording { model.stopRecording() }
    }

    // MARK: 标准主菜单（.regular 策略下必需：提供 ⌘Q 退出、⌘C/⌘V 编辑、⌘H 隐藏等）

    private func setupMainMenu() {
        let mainMenu = NSMenu()

        // App 菜单（首项自动作为应用菜单）
        let appItem = NSMenuItem()
        mainMenu.addItem(appItem)
        let appMenu = NSMenu()
        appItem.submenu = appMenu
        appMenu.addItem(iconItem("关于 Disynk", "info.circle", #selector(showAbout), key: "", mask: []))
        appMenu.addItem(.separator())
        let hide = appMenu.addItem(withTitle: "隐藏 Disynk",
                                   action: #selector(NSApplication.hide(_:)), keyEquivalent: "h")
        hide.keyEquivalentModifierMask = [.command]
        appMenu.addItem(.separator())
        let quit = appMenu.addItem(withTitle: "退出 Disynk",
                                   action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        quit.keyEquivalentModifierMask = [.command]

        // 编辑菜单（数值输入框 / OCR 文本框的剪切复制粘贴全选依赖此菜单）
        let editItem = NSMenuItem()
        mainMenu.addItem(editItem)
        let editMenu = NSMenu(title: "编辑")
        editItem.submenu = editMenu
        editMenu.addItem(withTitle: "撤销", action: Selector(("undo:")), keyEquivalent: "z")
        editMenu.addItem(withTitle: "重做", action: Selector(("redo:")), keyEquivalent: "Z")
        editMenu.addItem(.separator())
        editMenu.addItem(withTitle: "剪切", action: #selector(NSText.cut(_:)), keyEquivalent: "x")
        editMenu.addItem(withTitle: "复制", action: #selector(NSText.copy(_:)), keyEquivalent: "c")
        editMenu.addItem(withTitle: "粘贴", action: #selector(NSText.paste(_:)), keyEquivalent: "v")
        editMenu.addItem(withTitle: "全选", action: #selector(NSText.selectAll(_:)), keyEquivalent: "a")

        // 窗口菜单
        let windowItem = NSMenuItem()
        mainMenu.addItem(windowItem)
        let windowMenu = NSMenu(title: "窗口")
        windowItem.submenu = windowMenu
        windowMenu.addItem(withTitle: "最小化", action: #selector(NSWindow.performMiniaturize(_:)), keyEquivalent: "m")
        windowMenu.addItem(withTitle: "关闭", action: #selector(NSWindow.performClose(_:)), keyEquivalent: "w")
        NSApp.windowsMenu = windowMenu

        NSApp.mainMenu = mainMenu
    }

    // MARK: 菜单栏（参考 CleanShot 图 1：图标+文字快捷菜单）

    /// 动态刷新项：打开菜单时同步勾选态/录制中文案
    private var formatItems: [NSMenuItem] = []
    private var sourceItems: [NSMenuItem] = []
    private var delayItems: [NSMenuItem] = []
    private var desktopIconsItem: NSMenuItem?
    private var recordToggleItem: NSMenuItem?

    private func setupStatusItem() {
        // 用 variableLength：logo 菜单栏图为 22×16 非方形，按宽高比缩放后宽约 25pt，squareLength 会裁掉两侧。
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        item.button?.image = menuBarTemplateImage()
        let menu = NSMenu()
        menu.delegate = self

        // 顶部：入口
        menu.addItem(iconItem("录制面板…", "dot.circle.viewfinder", #selector(showPanel), key: "", mask: []))
        menu.addItem(iconItem("截图面板…", "camera.viewfinder", #selector(showShotPanel), key: "", mask: []))
        menu.addItem(iconItem("设置…", "gearshape", #selector(openMain), key: ",", mask: [.command]))
        menu.addItem(.separator())

        // 录制组（一行一功能 + 格式/来源子菜单）
        let rec = iconItem("录制屏幕", "record.circle", #selector(toggleRecording), key: "r", mask: [.command, .shift])
        recordToggleItem = rec
        menu.addItem(rec)
        let fmtHost = submenu("输出格式", items: [
            ("视频", "video", #selector(pickFormat(_:)), 0),
            ("WebM", "globe", #selector(pickFormat(_:)), 1),
            ("GIF", "film", #selector(pickFormat(_:)), 2),
        ])
        formatItems = fmtHost.submenu?.items ?? []
        menu.addItem(fmtHost)
        let srcHost = submenu("录制来源", items: [
            ("全屏", "display", #selector(pickSource(_:)), 0),
            ("窗口", "macwindow", #selector(pickSource(_:)), 1),
            ("范围", "rectangle.dashed", #selector(pickSource(_:)), 2),
        ])
        sourceItems = srcHost.submenu?.items ?? []
        menu.addItem(srcHost)
        // 延迟录制：无/3/5/10 秒（tag 即秒数）
        let delayHost = submenu("延迟录制", items: [
            ("无", "clock", #selector(pickDelay(_:)), 0),
            ("3 秒", "clock", #selector(pickDelay(_:)), 3),
            ("5 秒", "clock", #selector(pickDelay(_:)), 5),
            ("10 秒", "clock", #selector(pickDelay(_:)), 10),
        ])
        delayItems = delayHost.submenu?.items ?? []
        menu.addItem(delayHost)
        menu.addItem(.separator())

        // 桌面图标显隐（单切换项；标题在 menuNeedsUpdate 根据实际状态刷新）
        let desk = iconItem("隐藏桌面图标", "menubar.dock.rectangle", #selector(toggleDesktopIcons), key: "", mask: [])
        desktopIconsItem = desk
        menu.addItem(desk)
        menu.addItem(.separator())

        // 截图/OCR 已收入「截图面板」（顶部入口），不再平铺到主菜单

        // 虚拟屏组
        menu.addItem(submenu("虚拟屏", items: [
            ("创建 1080p", "display", #selector(virtualFHD), -1),
            ("创建 2K", "display", #selector(virtual2K), -1),
            ("创建 4K", "display", #selector(virtual4K), -1),
            ("全部移除", "trash", #selector(virtualDestroy), -1),
        ]))
        menu.addItem(.separator())

        // 辅助/系统
        menu.addItem(iconItem("摄像头小窗", "web.camera", #selector(toggleCamera), key: "", mask: []))
        menu.addItem(iconItem("打开输出目录", "folder", #selector(openOutputDir), key: "", mask: []))
        menu.addItem(iconItem("关于 Disynk…", "info.circle", #selector(showAbout), key: "", mask: []))
        menu.addItem(.separator())
        // 退出项：不能把 target 强制设为 self（AppDelegate 不实现 terminate: → 该项被禁用），
        // 显式指向 NSApp，令其始终可点击。
        let quit = NSMenuItem(title: "退出 Disynk", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        quit.keyEquivalentModifierMask = [.command]
        quit.target = NSApplication.shared
        menu.addItem(quit)
        item.menu = menu
        statusItem = item
    }

    /// 子菜单项 tag 即对应枚举 allCases 下标（-1 不参与勾选）。
    private func submenu(_ title: String, items: [(String, String, Selector, Int)]) -> NSMenuItem {
        let host = NSMenuItem(title: title, action: nil, keyEquivalent: "")
        let sub = NSMenu(title: title)
        for (name, sym, sel, tag) in items {
            let it = NSMenuItem(title: name, action: sel, keyEquivalent: "")
            it.target = self
            it.tag = tag
            it.image = symbol(sym)
            sub.addItem(it)
        }
        host.submenu = sub
        return host
    }

    private func iconItem(_ title: String, _ symbolName: String, _ action: Selector,
                          key: String, mask: NSEvent.ModifierFlags) -> NSMenuItem {
        let it = NSMenuItem(title: title, action: action, keyEquivalent: key)
        it.keyEquivalentModifierMask = mask
        it.target = self
        it.image = symbol(symbolName)
        return it
    }

    private func symbol(_ name: String) -> NSImage? {
        let img = NSImage(systemSymbolName: name, accessibilityDescription: nil)
        img?.isTemplate = true
        return img
    }

    /// 菜单栏单色图标：与彩色 App 图标主元素同形状（由 Scripts/make_icon.swift 生成）。
    /// 找不到资源时回退 SF Symbol，保证菜单栏不会出现空白。
    private func menuBarTemplateImage() -> NSImage? {
        // 优先按名加载（打包 .app 内自动合并 @2x 高分表征）。
        var img = NSImage(named: NSImage.Name("MenuBarIcon"))
        // 回退：直接跑 build.sh 产出的裸可执行 .build/Disynk 时，Bundle 里没有资源，
        // 逐级向上在源树里找 Resources/MenuBarIcon.png 与 logo/menubar/MenuBarIcon.png，
        // 避免静默回退成 record.circle（那会比 logo 标志大且不是本意）。
        if img == nil {
            for url in Self.menuBarIconCandidates() where FileManager.default.fileExists(atPath: url.path) {
                img = NSImage(contentsOf: url); break
            }
        }
        if let img {
            // 按图片真实宽高比缩放（logo 版为 22×16 非方形），固定高 13pt：
            // 该标志为实心块填满画布，无内边距，视觉比带内边距的邻图标重，故取明显小于常规 18pt。
            let s = img.size
            let aspect = s.height > 0 ? s.width / s.height : 1
            img.size = NSSize(width: (13 * aspect).rounded(), height: 13)
            img.isTemplate = true
            return img
        }
        return symbol("record.circle")
    }

    /// 菜单栏 template 图候选路径：bundle → 可执行文件目录逐级向上 → 当前工作目录，
    /// 每个基准分别试裸名、Resources/、logo/menubar/ 三种布局。
    private static func menuBarIconCandidates() -> [URL] {
        let fm = FileManager.default
        var bases: [URL] = []
        if let res = Bundle.main.resourceURL { bases.append(res) }
        bases.append(Bundle.main.bundleURL)
        for exePath in [Bundle.main.executableURL?.path, CommandLine.arguments.first] {
            guard let exePath else { continue }
            var dir = URL(fileURLWithPath: exePath).standardized.deletingLastPathComponent()
            for _ in 0..<4 { bases.append(dir); dir = dir.deletingLastPathComponent() }
        }
        bases.append(URL(fileURLWithPath: fm.currentDirectoryPath))
        var urls: [URL] = []
        for b in bases {
            urls.append(b.appendingPathComponent("MenuBarIcon.png"))
            urls.append(b.appendingPathComponent("Resources/MenuBarIcon.png"))
            urls.append(b.appendingPathComponent("logo/menubar/MenuBarIcon_Full.png"))
        }
        return urls
    }

    // 打开菜单时同步勾选态与录制中文案（图 1 的「当前态」体验）

    func menuNeedsUpdate(_ menu: NSMenu) {
        let fmt = AppModel.shared.snapshot.recording.outputFormat
        for it in formatItems { it.state = it.tag == RecordOutputFormat.allCases.firstIndex(of: fmt) ?? -1 ? .on : .off }
        let src = AppModel.shared.recordSource
        for it in sourceItems { it.state = it.tag == AppModel.RecordSourceKind.allCases.firstIndex(of: src) ?? -1 ? .on : .off }
        let delay = AppModel.shared.snapshot.recording.recordDelaySeconds
        for it in delayItems { it.state = it.tag == delay ? .on : .off }
        recordToggleItem?.title = AppModel.shared.isRecording ? "停止录制" : "录制屏幕"
        recordToggleItem?.image = symbol(AppModel.shared.isRecording ? "stop.circle.fill" : "record.circle")
        let hidden = DesktopIcons.isHidden()
        desktopIconsItem?.title = hidden ? "显示桌面图标" : "隐藏桌面图标"
        desktopIconsItem?.image = symbol(hidden ? "macwindow.on.rectangle" : "menubar.dock.rectangle")
    }

    @objc private func pickDelay(_ sender: NSMenuItem) {
        let s = max(0, sender.tag)
        model.mutateSettings { $0.recording.recordDelaySeconds = s }
    }

    @objc private func toggleDesktopIcons() {
        let nowHidden = DesktopIcons.toggle()
        model.statusLine = nowHidden ? "已隐藏桌面图标" : "已显示桌面图标"
    }

    @objc private func pickFormat(_ sender: NSMenuItem) {
        let all = RecordOutputFormat.allCases
        guard sender.tag >= 0, sender.tag < all.count else { return }
        let f = all[sender.tag]
        model.mutateSettings { $0.recording.outputFormat = f }
    }
    @objc private func pickSource(_ sender: NSMenuItem) {
        let all = AppModel.RecordSourceKind.allCases
        guard sender.tag >= 0, sender.tag < all.count else { return }
        let s = all[sender.tag]
        model.recordSource = s
        if s == .window, model.recordableWindows.isEmpty { model.refreshRecordableWindows() }
    }
    @objc private func showPanel() { RecordingPanelController.shared.toggle(model: model) }
    @objc private func showShotPanel() { ScreenshotPanelController.shared.toggle(model: model) }
    /// 关于页：复用主窗口（直跳到「关于」分区），避免两套版本/协议 UI 失同步。
    @objc private func showAbout() { MainWindowController.show(model: model, section: .about) }
    @objc private func virtualFHD() { model.createVirtualDisplay(preset: .fullHD) }
    @objc private func virtual2K() { model.createVirtualDisplay(preset: .retina2K) }
    @objc private func virtual4K() { model.createVirtualDisplay(preset: .fourK) }
    @objc private func virtualDestroy() { model.destroyAllVirtualDisplays() }

    /// 全局/本地快捷键：按 settings.shortcuts 匹配（辅助功能权限；需辅助功能才能全局）。
    /// 未配置任何快捷键时保留旧默认 ⌘⇧R = 开始/停止录制。
    private func setupGlobalHotkey() {
        hotMonitor = NSEvent.addGlobalMonitorForEvents(matching: .keyDown) { [weak self] event in
            let code = event.keyCode
            let mods = event.modifierFlags.intersection([.command, .shift, .control, .option]).rawValue
            Task { @MainActor in self?.handleHotkey(keyCode: code, modifiers: mods) }
        }
        // 本地监听：本应用处于前台时也能触发（回调在主线程运行）
        localMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard let self else { return event }
            let code = event.keyCode
            let mods = event.modifierFlags.intersection([.command, .shift, .control, .option]).rawValue
            if let action = self.matchAction(keyCode: code, modifiers: mods) {
                self.dispatch(action)
                return nil    // 吞掉事件，避免同时触发默认行为
            }
            return event
        }
    }

    @MainActor
    private func handleHotkey(keyCode: UInt16, modifiers: UInt) {
        if let action = matchAction(keyCode: keyCode, modifiers: modifiers) { dispatch(action) }
    }

    @MainActor
    private func matchAction(keyCode: UInt16, modifiers: UInt) -> ShortcutAction? {
        let mods = NSEvent.ModifierFlags(rawValue: modifiers).intersection([.command, .shift, .control, .option])
        for (action, combo) in model.snapshot.shortcuts where combo.keyCode == keyCode {
            let cm = NSEvent.ModifierFlags(rawValue: combo.modifiers).intersection([.command, .shift, .control, .option])
            if cm == mods { return action }
        }
        // 旧默认：⌘⇧R 未占用且无任何自定义时仍作为录制开关
        if model.snapshot.shortcuts.isEmpty, keyCode == 15, mods == [.command, .shift] { return .record }
        return nil
    }

    @MainActor
    private func dispatch(_ action: ShortcutAction) {
        switch action {
        case .openShotPanel: showShotPanel()
        case .openRecordPanel: showPanel()
        case .record: model.toggleRecording()
        case .recordVideo: model.startRecording(format: .video)
        case .recordGIF: model.startRecording(format: .gif)
        case .recordWebM: model.startRecording(format: .webm)
        case .shotFull: model.screenshotAndOCR(displayID: nil)
        case .shotRegion: model.screenshotRegionAndOCR()
        case .shotWindow: model.screenshotWindowAndOCR()
        case .toggleDesktopIcons: toggleDesktopIcons()
        }
    }

    @objc private func openMain() { MainWindowController.show(model: model) }
    @objc private func toggleRecording() { model.toggleRecording() }
    @objc private func toggleCamera() { CameraWindowController.shared.toggle() }
    @objc private func openOutputDir() {
        NSWorkspace.shared.open(URL(fileURLWithPath: model.snapshot.outputDirectoryPath))
    }
}
