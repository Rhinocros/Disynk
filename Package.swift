// swift-tools-version: 5.10
// Disynk —— macOS 多屏录制与截图应用
//
// 工程结构说明（对应 docs/ARCHITECTURE.md 第五节）：
//   每个 DK* 目录即一个逻辑模块，模块间依赖单向、可独立测试。
//   语言模式采用 Swift 5 + Sendable 友好的写法：Apple 的 delegate 型 API
//   （SCStreamOutputDelegate 等）尚未全面 Sendable 化，Swift 6 严格模式会把
//   平台回调写成大量 @preconcurrency 噪音；并发安全通过 actor 隔离实现。
//   （此为对批准方案的一处工程性微调，已在验收报告中说明。）

import PackageDescription

let package = Package(
    name: "Disynk",
    platforms: [
        .macOS(.v15)
    ],
    products: [
        .executable(name: "Disynk", targets: ["DisynkApp"]),
        .library(name: "DKCore", targets: ["DKCore"]),
        .library(name: "DKSettings", targets: ["DKSettings"]),
        .library(name: "DKEncode", targets: ["DKEncode"]),
        .library(name: "DKMux", targets: ["DKMux"]),
        .library(name: "DKCapture", targets: ["DKCapture"]),
        .library(name: "DKCompose", targets: ["DKCompose"]),
        .library(name: "DKAudio", targets: ["DKAudio"]),
        .library(name: "DKShot", targets: ["DKShot"]),
        .library(name: "DKOverlay", targets: ["DKOverlay"]),
        .library(name: "DKExport", targets: ["DKExport"]),
        .library(name: "DKVirtualDisplay", targets: ["DKVirtualDisplay", "DVKObjC"]),
    ],
    dependencies: [
        // 零第三方依赖：全部能力基于 Apple 系统框架（方案第一节）
    ],
    targets: [
        // MARK: 基础层
        .target(name: "DKCore"),
        .target(name: "DKSettings", dependencies: ["DKCore"]),

        // MARK: 录制管线
        .target(name: "DKEncode", dependencies: ["DKCore"]),
        .target(name: "DKMux", dependencies: ["DKCore", "DKEncode"]),
        .target(name: "DKCapture", dependencies: ["DKCore", "DKSettings"]),
        .target(name: "DKCompose", dependencies: ["DKCore"]),
        .target(name: "DKAudio", dependencies: ["DKCore", "DKSettings"]),

        // MARK: 截图 / 覆盖层 / 导出
        .target(name: "DKShot", dependencies: ["DKCore", "DKCapture", "DKSettings"]),
        .target(name: "DKOverlay", dependencies: ["DKCore", "DKSettings"]),
        .target(name: "DKExport", dependencies: ["DKCore", "DKMux"]),

        // MARK: 虚拟屏（ObjC 私有 API 桥接）
        .target(
            name: "DVKObjC",
            path: "Sources/DVKObjC",
            publicHeadersPath: "include",
            linkerSettings: [.linkedFramework("CoreGraphics"), .linkedFramework("IOKit")]
        ),
        .target(name: "DKVirtualDisplay", dependencies: ["DVKObjC", "DKCore"]),

        // MARK: App 壳
        .executableTarget(
            name: "DisynkApp",
            dependencies: [
                "DKCore", "DKSettings", "DKCapture", "DKEncode", "DKMux",
                "DKCompose", "DKAudio", "DKShot", "DKOverlay", "DKExport",
                "DKVirtualDisplay",
            ],
            path: "Sources/DisynkApp",
        ),

        // MARK: 测试
        // 轻量断言 harness（本环境 CLT 缺 XCTest framework，Tests/DKTests 为可执行目标，
        // 由 Scripts/test.sh 编译并运行；CLT 修复后可迁移为 XCTest 断言）
        .executableTarget(
            name: "DKTests",
            dependencies: [
                "DKCore", "DKSettings", "DKEncode", "DKMux", "DKCapture",
                "DKCompose", "DKAudio", "DKShot", "DKOverlay", "DKExport",
                "DKVirtualDisplay",
            ],
            path: "Tests/DKTests"
        ),
        // 占位 XCTest 目标（对应方案第七节“每模块附单元测试”；待 CLT 修复后填充用例）
        .testTarget(name: "DKCoreTests", dependencies: ["DKCore"]),
        .testTarget(name: "DKSettingsTests", dependencies: ["DKSettings"]),
        .testTarget(name: "DKMuxTests", dependencies: ["DKMux"]),
        .testTarget(name: "DKComposeTests", dependencies: ["DKCompose"]),
        ],
    swiftLanguageVersions: [.v5]
)
