// DVKObjC —— CGVirtualDisplay 私有 API 桥接层
//
// 依据联网调研结论（BetterDisplay / DeskPad / OpenDisplay 同源实现）：
// macOS 无公开虚拟屏 API，私有 CoreGraphics ObjC 类 CGVirtualDisplayDescriptor /
// CGVirtualDisplaySettings / CGVirtualDisplay 是行业通用路径。
// 所有调用均经运行时探测（NSClassFromString + respondsToSelector），
// 系统变更时返回错误而非崩溃；因此无法上架 MAS（方案已确认走直发）。

#import <Foundation/Foundation.h>
#import <CoreGraphics/CoreGraphics.h>

#ifdef __cplusplus
extern "C" {
#endif

/// 私有 API 在当前系统是否可探测到
BOOL DVKVirtualDisplayAvailable(void);

/// 创建虚拟屏。serial 用于幂等（同名同尺寸复用系统记录的 ICC 配置，见调研笔记）。
/// hiDPI 为真时尝试开启 Retina 缩放模式（CGVirtualDisplaySettings.hiDPI，方案第三节）。
/// 返回 0 表示失败；outErr 可选错误描述。
CGDirectDisplayID DVKCreateVirtualDisplay(NSUInteger width,
                                          NSUInteger height,
                                          double refreshRateHz,
                                          BOOL hiDPI,
                                          NSString *_Nullable name,
                                          NSUInteger serialNumber,
                                          NSString *_Nullable *_Nullable outErr);

/// 销毁虚拟屏；成功返回 true
BOOL DVKDestroyVirtualDisplay(CGDirectDisplayID displayID,
                              NSString *_Nullable *_Nullable outErr);

#ifdef __cplusplus
}
#endif
