#import "DVKObjC.h"
#import <objc/runtime.h>
#import <objc/message.h>
#import <CoreGraphics/CoreGraphics.h>

#pragma mark - 私有类声明（运行时解析，无链接期符号依赖）
//
// 注：macOS 14/15 上 CGVirtualDisplaySettings 仅有 modes/hiDPI/rotation/refreshDeadline，
//   不再有旧版 setResolution:/setEnabled:/settingsWithDescriptor:；分辨率须设在
//   CGVirtualDisplayDescriptor 的 maxPixelsWide/maxPixelsHigh（本会话 introspect 确认）。

@interface DVKVirtualDisplayDescriptor : NSObject
- (instancetype)init;
@property (nonatomic) NSUInteger serialNumber;
@property (nonatomic) NSUInteger vendorID;
@property (nonatomic) NSUInteger productID;
@property (nonatomic) NSUInteger maxPixelsWide;
@property (nonatomic) NSUInteger maxPixelsHigh;
@property (nonatomic) CGSize sizeInMillimeters;
@property (nonatomic, copy) NSString *name;
/// 运行时探测确认（macOS 15）：descriptor 有 queue / terminationHandler；
/// 下线是异步的，terminationHandler 在 queue 上回调，回调期间仍会访问 descriptor 内部内存。
@property (nonatomic, copy, nullable) void (^terminationHandler)(void);
@end

@interface DVKVirtualDisplaySettings : NSObject
- (instancetype)init;
@property (nonatomic) BOOL hiDPI;
/// macOS 14/15 上分辨率的唯一入口：CGVirtualDisplayMode 数组（旧版才是 width/height）。
/// 本文件为 MRC，故用 retain（运行时探测到的属性标记为 T&="...",T,N,V，即普通 retain 对象）。
@property (nonatomic, retain) NSArray *modes;
@end

@interface DVKVirtualDisplay : NSObject
- (instancetype)initWithDescriptor:(DVKVirtualDisplayDescriptor *)descriptor;
@property (nonatomic, readonly) NSUInteger displayID;
- (void)applySettings:(DVKVirtualDisplaySettings *)settings;
@end

// 下线完成凭证：terminationHandler 回调里把它置位，由后续清扫决定何时释放 holder。
// 单独一个小对象（而不让 block 直接引用 holder）是为了避开 MRC 下无 __weak 的循环/悬垂指针问题：
// block 强持 ticket，ticket 不反向引用任何人。
@interface DVKTeardownTicket : NSObject
@property (atomic) BOOL fired;
@end
@implementation DVKTeardownTicket
@end

// 持有 display 及其 descriptor / settings 的强引用包。
// 两层生命周期约束（两者都会导致随机 objc_msgSend / 堆损坏崩溃）：
//  1) CGVirtualDisplay dealloc 会向创建它的 descriptor 发消息 → descriptor/settings 必须比 display 活得久；
//  2) display 释放后，WindowServer 侧的下线是异步的，完成时会在 queue 上回调 terminationHandler，
//     期间仍会写 descriptor/settings 内存 → 必须把它们扣在「下线中集合」里，直到回调真正发生才释放。
@interface DVKDisplayHolder : NSObject
@property (nonatomic, strong, nullable) DVKVirtualDisplay *display;
@property (nonatomic, strong) DVKVirtualDisplayDescriptor *descriptor;
@property (nonatomic, strong, nullable) DVKVirtualDisplaySettings *settings;
@property (nonatomic, strong) DVKTeardownTicket *ticket;
@end
@implementation DVKDisplayHolder
@end

#pragma mark - 工具

static NSArray<NSNumber *> *DVKOnlineDisplayIDs(void) {
    uint32_t count = 0;
    CGGetOnlineDisplayList(0, NULL, &count);
    NSMutableArray *out = [NSMutableArray arrayWithCapacity:count];
    if (count == 0) return out;
    CGDirectDisplayID *ids = calloc(count, sizeof(CGDirectDisplayID));
    CGGetOnlineDisplayList(count, ids, &count);
    for (uint32_t i = 0; i < count; i++) [out addObject:@(ids[i])];
    free(ids);
    return out;
}

// 实例注册表：displayID -> DVKDisplayHolder（强持有 display 及其 descriptor/settings）。
// 存 holder 而非裸 display：销毁时需保证 descriptor/settings 比 display 活得更久，
// 否则 CGVirtualDisplay dealloc 访问已释放的 descriptor → objc_msgSend 野指针崩溃。
static NSMutableDictionary<NSNumber *, id> *DVKRegistry(void) {
    static NSMutableDictionary *reg;
    static dispatch_once_t token;
    // 必须 alloc/init：本文件以 **MRC** 编译（build.sh 的 clang 不带 -fobjc-arc），
    // [NSMutableDictionary dictionary] 返回的是 autorelease 对象，池排空后静态指针就悬垂，
    // 之后每次读写都是 use-after-free（表现为删除虚拟屏时 objc_msgSend 随机崩溃）。
    dispatch_once(&token, ^{ reg = [[NSMutableDictionary alloc] init]; });
    return reg;
}

// 「下线中」集合：强持有已请求销毁但异步 terminationHandler 还未回调的 holder。
// 不这样扣住的话，descriptor/settings 会在系统仍在写它时被释放 → 堆损坏（表现为
// 随机位置的 objc_msgSend 崩溃，例如下次访问注册表字典时 bad isa）。
static NSMutableSet *DVKTearing(void) {
    static NSMutableSet *s;
    static dispatch_once_t token;
    dispatch_once(&token, ^{ s = [[NSMutableSet alloc] init]; });   // 同上：MRC 下不可用 +set 便利构造
    return s;
}

// 把已收到下线回调的 holder 从「下线中集合」里丢掉（= 真正释放 descriptor/settings）。
// 在每次 create/destroy 入口以及几个延迟清扫点调用，避免依赖回调线程上做释放。
static void DVKSweepTearing(void) {
    NSMutableArray *done = [NSMutableArray array];
    @synchronized (DVKTearing()) {
        for (DVKDisplayHolder *h in DVKTearing()) {
            if (h.ticket.fired) [done addObject:h];
        }
        [DVKTearing() minusSet:[NSSet setWithArray:done]];
    }
}

static void DVKScheduleTearingSweep(void) {
    for (NSNumber *delay in @[ @2.0, @15.0, @90.0 ]) {
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(delay.doubleValue * NSEC_PER_SEC)),
                       dispatch_get_main_queue(), ^{ DVKSweepTearing(); });
    }
}

BOOL DVKVirtualDisplayAvailable(void) {
    return NSClassFromString(@"CGVirtualDisplayDescriptor") != nil
        && NSClassFromString(@"CGVirtualDisplay") != nil
        && NSClassFromString(@"CGVirtualDisplaySettings") != nil;
}

static void DVKSetIfResponds(id obj, SEL sel, NSUInteger value) {
    if ([obj respondsToSelector:sel]) {
        ((void (*)(id, SEL, NSUInteger))objc_msgSend)(obj, sel, value);
    }
}

static void DVKSetIfRespondsBool(id obj, SEL sel, BOOL value) {
    if ([obj respondsToSelector:sel]) {
        ((void (*)(id, SEL, BOOL))objc_msgSend)(obj, sel, value);
    }
}

// CGVirtualDisplayMode 的 width/height/refreshRate 都是只读，只能走私有初始化器。
// 取不到类/选择器时返回 nil，由调用方回退到 descriptor-only 旧路径。
static id DVKNewDisplayMode(NSUInteger width, NSUInteger height, double hz) {
    Class modeCls = NSClassFromString(@"CGVirtualDisplayMode");
    if (!modeCls) return nil;
    SEL initSel = @selector(initWithWidth:height:refreshRate:);
    if (![modeCls instancesRespondToSelector:initSel]) return nil;
    return ((id (*)(id, SEL, NSUInteger, NSUInteger, double))objc_msgSend)(
        [modeCls alloc], initSel, width, height, hz > 1.0 ? hz : 60.0);
}

// 把虚拟屏的当前模式切到请求分辨率。
// 只把 mode 放进 settings.modes 不够：系统默认挑中的往往是中间项（实测 2560x1440 虚拟屏
// 默认落在 1280x720），必须显式 SetDisplayMode，否则“建 2K”实拿 720p。
// CGDisplaySetDisplayMode 在 macOS 13+ 标了 deprecated，但实测仍有效（返回 0 且模式生效）。
static BOOL DVKApplyPreferredMode(CGDirectDisplayID did, NSUInteger width, NSUInteger height) {
    if (!did || !CGDisplayIsOnline(did)) return NO;
    CFArrayRef all = CGDisplayCopyAllDisplayModes(did, NULL);
    if (!all) return NO;
    CGDisplayModeRef target = NULL;
    for (CFIndex i = 0; i < CFArrayGetCount(all); i++) {
        CGDisplayModeRef m = (CGDisplayModeRef)CFArrayGetValueAtIndex(all, i);
        if (CGDisplayModeGetPixelWidth(m) == width && CGDisplayModeGetPixelHeight(m) == height) {
            target = m;
            break;
        }
    }
    BOOL ok = NO;
    if (target) {
#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Wdeprecated-declarations"
        ok = CGDisplaySetDisplayMode(did, target, NULL) == kCGErrorSuccess;
#pragma clang diagnostic pop
    }
    CFRelease(all);
    return ok;
}

// 失败善后：display 已创建但拿不到 displayID 时，绝不可在此释放它——
// CGVirtualDisplay dealloc 会访问 descriptor（可能刚被同作用域释放）而与 WindowServer
// 半初始化的资源打架，导致崩溃。故意永久持有（泄漏一个对象）比闪退划算。
static NSMutableArray<DVKDisplayHolder *> *DVKOrphans(void) {
    static NSMutableArray *arr;
    static dispatch_once_t token;
    dispatch_once(&token, ^{ arr = [[NSMutableArray alloc] init]; });   // 同上：MRC 下必须 alloc
    return arr;
}

static void DVKParkOrphan(DVKVirtualDisplay *display,
                          DVKVirtualDisplayDescriptor *descriptor,
                          DVKVirtualDisplaySettings *settings) {
    if (!display) return;
    DVKDisplayHolder *holder = [[DVKDisplayHolder alloc] init];
    holder.display = display;
    holder.descriptor = descriptor;
    holder.settings = settings;
    @synchronized (DVKOrphans()) { [DVKOrphans() addObject:holder]; }   // 数组接管
    [holder release];
}

CGDirectDisplayID DVKCreateVirtualDisplay(NSUInteger width, NSUInteger height,
                                          double refreshRateHz, BOOL hiDPI,
                                          NSString *name,
                                          NSUInteger serialNumber,
                                          NSString **outErr) {
    DVKSweepTearing();   // 顺手回收已下线完成的 holder
    if (!DVKVirtualDisplayAvailable()) {
        if (outErr) *outErr = @"系统未暴露 CGVirtualDisplay 私有类，虚拟屏不可用";
        return 0;
    }
    Class descCls = NSClassFromString(@"CGVirtualDisplayDescriptor");
    Class dispCls = NSClassFromString(@"CGVirtualDisplay");
    Class settingsCls = NSClassFromString(@"CGVirtualDisplaySettings");
    if (!descCls || !dispCls || !settingsCls) {
        if (outErr) *outErr = @"私有类解析失败";
        return 0;
    }

    DVKVirtualDisplayDescriptor *descriptor = [[descCls alloc] init];   // MRC：本函数 +1
    if (!descriptor) {
        if (outErr) *outErr = @"descriptor 创建失败";
        return 0;
    }
    // 分辨率/身份设在 descriptor（新版 API）；setter 均经 respondsToSelector 防御
    DVKSetIfResponds(descriptor, @selector(setSerialNumber:), serialNumber);
    DVKSetIfResponds(descriptor, @selector(setVendorID:), 0x1234);
    DVKSetIfResponds(descriptor, @selector(setProductID:), 0x0001);
    DVKSetIfResponds(descriptor, @selector(setMaxPixelsWide:), width - (width % 2));
    DVKSetIfResponds(descriptor, @selector(setMaxPixelsHigh:), height - (height % 2));
    if ([descriptor respondsToSelector:@selector(setSizeInMillimeters:)]) {
        ((void (*)(id, SEL, CGSize))objc_msgSend)(descriptor, @selector(setSizeInMillimeters:),
                                                  CGSizeMake(390, 220));
    }
    if (name && [descriptor respondsToSelector:@selector(setName:)]) {
        [descriptor setName:name];
    }

    // holder 先于 display 创建：下线回调只强持一个 ticket（不反向引用 holder），
    // 回调置位后由清扫释放 holder。
    // 以下均按 MRC 约定交接所有权：建对象 +1 → 交给 holder/容器 → 立即 release 自己那份。
    DVKDisplayHolder *holder = [[DVKDisplayHolder alloc] init];         // +1（本函数持有，出口统一 release）
    holder.descriptor = descriptor;
    [descriptor release];                                              // descriptor 现由 holder 唯一持有
    DVKTeardownTicket *ticket = [[DVKTeardownTicket alloc] init];
    holder.ticket = ticket;
    [ticket release];                                                  // block 拷入堆时也会 retain 一份
    if ([descriptor respondsToSelector:@selector(setTerminationHandler:)]) {
        [descriptor setTerminationHandler:^{ ticket.fired = YES; }];
    }

    DVKVirtualDisplay *display = [[dispCls alloc] initWithDescriptor:descriptor];   // +1
    if (!display) {
        if (outErr) *outErr = @"CGVirtualDisplay 实例创建失败";
        [holder release];       // 连带释放 descriptor/ticket
        return 0;
    }
    holder.display = display;
    [display release];          // display 现由 holder 持有

    DVKVirtualDisplaySettings *settings = [[settingsCls alloc] init];    // +1
    if (settings) {
        // 方案第三节：HiDPI——新版 settings 仅剩 hiDPI 等少数字段，经 respondsToSelector 防御。
        if (hiDPI) {
            DVKSetIfRespondsBool(settings, @selector(setHiDPI:), YES);
        }
        // 关键：macOS 14/15 的 settings 已无 width/height，分辨率**必须**通过 modes 数组给出。
        // 不设 modes → 虚拟屏没有可用显示模式 → 系统永远不让它 online →
        // CGGetOnlineDisplayList / NSScreen / SCK 屏幕列表里都看不到它（= 无法录制虚拟屏）。
        if ([settings respondsToSelector:@selector(setModes:)]) {
            id mode = DVKNewDisplayMode(width - (width % 2), height - (height % 2), refreshRateHz);
            if (mode) {
                NSArray *modes = [[NSArray alloc] initWithObjects:&mode count:1];   // 数组 retain mode
                [mode release];                                                     // 放掉 init 那份
                [settings setModes:modes];
                [modes release];                                                    // 交给 settings（retain）
            }
        }
        [display applySettings:settings];
    }
    holder.settings = settings;
    [settings release];                                                  // 交给 holder（可能为 nil）

    // 主取 displayID 属性（新版直接暴露）；兼容旧环境再回退到在线列表差分。
    NSUInteger before = [DVKOnlineDisplayIDs() count];
    CGDirectDisplayID newID = (CGDirectDisplayID)display.displayID;
    // 上线是异步的（需进程拥有活跃 GUI/WindowServer 会话；纯 CLI 工具可能永远不 online）
    //   ——与方案第七节“依赖真机 GUI”限制一致。给多次 runloop 一拍以便真实 App 内差分兼底。
    for (int attempt = 0; attempt < 10 && newID == 0; attempt++) {
        [[NSRunLoop currentRunLoop] runUntilDate:[NSDate dateWithTimeIntervalSinceNow:0.1]];
        newID = (CGDirectDisplayID)display.displayID;
        if (newID == 0 && [DVKOnlineDisplayIDs() count] > before) {
            NSSet *beforeSet = [NSSet set]; // 差分兑底：取新出现且未被注册的 ID
            for (NSNumber *n in DVKOnlineDisplayIDs()) {
                if (DVKRegistry()[n] == nil) { newID = (CGDirectDisplayID)n.unsignedIntValue; break; }
            }
            (void)beforeSet;
        }
    }
    if (newID == 0) {
        if (outErr) *outErr = @"虚拟屏已创建但未获得 displayID（系统可能拒绝或非 GUI 会话）";
        // 注意：display/descriptor/settings 已由 holder 持有，这里传的是借用指针；
        // DVKParkOrphan 内部会再 retain 一份，因此下面 release holder 不会把它们带下去。
        DVKParkOrphan(display, descriptor, settings);   // 不释放，避免 dealloc 崩溃
        [holder release];
        return 0;
    }
    // 等待真正「上线」：SCK / CGGetOnlineDisplayList 只列出 online 的屏，
    // 仅拿到 displayID 不代表已 online（否则刚创建的屏不会出现在录制屏幕列表里）。
    // 上线是异步的，泵主 runloop 最多 ~2.5s 等它进入 online 集。
    for (int wait = 0; wait < 25 && !CGDisplayIsOnline(newID); wait++) {
        [[NSRunLoop currentRunLoop] runUntilDate:[NSDate dateWithTimeIntervalSinceNow:0.1]];
    }
    if (!CGDisplayIsOnline(newID)) {
        // 仍未上线：不视为失败（部分环境上线更晚，后续多次刷新仍可能出现），
        // 仅给出提示；注册表照存，保证能单独/全部移除。
        if (outErr) *outErr = @"虚拟屏已创建但系统未使其上线（可能受会话/权限限制），可能不会出现在屏幕列表";
    } else if (!DVKApplyPreferredMode(newID, width - (width % 2), height - (height % 2))) {
        // 切模式失败不致命：虚拟屏仍在（只是分辨率不是请求的那个），给提示不报错。
        if (outErr) *outErr = @"虚拟屏已上线但未能切到请求分辨率（实际分辨率可能与请求不同）";
    }
    @synchronized (DVKRegistry()) {
        DVKRegistry()[@(newID)] = holder;   // holder 已持 display/descriptor/settings
    }
    [holder release];                       // 注册表接管
    return newID;
}

BOOL DVKDestroyVirtualDisplay(CGDirectDisplayID displayID, NSString **outErr) {
    DVKDisplayHolder *holder = nil;
    @synchronized (DVKRegistry()) {
        id obj = DVKRegistry()[@(displayID)];
        if ([obj isKindOfClass:[DVKDisplayHolder class]]) {
            // 必须 retain：objectForKeyedSubscript: 返回 +0 借用引用，而下一行的
            // removeObjectForKey: 会把字典那份唯一的所有权放掉 → 不 retain 则 holder 当场悬垂，
            // 后续 holder.display = nil 就是 use-after-free（删除虚拟屏闪退的直接原因）。
            holder = [obj retain];
        }
        [DVKRegistry() removeObjectForKey:@(displayID)];
    }
    if (!holder) {
        if (outErr) *outErr = @"该 displayID 不是本应用创建的虚拟屏";
        return NO;
    }
    // 关键：下线是异步的。先把 holder 扣进「下线中集合」强持有，再释放 display；
    // descriptor/settings 将一直活到 terminationHandler 回调（回调后置位 ticket，由清扫除名）。
    BOOL asyncTermination = [holder.descriptor respondsToSelector:@selector(setTerminationHandler:)];
    if (asyncTermination) {
        @synchronized (DVKTearing()) { [DVKTearing() addObject:holder]; }   // 集合接管一份
        DVKScheduleTearingSweep();
    }
    @autoreleasepool {
        // 先释放 display：此时 descriptor/settings 仍被 holder（及 tearing 集合）强持有。
        holder.display = nil;
    }
    if (!asyncTermination) {
        // 旧系统无回调可用：只能泵一轮 runloop 后放手（尽力而为）。
        [[NSRunLoop currentRunLoop] runUntilDate:[NSDate dateWithTimeIntervalSinceNow:0.05]];
    }
    [holder release];                       // 放下本函数那份
    return YES;
}
