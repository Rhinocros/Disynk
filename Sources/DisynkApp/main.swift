import AppKit

// Disynk 入口：常规 App 壳（swiftc 直编无 @main，手动装配；顶层代码运行于主线程）
// 采用 .regular 激活策略：显示 Dock 图标、⌘Tab 可切换、带标准 App 菜单（含 ⌘Q 退出）；
// 同时保留状态栏（菜单项）常驻（见 AppDelegate.setupStatusItem）。
MainActor.assumeIsolated {
    let app = NSApplication.shared
    let delegate = AppDelegate()
    app.delegate = delegate
    app.setActivationPolicy(.regular)   // Dock 图标 + ⌘Tab + 退出；关闭主窗口不退出
    app.run()
}
