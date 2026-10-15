import DKExport
import Foundation

/// libvpx（VP8/VP9 软编）装配入口——保留旧调用点，实体实现已迁至 DKExport/LibVPXBridge.swift
/// 迁移原因：让 DKTests 能链接 DKExport 后直接跑真实 VP8 编码集成测试（`vpx-verify`）。
/// 默认构建：DKExport 未编译 libvpx 分支 → install() 走空实现，导出 WebM 时显式报「未装配」。
/// 装配构建：`DISYNK_WITH_LIBVPX=1` 触发 DKExport 编译真实桥，install() 注入 factory。
enum WebMLibvpxAssembler {
    static func install() { WebMExporter.installLibVPXCodec() }
}
