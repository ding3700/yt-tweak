// YTSplashKill.m —— GroMore(ABU) 开屏广告自适应拦截
#import <Foundation/Foundation.h>
#import <UIKit/UIKit.h>
#import <CoreMotion/CoreMotion.h>
#import <objc/runtime.h>
#import <objc/message.h>

static void YTLog(NSString *fmt, ...) {
    va_list a; va_start(a, fmt);
    NSString *s = [[NSString alloc] initWithFormat:fmt arguments:a];
    va_end(a);
    NSLog(@"[YTSplashKill] %@", s);
}

// 找属性（按类型关键字）
static NSString *YTProp(Class cls, NSString *typeKey) {
    for (Class c = cls; c; c = class_getSuperclass(c)) {
        unsigned n = 0; objc_property_t *ps = class_copyPropertyList(c, &n);
        NSString *hit = nil;
        for (unsigned i = 0; i < n; i++) {
            const char *at = property_getAttributes(ps[i]);
            if (!at) continue;
            if ([[NSString stringWithUTF8String:at] rangeOfString:typeKey
                 options:NSCaseInsensitiveSearch].length) {
                hit = [NSString stringWithUTF8String:property_getName(ps[i])]; break;
            }
        }
        free(ps);
        if (hit) return hit;
    }
    return nil;
}

// 找含关键字的 selector
static SEL YTSel(Class cls, NSString *kw) {
    unsigned n = 0; Method *ms = class_copyMethodList(cls, &n);
    SEL hit = NULL;
    for (unsigned i = 0; i < n; i++) {
        SEL s = method_getName(ms[i]);
        if ([NSStringFromSelector(s) rangeOfString:kw
             options:NSCaseInsensitiveSearch].length) { hit = s; break; }
    }
    free(ms);
    return hit;
}

static id YTDelegateOf(id obj) {
    NSString *p = YTProp([obj class], @"SplashAdDelegate");
    if (!p) p = YTProp([obj class], @"Delegate");
    if (!p) return nil;
    @try { return [obj valueForKey:p]; } @catch (NSException *e) { return nil; }
}

// 主动通知 App：广告已关闭（让它直接进首页）
static void YTNotifyClosed(id self) {
    id del = YTDelegateOf(self);
    if (!del) { YTLog(@"no delegate found"); return; }
    SEL s = YTSel([del class], @"DidClose");
    if (!s) s = YTSel([del class], @"Closed");
    if (!s) s = YTSel([del class], @"DidFail");
    if (!s) { YTLog(@"no close/fail selector"); return; }
    NSMethodSignature *sig = [del methodSignatureForSelector:s];
    @try {
        if (sig.numberOfArguments == 2)      ((void (*)(id, SEL))objc_msgSend)(del, s);
        else if (sig.numberOfArguments == 3) ((void (*)(id, SEL, id))objc_msgSend)(del, s, self);
        else if (sig.numberOfArguments == 4) ((void (*)(id, SEL, id, id))objc_msgSend)(del, s, self, nil);
        YTLog(@"sent %@ -> %@", NSStringFromSelector(s), [del class]);
    } @catch (NSException *e) { YTLog(@"err %@", e); }
}

// 替换 show*: 不展示广告，直接回调关闭
static id YTShowBlocked(id self, SEL _cmd, id arg) {
    YTLog(@"block show %@::%@", [self class], NSStringFromSelector(_cmd));
    YTNotifyClosed(self);
    return nil;
}

static void YTNoop(id self, SEL _cmd, id a, id b) { }

static void YTInstall(void) {
    static BOOL done = NO; if (done) return;

    // 1) 拦所有 SplashAd 类的 show / load
    int num = objc_getClassList(NULL, 0);
    Class *cs = (Class *)malloc(sizeof(Class) * num);
    num = objc_getClassList(cs, num);
    int found = 0;
    for (int i = 0; i < num; i++) {
        NSString *cn = NSStringFromClass(cs[i]);
        if (![cn rangeOfString:@"SplashAd" options:NSCaseInsensitiveSearch].length) continue;
        found++;
        YTLog(@"== class %@ ==", cn);
        unsigned n = 0; Method *ms = class_copyMethodList(cs[i], &n);
        for (unsigned j = 0; j < n; j++) {
            SEL s = method_getName(ms[j]);
            NSString *sn = NSStringFromSelector(s);
            int argc = method_getNumberOfArguments(ms[j]);
            YTLog(@"   %@ (%d)", sn, argc);
            if (([sn hasPrefix:@"show"] || [sn rangeOfString:@"showInWindow"
                 options:NSCaseInsensitiveSearch].length) && argc == 3) {
                method_setImplementation(ms[j], (IMP)YTShowBlocked);
                YTLog(@"   -> hooked %@", sn);
            }
        }
        free(ms);
    }
    free(cs);
    YTLog(@"splash classes found: %d", found);

    // 2) 禁传感器（摇一摇跳转）
    Class cm = NSClassFromString(@"CMMotionManager");
    if (cm) {
        SEL sels[] = { @selector(startAccelerometerUpdatesToQueue:withHandler:),
                       @selector(startGyroUpdatesToQueue:withHandler:),
                       @selector(startDeviceMotionUpdatesToQueue:withHandler:) };
        for (int k = 0; k < 3; k++) {
            Method m = class_getInstanceMethod(cm, sels[k]);
            if (m) { method_setImplementation(m, (IMP)YTNoop); YTLog(@"motion blocked %d", k); }
        }
    }
    if (found > 0) done = YES;
}

__attribute__((constructor)) static void YTInit(void) {
    @autoreleasepool {
        YTLog(@"dylib loaded");
        YTInstall();
        // 类可能尚未注册，启动完成后再补一次
        dispatch_async(dispatch_get_main_queue(), ^{
            static dispatch_once_t once; dispatch_once(&once, ^{
                dispatch_after(dispatch_time(DISPATCH_TIME_NOW, 1.0 * NSEC_PER_SEC),
                               dispatch_get_main_queue(), ^{ YTInstall(); });
            });
        });
    }
}
