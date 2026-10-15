# libvpx 装配（WebM VP8/VP9 编码）

本目录是 WebM 导出的外部依赖，现已**实装配**：Swift 端 `DKExport/LibVPXBridge` 直连真实
`vpx_codec_enc_init_ver / vpx_codec_encode / vpx_codec_get_cx_data / vpx_codec_destroy`，
产出含关键帧起始码 `9D 01 2A` 的 VP8 码流（DKTests `webmLibVPXRealTest` 端到端验证）。

## 目录现状

```
include/
  libvpx_shim.h     ← 手写 ABI 正确的 libvpx v1.15.x 公共编码器 API 最小子集
                       （vpx_image / enc_cfg 504B / cx_pkt 136B / vpx_codec_ctx_t 等）
  module.modulemap  ← umbrella 指向 libvpx_shim.h → Swift `import LibVPX` 生效
lib/
  libvpx.11.dylib   ← libvpx v1.15.2 arm64 动态库，install-name 改为 @rpath/libvpx.11.dylib
```

`libvpx.11.dylib` 来自本机 Python cv2 wheel 自带副本（`/Library/Frameworks/Python.framework/.../cv2/.dylibs/libvpx.11.dylib`），
已用 `install_name_tool -id @rpath/libvpx.11.dylib` 改写；其余元数据未改动，
BSD+Patent 许可要求随源码分发时保留 LICENSE，正式商用前请核对上游 LICENSE 完整性。

## 构建 / 测试 / 打包开关

默认（无 libvpx 装配）：
```
zsh Scripts/build.sh           # WebMExporter.codecFactory 保持 nil
zsh Scripts/test.sh            # 43/43（WebM 假 codec 用例继续通过）
```

启用 libvpx（VP8/VP9 WebM 软编）：
```
DISYNK_WITH_LIBVPX=1 zsh Scripts/build.sh   # COMMON 加 -D DISYNK_LIBVPX + LibVPX modulemap；
                                            # 可执行链入 dylib 并附两条 rpath
DISYNK_WITH_LIBVPX=1 zsh Scripts/test.sh    # 49/49（真实 VP8 编码 6 项断言加入）
DISYNK_WITH_LIBVPX=1 zsh Scripts/package.sh # dylib 拷入 .app/Contents/Frameworks，
                                            # 先内后外 codesign 再签 app
```

## ABI 备注

- `VPX_ENCODER_ABI_VERSION = 18 + VPX_CODEC_ABI_VERSION(9) + VPX_EXT_RATECTRL_ABI_VERSION(10) = 37`。
  libvpx 上游宏定义依赖 `vpx_ext_ratectrl.h`；Swift 无法导入 C 宏 → 桥接层直接给
  `vpx_codec_enc_init_ver` 传字面量 37（本机 dylib 实测接受）。
- 变参 `vpx_codec_control(...)`（如 VP8E_SET_CQ_LEVEL）Swift 不可导入；本桥接采用
  `VPX_VBR + rc_target_bitrate`（由 crf 反推码率）而非 VPX_Q/cq_level，规避变参需求。

## 已知代价

- dylib 依赖 `/usr/lib/libc++.1.dylib` 与 `/usr/lib/libSystem.B.dylib`（系统自带，无需 bundle）。
- Intel Mac 部署需另配 x86_64/arm64 通用切片；`lipo -info` 检查。
- ad-hoc 签名（路径 A）每次重编 cdhash 变化 → 用户需重新授予 TCC 权限；路径 B Developer ID 保持授权。
