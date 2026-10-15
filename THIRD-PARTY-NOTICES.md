# Third-party notices / 第三方组件声明

Disynk 自身代码以 GPL-3.0-or-later 发布（见 [LICENSE](LICENSE) 与 [ADDITIONAL-TERMS.md](ADDITIONAL-TERMS.md)）。本文件记录仓库或产物里出现的第三方组件。

注意：GPL 的传染性不适用于 libvpx 自身的上游代码，但把 libvpx 与本程序一起再分发时，必须同时满足两边的条款（GPL-3.0 与 BSD-3-Clause 兼容）。

## libvpx —— BSD-3-Clause

| | |
| --- | --- |
| 用途 | WebM / VP8·VP9 软编码，可选装配 |
| 版本 | v1.15.2（`Scripts/build_libvpx.sh` 的 `LIBVPX_VERSION` 默认值） |
| 上游 | <https://github.com/webmproject/libvpx>（镜像：<https://chromium.googlesource.com/webm/libvpx>） |
| 许可原文 | <https://github.com/webmproject/libvpx/blob/v1.15.2/LICENSE> |
| 接入方式 | 仓库内只保留手写 ABI 头 `Scripts/vendor/libvpx/include/libvpx_shim.h` 与 `module.modulemap`；`libvpx.11.dylib` 由 `.gitignore` 排除，构建产物路径 `Scripts/vendor/libvpx/lib/libvpx.11.dylib` |
| 装配开关 | 存在该 dylib 时 `Scripts/package.sh` 自动启用 `DISYNK_WITH_LIBVPX=1`，把 dylib 拷进 `Disynk.app/Contents/Frameworks`（install-name 为 `@rpath/libvpx.11.dylib`），并先签 dylib 再签 app |
| 未装配时 | `WebMExporter.codecFactory` 保持 `nil`，WebM 产出不可用；其它功能不受影响 |

BSD-3-Clause 要求分发二进制时保留版权与许可原文。`Scripts/build_libvpx.sh` 会把上游 `LICENSE`
复制到 `Scripts/vendor/libvpx/LICENSE`，CI 再将其随 DMG 一并上传为 Release 附件
（`LICENSE-libvpx.txt`）。正式商用前请核对随包许可文本的完整性。

VP8/VP9 另涉 Google 的免版税专利授权条款（libvpx 页面所述 WebM Patent License），专利授权
独立于 BSD 版权许可；商用分发前请自行确认适用范围。

## Apple 系统框架

ScreenCaptureKit、VideoToolbox、AVFoundation、Vision、CoreImage、Metal、CoreGraphics、IOKit、
AppKit、SwiftUI 随 macOS 提供，受 Apple 系统软件许可条款约束；SF Symbols 按 Apple 使用条款用于界面图标。
虚拟屏使用的 `CGVirtualDisplay` 属 macOS 私有接口，不构成分发第三方代码。

## 构建期工具（不进入产物）

- GitHub Actions macOS runner 镜像（`macos-15`）提供的 Xcode / Command Line Tools / clang / make。
- `Scripts/verify_media.py`：测试链里用 PyAV / ffmpeg 第三方解码复核产出文件，仅本地与 CI 运行，
  不随 app 分发。

## 无第三方 Swift 依赖

`Package.swift` 的 `dependencies` 为空——除上述 libvpx 外，项目不链接任何第三方包。
