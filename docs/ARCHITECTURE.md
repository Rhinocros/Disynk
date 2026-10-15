# Disynk 架构文档

macOS 多屏录制与截图应用。本文为仓库内架构沉淀（对应技术方案第五节），
与代码同步演进；方案原文见批准的计划文档。

## 1. 技术栈总览

| 层 | 选型 |
|---|---|
| 语言 / UI | Swift 5.10（Sendable 友好写法 + actor 隔离）/ SwiftUI + AppKit 桥接 |
| 捕获 | ScreenCaptureKit（部署目标 macOS 14+），每屏一路独立 `SCStream` |
| 编码 | VideoToolbox 硬编（H.264 / HEVC / ProRes 422） |
| 封装 | `RecordingMuxer` 协议双后端：AVAssetWriter（MP4/MOV）+ 内置 EBML writer（MKV） |
| 多屏合成 | Metal 实时合成（运行时 `makeLibrary(source:)` 编译 MSL）+ CGContext CPU 回退 |
| 音频 | SCK 系统声 + AVAudioEngine 麦克风（均 48kHz 立体声 Float32）；MP4/MOV 由 AVAssetWriter 转 AAC，MKV 由内置 AACStreamEncoder 转 AAC |
| 截图 / OCR | SCScreenshotManager 单帧抓图 + Vision `VNRecognizeTextRequest`（中英离线） |
| 覆盖层 | CGEventTap（辅助功能权限，listenOnly）+ 透明 NSPanel（涟漪 / 快捷键横幅） |
| 导出 | GIF：AVAssetReader 抽帧 + CGImageDestination；WebM：捆绑 libvpx v1.15 dylib + vpx_codec_enc_init_ver 真实 VP8/VP9 编码 + EBML 封装 |
| 虚拟屏 | `CGVirtualDisplay` 私有 API（ObjC 运行时桥接 DVKObjC，防御性探测降级） |

## 2. 模块拓扑（Sources/，依赖单向）

```
DVKObjC ─┐                    （ObjC 桥接：CGVirtualDisplay 私有类）
DKCore ──┬─ DKSettings ──┬─ DKCapture ─── DKShot
         ├─ DKEncode ─── DKMux ────────── DKExport
         ├─ DKCompose
         ├─ DKAudio
         ├─ DKOverlay
         └─ DKVirtualDisplay
DisynkApp = 全部模块 + RecordingEngine 管线整合 + SwiftUI 界面
```

- **DKCore**：PixelSize / ResolutionMode（预设+自定义，长宽比取框）/ FrameRate（30/60/自定义，≤刷新率）/ OutputMode / QualityTier 码率估算 / `EncodeCapacity`（§四 并发编码会话数估算 + 硬编上限/ProRes 软编建议的单一真相，UI 与引擎共用，可离线单测）/ DisplaySnapshot / DKError / DKLog（os.log 分 category）。
- **DKCapture**：`DisplayCapture` 每屏一路 SCStream（NV12 零拷贝直入编码器；合并模式切 BGRA；queueDepth=3；SCFrameStatus 掉帧统计）；`CaptureCoordinator` actor 并发启停；`DisplayEnumerator` 物理+虚拟屏枚举；`ScreenPermissions` TCC 引导。帧率按源屏刷新率钳制（§四）已抽为纯函数 `DisplayCapture.clampedFPS(requested:refreshHz:)`（上限 `刷新率-0.5`、不低于 1fps），可离线单测（`captureClampTest`）。覆盖层「入画/不入画」（§三独立开关、§七关闭时不入画）的排除窗口决策亦抽为纯函数 `DisplayCapture.overlayExcludedWindowIDs(included:panelWindowID:)`（入画→空集；不入画且面板窗口 ID 有效→排除该面板；面板未创建/无效 ID→空集），作为 AppModel 单一真相（取代内联 if/insert）并可离线单测（`overlayExclusionTest`）。`ScreenPermissions` 提供 M7 路径 A「引导重新授权」纯逻辑：`tccutilService(for:)`（ScreenCapture/Microphone/Accessibility 映射）+ `reauthorizationHint(bundleID:pane:)`（拼 `tccutil reset …`，空/空白 bundleID 回退全量重置无尾随空格）+ `isGranted`/`openPrivacyPane`，可离线单测（`permissionsReauthTest`）。
- **DKEncode**：`HardwareEncoder` VT 会话封装（码率/GOP/Profile/Reorder 属性，像素格式回退链，输出回调第 1 参为 outputCallbackRefCon）；`ParameterSets` 提取 SPS/PPS 供 MKV CodecPrivate。
- **DKMux**：`RecordingMuxer` 协议 + `MuxerFactory`；`AssetWriterMuxer`（passthrough 需 `sourceFormatHint`，音轨喂 PCM 自动 AAC）；`MKVMuxer` 纯 Swift EBML writer（`EBML.swift` 原语）；`AACStreamEncoder`（AudioConverter 回调式 PCM→AAC，产出 A_AAC 音轨 + AudioSpecificConfig CodecPrivate，新建会话 cookie 未就绪时回退为确定性合成）。
- **DKCompose**：`ComposeLayout` 归一化摆放模型（horizontal/vertical/mixedGrid 预设、move/resize 钳制、8K 宽兜底）+ `MetalCompositor`（MSL 全屏三角形按 placement 设 viewport+scissor 采样定位、避免重叠屏互覆；输入须为 Metal 兼容缓冲即 SCStream 的 IOSurface 输出；`CVMetalTexture` 盒在 GPU 完成前保持存活以免纹理 backing 失效；池化 BGRA 输出；失败自动 CPU 回退，并可经 `MetalCompositor(layout:forceCPUFallback:)` 显式强制走 CG 路径以离线单测回退像素一致性（`composeMergeTest` 断言 CPU 回退左右半屏颜色/尺寸与 Metal 等价））+ `ComposeGate`（“凑齐一帧”对齐门：仅跟踪每屏最新帧 PTS/消费标志、不持像素缓冲的纯逻辑；`isReady` 要求所有期望屏都有未消费新帧、`mergedPTS` 取各屏 PTS 最小值→实现 §七「≤一帧偏差」对齐；可离线单测 `composeGateTest`）。
- **DKAudio**：`MicCapturer`（AVAudioEngine tap → AVAudioConverter 48k Float32 → CMSampleBuffer）。
- **DKShot**：`Screenshotter` 全屏/窗口/区域抓图（`captureDisplay`/`captureWindow`/`captureRegion`）+ Vision OCR（accurate，zh-Hans/zh-Hant/en-US）+ 剪贴板 OCR + `writeText`（TXT 逐行 / Markdown 加标题分段）导出。`OCRResult`（公开构造器 + `text` 拼接）与 `writeText` 为纯文件逻辑，可离线单测（`shotExportTest`，TXT/MD round-trip）。
- **DKOverlay**：`OverlayController` CGEventTap（listenOnly，超时自动重挂，点击/组合键解析）+ `OverlayPanel` 穿透 NSPanel（涟漪圆环、快捷键横幅，Timer 60Hz 驱动）。组合键 → 展示串的解析已抽为与 `CGEvent` 解耦的纯函数 `comboString(flags:code:charFallback:)` / `mappedKeyName(code:)`（修饰键固定 ⌘⌃⌥⇧ 序 + 特殊键映射表 + 普通字符 unicode 回退大写），故可在无辅助功能权限的 CLI 环境单测（`overlayComboTest`，对齐 §七「每模块附单元测试」）。
- **DKExport**：`GIFExporter`（≤15fps、长边钳制、crop、进度、返回体积）；`WebMExporter` 抽帧(I420)+EBML 容器+`LibVPXBridge`（真实 vpx_codec_enc_init_ver 会话）——开关 `DISYNK_WITH_LIBVPX=1` 时产出含关键帧 `9D 01 2A` 的真 VP8 码流（VP9 走 `vpx_codec_vp9_cx()` 同一路径，产 codecID=V_VP9）；默认不装配时导出显式报「未装配」。
- **DKVirtualDisplay**：`VirtualDisplayManager` actor（serial 幂等、运行时探测 `DVKVirtualDisplayAvailable`，不可用则 UI 降级）；`create(width:height:refreshHz:hiDPI:)` 支持自定义分辨率 + HiDPI（方案第三节；`retina2K/fourK` 预设默认开 HiDPI，`VirtualScreen.hiDPI` 回传）；`DVKObjC` 桥接经运行时探测调用私有 `CGVirtualDisplay*`，`hiDPI` 经 `setHiDPI:` respondsToSelector 防御式下发（详 §3.7）。§三「向虚拟屏拖放窗口」由 `WindowArranger` 落地：落点几何抽为纯函数 `place(windowSize:in:margin:)`（可见区内居中、超限钳制且完整留边、多屏含 origin 偏移，CG 左上坐标系）+ `globalFrame(ofDisplay:)`，可离线单测（`windowArrangerTest`）；真机移窗 `moveFocusedWindow(to:/toDisplay:)` 经 AX API（`AXUIElementCreateApplication` + `kAXFocusedWindow` 设 `kAXSize/kAXPosition`，`AXValueCreate(.cgSize/.cgPoint)`），gate 在 `AXIsProcessTrusted`（辅助功能权限，复用 PermissionTab），无权限抛 `DKError.windowAutomation`、无焦点窗口返回 false 优雅降级（AX 效果依赖真机 GUI，不入离线断言）。
- **DisynkApp**：`RecordingEngine`（separate/composedOnly/both 三模式路由；帧在单串行 routeQueue 分发；合并模式“凑齐一帧”对齐已抽为 DKCompose 纯逻辑 `ComposeGate`（isReady + 最小 PTS，≤ 1 帧偏差）可离线单测；帧率钳制复用 `DisplayCapture.clampedFPS` 单一真相；每输出文件一条 FIFO `DestPipeline` 保证 muxer append 保序）+ 菜单栏 / 主窗口 / 拖拽布局编辑器 / 浮动控制条 / 全局快捷键。截图页接入全屏/最前窗口/区域（`RegionCapture` 橡胶筋选择遮罩 + `FrontWindowResolver`）+ OCR 复制/导出 TXT·MD；录制页按 §四 显式提示并发编码会话数与 ProRes 软编上限（`VideoCodec.isHardwareAccelerated` + `OutputMode.displayName`），并暴露 §三 关键帧间隔/GOP 可调（`keyframeIntervalSeconds` Picker→编码器 MaxKeyFrameInterval）；虚拟屏页含自定义分辨率 + HiDPI 控件，以及每块已创建虚拟屏的「移入最前窗口」按钮（§三「向虚拟屏拖放窗口」→ `WindowArranger.moveFocusedWindow(toDisplay:)` 经 AX 居中移窗，需辅助功能权限）。新增「权限」页（`PermissionTab`，M7 路径 A）：实时展示屏幕录制/麦克风/辅助功能三项授予状态，每项附可复制的 `tccutil reset <service> <bundleID>` 重置命令与「打开系统设置面板」按钮（`openPrivacyPane` 直达对应隐私页签），补偿 ad-hoc 重编译 cdhash 变更导致的授权失效。

## 3. 关键工程决策与偏差

1. **MKV 用内置 EBML writer 替代 MediaIO**：MediaIO 为私有框架、无 SDK 支持；EBML 原语纯 Swift 实现，简单块 +时长修正，支持 H.264/HEVC 视频 + AAC 音轨（ProRes 除外）。
   • **已落地的关键 ID 修正**：`MkID` 中 CodecPrivate/DisplayWidth/DisplayHeight 曾错写为 `0x2586 81 / 0x55B0 / 0x55BA`，与 Matroska 官方规范（`0x63A2 / 0x54B0 / 0x54BA`）不一致，导致 ffmpeg 报 `Unknown entry 0x258681` + `could not find codec parameters`（H.264 因缺少可识别的 avcC CodecPrivate 无法初始化）。修正后**外部解码验收通过**：cv2 4.13 内置 ffmpeg matroska demux 打开本仓库产出的 MKV，`opened=True; decoded frames=12; first shape=(480, 640, 3)`——覆盖纯视频轨、含 AAC 音轨、muxSmoke 三种路径；`Tests/DKTests/main.swift::mkvAudioTest` 追加 5 条结构断言（新写入 `0x63A2/0x54B0/0x54BA`；不再包含旧错 ID），防止未来再飘移。对齐方案 §七「MKV 验收：H.264/HEVC + AAC 音轨封装 MKV，ffprobe/VLC 校验时长、音画同步正常」。
• **编码×容器矩阵外部解码已纳入可复现回归**（本会话）：发现本机实际具备 `PyAV 19.0.1` 与 `imageio-ffmpeg` 自带的真 `ffmpeg` 二进制（早先「本机无 ffprobe」判断不实）。新增 `Scripts/verify_media.py` 由 `Scripts/test.sh` 末尾自动调用：各集成用例经 `DISYNK_*_FIXTURE` 环境变量把产物落盘到稳定路径，随后用 PyAV 以第三方解码器逐个打开+实解码（每路独立 `av.open`，因 `container.decode` 共享 demuxer 游标，视频中途 break 后再解音频会误得 0 帧）。实测全部通过：`h264aac.mkv`→1 视频(h264)+1 音轨(aac 48kHz stereo)、时长 0.400s、解码 12 视频帧+8 音频帧；`hevc.mkv`→hevc 解码 8 帧（验证自拼 hvcC 可初始化解码器）；`vp8.webm`→vp8 8 帧；`vp9.webm`→vp9 8 帧（后两者仅 `DISYNK_WITH_LIBVPX=1` 时产出，否则自动跳过不判失败）。**合并模式端到端已纳入**（本会话）：`composeMergeToFileTest` 将两路纯色 BGRA 经 `MetalCompositor` 合成单帧→H.264 编码→MKV 封装为单文件（`DISYNK_MKV_MERGE_FIXTURE`），`verify_media.py --expect-layout` 从全新 container 解码首帧采样左/右半像素，实测左 RGB=(235,0,2) 红、右 RGB=(3,0,246) 蓝——证实“各屏画面位置与布局一致”存活整个合成→编码→封装→外部解码链（没有仅停在合成前像素断言）。坐实 §七「MKV/导出验收：H.264/HEVC + AAC 封装、WebM VP8/VP9、时长正常」（超越仅字节级 `A_AAC`/codecID/EBML magic 结构断言）。
   • **hvcC 自行拼装**（本会话发现的新修正）：VideoToolbox HEVC 输出的 `CMFormatDescription` 实测 **不**提供 `HVCDecoderConfigurationRecord` 扩展（`CMFormatDescriptionGetExtension` 返回 nil，本会话 probe 确认）。旧兜底 `buildHVCCHDR` 仅写 16 字节 stub（numOfArrays=0），ffmpeg 能开容器但 0 帧解码。`ParameterSets.extract` 升级为 `Sets { sps, pps, vps }` 三元组并将 HEVC 的 VPS 从 SPS 列表中分离；`MKVMuxer.buildHVC` 写入完整 22B hvcC 头 + numOfArrays=3 + VPS(32)/SPS(33)/PPS(34) 三 array，与 ISO/IEC 14496-15 §8.3.1.1 一致；长度前缀对齐（`lengthSizeMinusOne=3`），保证与 SimpleBlock 内 AVCC 字节流一致。回归验收：`dktest-hevc-*.mkv opened=True frames=8 shape=(480, 640, 3)`（cv2/ffmpeg）；hvcC 大小 103 字节（header 22 + numOfArrays 1 + VPS/SPS/PPS array header 12 + 参数集内容）。HEVC/MOV 一并验证 opened=True 8 帧（AVAssetWriter 自身已内建 hvcC）。
2. **Swift 5 语言模式而非 Swift 6 严格并发**：Apple delegate 型 API（SCStreamOutput 等）未全面 Sendable 化，6 模式产生大量 @preconcurrency 噪音；并发安全改由 actor + 显式锁保障（Package.swift 注释同）。
3. **WebM 真实 libvpx VP8/VP9 编码已落地**（本会话完成）：VideoToolbox 无 VP8/VP9 硬编；本环境不可下载官方 libvpx SDK，但发现本机 Python cv2 wheel 自带 `libvpx.11.dylib = v1.15.2` arm64，内含完整 VP8/VP9 编码器。取到后：
   • `install_name_tool -id @rpath/libvpx.11.dylib` 改写 install-name，拷入 `Scripts/vendor/libvpx/lib/`；
   • 无官方 SDK 头 → 从 raw.githubusercontent 拓取 v1.15.0 权威头文件逐字段核对，手写 ABI 正确的最小子集 `libvpx_shim.h`（vpx_image 136B、enc_cfg 504B、cx_pkt 136B），配 `module.modulemap` 将 umbrella 指向 shim → Swift `import LibVPX` 成功；
   • ABI 实测 `VPX_ENCODER_ABI_VERSION = 18+(4+5)+10 = 37`，Swift 不能导入宏 → `vpx_codec_enc_init_ver` 直传字面量 37；
   • 避开变参 `vpx_codec_control`（`VP8E_SET_CQ_LEVEL`）需求：采用 `VPX_VBR + rc_target_bitrate`（由 crf 反推码率）而非 VPX_Q；
   • `DISYNK_WITH_LIBVPX=1` 开启后 `zsh Scripts/test.sh` 全绿（当前默认 70/70；加 `DISYNK_RUN_GUI_SMOKE=1` 为 74/74），`webmLibVPXRealTest` 走真实抽帧→编码→封装全链路，**VP8 与 VP9 双码流各自产一份 WebM**：VP8 产物含 EBML magic + DocType=webm + codecID=V_VP8 + 关键帧起始码 9D 01 2A；VP9 产物含 DocType=webm + codecID=V_VP9 且不误写 V_VP8。`package.sh` 将 dylib 拷入 `.app/Contents/Frameworks` 并先内后外 codesign；隐藏开发绝对 rpath 后，dyld 确从 @executable_path/../Frameworks 加载 dylib。
   • **外部解码验收（VP8/VP9 双轨）**：本机无 ffprobe/VLC，但 cv2 4.13 自带 ffmpeg matroska/webm demux 可直接读回产出的 WebM——VP8 与 VP9 均 `opened=True; decoded frames=8; first shape=(240, 320, 3)`（测试写入临时目录、拷贝到 /tmp 后手动验证），与编码器入参完全对应，确认对齐方案 §三/§七「WebM（VP8/VP9）」两码流均可被独立第三方解码器处理。
4. **构建链**：本机 CLT 双重损坏（libPackageDescription 缺符号、module.modulemap 重复定义）→ `Scripts/build.sh` 用修补 resource-dir 的 swiftc 直编 + clang/libtool 编 ObjC 桥接；`Package.swift`/`project.yml` 为工程事实源，待环境修复后接管。
5. **不分发授权机制**：Ed25519 激活码、HWID 绑定与功能门控已于 v0.1.80 整体移除；所有能力对所有构建一律开放，UI 与引擎不再有许可判断分支。
6. 覆盖层「不入画」：已实现——`overlayIncludedInRecording=false` 时，AppModel 将 OverlayPanel 的 `windowNumber`（即 CGWindowID）经 `RecordingEngine.Params.overlayWindowIDs` 下传，CaptureCoordinator 从 `SCShareableContent.windows` 按 windowID 匹配解析为 SCWindow 并传入 `SCContentFilter(display:excludingWindows:)`，面板仅本机显示、不进录制流；开关与点击/快捷键两开关均独立生效。（需真机屏幕录制权限才能人工验收排除效果。）
7. **虚拟屏桥接 API 修正（本会话发现的真 bug）**：旧 `DVKCreateVirtualDisplay` 按旧版假设编写——先调 `+[CGVirtualDisplayDescriptor descriptor]`、再用 `+[CGVirtualDisplaySettings settingsWithDescriptor:]` 并在 settings 上 `setResolution:/setEnabled:/setRefreshRate:`。本会话对本机 CoreGraphics 做 ObjC 运行时 introspection 发现：macOS 14/15 上 descriptor **无** `+descriptor` 工厂（只 `-init`）、身份字段为 `productID`（非 productNumber）、名称为 `name`（非 productName），且**分辨率必须设在 descriptor 的 `maxPixelsWide/maxPixelsHigh`**；`CGVirtualDisplaySettings` 仅剩 `modes/hiDPI/rotation/refreshDeadline`，旧 `settingsWithDescriptor:`/`setResolution:`/`setEnabled:` **全部不存在**（旧代码因 respondsToSelector 保护不会崩，但 settings 永远为 nil、分辨率从未生效→虚拟屏永远无法上线）。修正后：descriptor `-init` + 设 maxPixelsWide/High/sizeInMillimeters/name，`initWithDescriptor:` 建实例，`CGVirtualDisplaySettings -init` 后 apply，**直读 `display.displayID` 属性**（新版直接暴露，不再脆弱地依赖在线列表差分）。集成冒烟：`virtualDisplaySmokeTest` 默认仅做非侵入能力探测；显式 `DISYNK_RUN_GUI_SMOKE=1` 时在本机真机 GUI 会话下创建 1920x1080 虚屏→断言 displayID≠0/在管理列表/销毁后移除，再创建自定义 2560x1440+HiDPI→断言标志位透传→销毁（本会话实跑：create#8(1920x1080)→list→destroy→create HiDPI 2560x1440→destroy→removed 全绿，145/145）——坐实 §三「虚拟屏创建（多块、自定义分辨率与 HiDPI）」的私有 API 生命周期在真机可用。**注**：虚屏是否真正“上线”可被 SCK 录制，需进程具备活跃 GUI/WindowServer 会话（即启动的 .app）；纯 CLI 测试环境常只分配 displayID 而不 online，属方案 §七已声明的“依赖真机 GUI”限制。

## 3.6 虚拟屏「上线」的真正前置条件（v0.1.22 补完 §七 第 7 条）

仅把分辨率设在 descriptor 的 `maxPixelsWide/maxPixelsHigh` **仍不足以让虚拟屏上线**：macOS 14/15 上 `CGVirtualDisplaySettings` 的分辨率唯一入口是 `modes`（`CGVirtualDisplayMode initWithWidth:height:refreshRate:` 组成的数组）。不设 `modes` → 该 display 没有任何可用显示模式 → WindowServer 永不将其 online → `CGGetOnlineDisplayList` / `NSScreen` / ScreenCaptureKit 共享内容列表里都看不到它，表现为「虚拟屏在录屏窗口显示不出来」（运行时反射探测 + 独立 probe 程序实测：补 `modes` 前 online=0，补后 online=1 且 px=2560x1440）。另两个坑：
- 只塞 `modes` 时系统默认挑中的往往是**中间项**（实测 2560x1440 虚拟屏默认落在 1280x720），必须再显式 `CGDisplaySetDisplayMode`（`DVKApplyPreferredMode`，已 deprecated 但实测返回 0 且生效），否则「建 2K」实拿 720p。
- 同一进程内销毁后 **3s 内立刻重建**可能不再 online（实测间隔 6s 正常）；故 `AppModel.virtualDisplayReport` 直接告知「已上线（可勾选）」还是「已创建但未上线，稍等后点刷新屏幕」，不再只给模糊提示。MRC 下 `modes` 属性声明为 `retain`（非 `strong`），`alloc` 出的 mode 交棒给数组后立即 release。

## 3.7 合并布局 = 真实像素 1:1 舞台 + 自由拖拽（v0.1.22）

旧版把预设单元格定死 `cellW = 1920` 并将各屏 `scaleToFit` 进去 → 预设/显示/合成三重降级（2K 屏在布局里显示成 1920×1080）。现模型：
- `Placement` 携带 `sourceWidth/sourceHeight`（真实像素），`pixelSize(canvas:)` 供编辑器回显真实分辨率；`tile()` 每块按 1:1 摆放，舞台至少 2×2 格以留出拖拽余量。
- 拖拽必须用 **命名坐标空间**（`DragGesture(coordinateSpace: .named("layoutStage"))`）：默认局部坐标下指针永远落在块内，换算出的归一化位置几乎不变 = 「拖不动」；同时旧 `move()` 的 `min(max(y,0), 1-h)` 在横排预设（h = 1）下把 y 锁死为 0 = 「摆不成上下排列」。
- 拖拽中只 `setDragPosition`（允许越界、不重映射），松手 `commitDrag → fitStage` 才扩舞台（越界时四周留 1/16 边距、各块**像素尺寸不变**）；若中途就 fitStage，画布一变就会与 `dragOrigin` 快照失配，块在边界处来回跳变。
- 录制起点 `RecordingEngine` 先 `croppedToContent()`（输出画布 = 各块并集包围盒）再 `clamped()`，实现「怎么摆放就怎么合并、不留舞台黑边」；上下排列的两块 2K 屏输出 2560×3312（高>宽）。
- 滚动拼接同步改写（§三 长截图）：固定 UI 识别改为「全局中位数静止带 + 逐对同址静止带」并容忍带内极少量闪烁行（地址栏光标/favicon），后续帧**只画内容区**，位移 Δ 直接给出新增行数（不再依赖「后缀 = 前缀」这种在两帧都带固定栏时结构性不可能成立的匹配）。

## 4. 性能对策落点（方案第四节）

- NV12 零拷贝直入 VT；合并模式才用 BGRA（多一次 GPU 采样，1 个编码会话替代 N 个）
- queueDepth=3；SCFrameStatus 非 complete 帧不入编码器并计入 dropped（UI 显示掉帧率）
- 帧率启动时按 `min(设定, 刷新率-0.5)` 钳制；合并画布 >8K 宽自动等比缩小
- 启动录制前 `DiskProbe`（DKCore）以 `F_FULLFSYNC` 实测目标盘持续写入吞吐，与本次各输出文件码率合计比较，不足（<需求×1.2）时 `onStatus` 抛 `.diskTooSlow` 告警（非致命，方案第四节“机械盘必然掉帧→写入前探测并警告”）
- SCK 回调在专用队列；帧路由单串行队列；muxer append 经 FIFO 管线不竞序
- GIF/WebM 导出在后台队列（Task.detached），不占实时管线

## 5. 命令

```sh
zsh Scripts/build.sh      # 全量编译（13 模块 + Disynk.app 可执行）
zsh Scripts/test.sh       # 编译并运行测试 harness（无 XCTest 环境，轻量断言）
zsh Scripts/package.sh    # 路径 A：ad-hoc 签名 + dmg（个人网站直发）
DISYNK_SIGN_IDENTITY="Developer ID Application: …" DISYNK_NOTARY_PROFILE=… \
  zsh Scripts/package.sh  # 路径 B：Developer ID + 公证 + staple
zsh Scripts/make_icon.sh  # 重生图标：AppIcon.icns + MenuBarIcon.png/@2x（彩色与单色共用同一矢量几何 aperturePath，形状必一致）
                          # 需 resource-dir 修补时才有 .build/resfix（健康工具链不生成）；图标变更后 package.sh 会拷进 bundle 并 lsregister 刷新缓存
zsh Scripts/build_libvpx.sh   # 按 DISYNK_ARCHS 逐架构编上游 libvpx v1.15.2 并 lipo，install-name 改写为 @rpath/libvpx.11.dylib
zsh Scripts/publish-github.sh # 发布公开仓库：复刻本仓库 → filter-repo 从全部历史剔除 website/ → 推分支与 v* 标签

# 构建开关（默认＝本机单架构、不装配 libvpx 的快循环）；架构、部署目标与修补判定只在 Scripts/toolchain.zsh 定义一份
DISYNK_ARCHS="arm64 x86_64"  # 通用二进制，CI 用这个
DISYNK_MIN_MACOS=15.0        # -target 三元组的部署目标
DISYNK_WITH_LIBVPX=1         # 显式装配/关闭 WebM 软编
DISYNK_VERSION=x.y.z         # package.sh 写入 bundle 的版本（默认取 Info.plist）
```
