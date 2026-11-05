//
//  Tweak.x —— VCam Volume Panel
//
//  作用：在 SpringBoard 里挂一个"音量减"监听，按一下弹出面板：
//      选择视频   -> 转发 Darwin 通知给 551UK Virtual Cam，让它弹出相册选择器
//      禁止替换   -> 直接改它的配置文件 enabled=false，并用通知让它刷新
//      恢复替换   -> enabled=true
//
//  不重写 Virtual Cam 的任何核心逻辑，只做"外部触发器"，所以它自己能继续升级。
//
//  这也是为什么必须 arm64e：SpringBoard 是 arm64e 进程。
//

#import <UIKit/UIKit.h>
#import <AVFoundation/AVFoundation.h>
#import <objc/runtime.h>
#import <objc/message.h>
#include <dlfcn.h>

#define VCAM_CONFIG   @"/var/mobile/Media/DCIM/vcam.plist"
#define NOTIFY_CHOOSE "com.551uk.virtualcam.choose"
#define NOTIFY_TOGGLE "com.551uk.virtualcam.toggle"
#define NOTIFY_STATE  "com.551uk.virtualcam.statechanged"
#define LOG_PATH      @"/tmp/vcamvol.log"

static void VVLog(NSString *fmt, ...) {
    va_list ap; va_start(ap, fmt);
    NSString *msg = [[NSString alloc] initWithFormat:fmt arguments:ap];
    va_end(ap);
    NSFileManager *fm = [NSFileManager defaultManager];
    [fm createDirectoryAtPath:@"/var/mobile/Library" withIntermediateDirectories:YES attributes:nil error:nil];
    NSString *line = [NSString stringWithFormat:@"[%@] %@\n", [NSDate date], msg];
    NSFileHandle *fh = [NSFileHandle fileHandleForWritingAtPath:LOG_PATH];
    if (!fh) {
        [[line dataUsingEncoding:NSUTF8StringEncoding] writeToFile:LOG_PATH atomically:NO];
        [fm setAttributes:@{NSFilePosixPermissions: @(0666)} ofItemAtPath:LOG_PATH error:nil];
    } else {
        @try { [fh seekToEndOfFile]; [fh writeData:[line dataUsingEncoding:NSUTF8StringEncoding]]; }
        @finally { [fh closeFile]; }
    }
}

#pragma mark - Virtual Cam 配置读写（逆向得出的 plist 格式）

static NSMutableDictionary *VVReadConfig(void) {
    NSDictionary *d = [NSDictionary dictionaryWithContentsOfFile:VCAM_CONFIG];
    return d ? [d mutableCopy] : [NSMutableDictionary dictionary];
}

static void VVWriteConfig(NSMutableDictionary *cfg) {
    // generation 是它用来感知"配置变了"的版本号，必须递增
    NSInteger gen = [cfg[@"generation"] integerValue] + 1;
    cfg[@"generation"] = @(gen);
    [cfg writeToFile:VCAM_CONFIG atomically:YES];
    [[NSFileManager defaultManager] setAttributes:@{NSFilePosixPermissions: @(0644)}
                                     ofItemAtPath:VCAM_CONFIG error:nil];
    VVLog(@"config written: enabled=%@ generation=%@", cfg[@"enabled"], cfg[@"generation"]);
}

static void VVPost(const char *name) {
    void (*post)(const char *) = (void (*)(const char *))dlsym(RTLD_DEFAULT, "notify_post");
    if (post) { post(name); VVLog(@"posted %s", name); }
}

#pragma mark - 面板

@interface VVPanel : NSObject
+ (instancetype)shared;
- (void)trigger;
@end

@implementation VVPanel {
    UIWindow *_win;
    UIViewController *_host;
    CFAbsoluteTime _last;
}

+ (instancetype)shared {
    static VVPanel *p; static dispatch_once_t once;
    dispatch_once(&once, ^{ p = [VVPanel new]; });
    return p;
}

- (UIWindow *)window {
    if (_win) return _win;
    UIWindow *w = nil;
    if (@available(iOS 13.0, *)) {
        UIWindowScene *scene = nil;
        for (UIScene *s in [UIApplication sharedApplication].connectedScenes) {
            if ([s isKindOfClass:[UIWindowScene class]]) {
                UIWindowScene *ws = (UIWindowScene *)s;
                if (ws.activationState == UISceneActivationStateForegroundActive) { scene = ws; break; }
                if (!scene) scene = ws;
            }
        }
        VVLog(@"window: scene=%p activation=%ld", scene, (long)scene.activationState);
        if (scene) {
            w = [[UIWindow alloc] initWithWindowScene:scene];
            w.frame = scene.coordinateSpace.bounds;
        }
    }
    if (!w) {
        VVLog(@"window: fallback initWithFrame");
        w = [[UIWindow alloc] initWithFrame:[UIScreen mainScreen].bounds];
    }
    w.windowLevel = 10000001.0;
    w.backgroundColor = [UIColor clearColor];
    UIViewController *vc = [UIViewController new];
    vc.view.backgroundColor = [UIColor clearColor];
    w.rootViewController = vc;
    w.hidden = NO;
    _win = w; _host = vc;
    VVLog(@"window ready: %@ level=%.0f hidden=%d", w, w.windowLevel, w.hidden);
    return w;
}
- (UIViewController *)top {
    UIViewController *vc = _host;
    while (vc.presentedViewController) vc = vc.presentedViewController;
    return vc;
}

- (void)trigger {
    CFAbsoluteTime now = CFAbsoluteTimeGetCurrent();
    if (now - _last < 0.8) return;       // 去抖
    _last = now;
    VVLog(@"volume down -> panel");
    dispatch_async(dispatch_get_main_queue(), ^{ [self show]; });
}

- (void)hideOverlay {
    // 延迟隐藏，等 alert 收完动画，避免把用户下一次点击吃掉
    __weak typeof(self) ws = self;
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.45 * NSEC_PER_SEC)),
                   dispatch_get_main_queue(), ^{
        ws->_win.hidden = YES;
        VVLog(@"overlay hidden (touches restored)");
    });
}

- (void)show {
    _win.hidden = NO;
    [self window];
    UIViewController *from = [self top];
    if ([from isKindOfClass:[UIAlertController class]]) return;

    NSMutableDictionary *cfg = VVReadConfig();
    BOOL on = [cfg[@"enabled"] boolValue];
    NSString *msg = on
        ? [NSString stringWithFormat:@"当前：已替换\n%@", [[cfg[@"sourcePath"] lastPathComponent] ?: @"?" description]]
        : @"当前：使用手机摄像头";

    VVLog(@"show: from=%@", from);
    UIAlertController *ac = [UIAlertController alertControllerWithTitle:@"Virtual Cam"
                                                               message:msg
                                                        preferredStyle:UIAlertControllerStyleAlert];

    [ac addAction:[UIAlertAction actionWithTitle:@"选择视频" style:UIAlertActionStyleDefault handler:^(UIAlertAction *a) {
        VVPost(NOTIFY_CHOOSE);
        [[VVPanel shared] hideOverlay];                     // 让 Virtual Cam 弹它自己的相册选择器
    }]];

    if (on) {
        [ac addAction:[UIAlertAction actionWithTitle:@"禁止替换" style:UIAlertActionStyleDestructive handler:^(UIAlertAction *a) {
            NSMutableDictionary *c = VVReadConfig();
            c[@"enabled"] = @NO;
            VVWriteConfig(c);
            VVPost(NOTIFY_STATE);
            VVPost(NOTIFY_TOGGLE);
            [[VVPanel shared] hideOverlay];
        }]];
    } else {
        [ac addAction:[UIAlertAction actionWithTitle:@"恢复替换" style:UIAlertActionStyleDefault handler:^(UIAlertAction *a) {
            NSMutableDictionary *c = VVReadConfig();
            c[@"enabled"] = @YES;
            c[@"masterEnabled"] = @YES;
            VVWriteConfig(c);
            VVPost(NOTIFY_STATE);
            VVPost(NOTIFY_TOGGLE);
            [[VVPanel shared] hideOverlay];
        }]];
    }

    [ac addAction:[UIAlertAction actionWithTitle:@"取消" style:UIAlertActionStyleCancel handler:^(UIAlertAction *a) {
        [[VVPanel shared] hideOverlay];
    }]];
    [from presentViewController:ac animated:YES completion:^{
        VVLog(@"present completion: presented=%@", from.presentedViewController);
    }];
}

@end

#pragma mark - 音量键：多候选 hook + 音量轮询兜底

typedef void (*MSHookMsgExFn)(Class, SEL, IMP, IMP *);
static IMP g_origVolDown = NULL;

static void vv_volumeDown(id self, SEL _cmd) {
    [[VVPanel shared] trigger];
    if (g_origVolDown) ((void (*)(id, SEL))g_origVolDown)(self, _cmd);
}

static BOOL vv_hookFirst(NSString *clsName, NSArray<NSString *> *sels) {
    Class cls = NSClassFromString(clsName);
    MSHookMsgExFn hook = (MSHookMsgExFn)dlsym(RTLD_DEFAULT, "MSHookMessageEx");
    if (!cls || !hook) return NO;
    for (NSString *s in sels) {
        SEL sel = NSSelectorFromString(s);
        if (!class_getInstanceMethod(cls, sel)) continue;
        hook(cls, sel, (IMP)vv_volumeDown, &g_origVolDown);
        VVLog(@"hooked %@ -%@", clsName, s);
        return YES;
    }
    return NO;
}

// 读取系统音量：用公开 API AVAudioSession，不碰私有方法，避免签名不匹配崩溃
static float vv_volume(void) {
    static dispatch_once_t once;
    dispatch_once(&once, ^{ VVLog(@"volume source: AVAudioSession.outputVolume"); });
    @try {
        return [[AVAudioSession sharedInstance] outputVolume];
    } @catch (NSException *e) {
        return -1.0f;
    }
}
static void vv_startPoll(void) {
    // 用后台线程轮询，不依赖主队列/runloop（SpringBoard 早期主队列定时器不生效）
    dispatch_async(dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_DEFAULT, 0), ^{
        float last = vv_volume();
        VVLog(@"poll start volume=%.3f", last);
        CFAbsoluteTime lastBeat = CFAbsoluteTimeGetCurrent();
        int n = 0;
        while (YES) {
            @autoreleasepool {
                float v = vv_volume();
                n++;
                // 每 2 秒报告一次当前音量，方便确认它在工作
                if (CFAbsoluteTimeGetCurrent() - lastBeat > 2.0) {
                    lastBeat = CFAbsoluteTimeGetCurrent();
                    VVLog(@"beat #%d volume=%.3f", n, v);
                }
                if (v >= 0 && last >= 0 && v < last - 0.01f) {
                    VVLog(@"poll: volume DROP %.3f -> %.3f", last, v);
                    [[VVPanel shared] trigger];
                }
                if (v >= 0) last = v;
                [NSThread sleepForTimeInterval:0.15];
            }
        }
    });
}

%ctor {
    @autoreleasepool {
        VVLog(@"===== vcamvol loaded (pid %d) =====", getpid());

        NSArray *cands = @[
            @[@"SBVolumeHardwareButton", @[@"_volumeDownButtonDown:", @"volumeDownButtonDown:", @"volumeDownButtonPressed"]],
            @[@"SBVolumeControl",        @[@"decreaseVolume", @"_decreaseVolume", @"handleVolumeDown"]],
            @[@"SBHardwareButtonCoordinator", @[@"_volumeDownButtonDown:"]],
            @[@"SpringBoard",            @[@"_handleVolumeDownButtonDown:"]],
        ];
        BOOL bound = NO;
        for (NSArray *pair in cands) {
            if (vv_hookFirst(pair[0], pair[1])) { bound = YES; break; }
            VVLog(@"class %@ / 方法都不存在", pair[0]);
        }
        VVLog(@"volume hook bound=%d", bound);
        vv_startPoll();
    }
}
