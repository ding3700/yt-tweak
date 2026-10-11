#import <Foundation/Foundation.h>
#import <UIKit/UIKit.h>
#import <CoreMotion/CoreMotion.h>
#import <objc/runtime.h>

static NSMutableOrderedSet<NSString *> *gSeen;
static NSMutableString *gReport;

static void YTInit(void) {
    if (!gSeen) { gSeen = [NSMutableOrderedSet orderedSet]; gReport = [NSMutableString string]; }
}
static void YTLog(NSString *line) {
    YTInit();
    if (![gSeen containsObject:line]) { [gSeen addObject:line]; [gReport appendFormat:@"%@\n", line]; }
    NSLog(@"[YTProbe] %@", line);
}

// 只记录（范围宽）
static BOOL YTIsSuspect(NSString *cn) {
    NSString *l = cn.lowercaseString;
    return [l containsString:@"ad"] || [l containsString:@"splash"] || [l containsString:@"launch"];
}
// 会动手点跳过（范围窄，防误伤）
static BOOL YTIsAdLike(NSString *cn) {
    NSString *l = cn.lowercaseString;
    for (NSString *k in @[@"splash", @"launchad", @"bootad", @"openad", @"startad",
                          @"adview", @"advc", @"advert", @"welcomead", @"adsplash"]) {
        if ([l containsString:k]) return YES;
    }
    return NO;
}

static void YTTrySkip(UIViewController *vc) {
    for (NSString *k in @[@"skipButton", @"skipBtn", @"closeButton", @"closeBtn",
                          @"jumpButton", @"countDownButton", @"skipView"]) {
        id obj = nil;
        @try { obj = [vc valueForKey:k]; } @catch (NSException *e) { continue; }
        if ([obj isKindOfClass:UIButton.class]) {
            UIButton *b = (UIButton *)obj;
            if (!b.hidden && b.userInteractionEnabled) {
                [b sendActionsForControlEvents:UIControlEventTouchUpInside];
                YTLog([NSString stringWithFormat:@"TRYSKIP %@ btn=%@",
                       NSStringFromClass(vc.class), k]);
                return;
            }
        }
    }
    YTLog([NSString stringWithFormat:@"NOSKIP %@", NSStringFromClass(vc.class)]);
}

static void YTSwizzle(Class c, SEL orig, SEL repl) {
    Method m1 = class_getInstanceMethod(c, orig), m2 = class_getInstanceMethod(c, repl);
    if (!m1 || !m2) return;
    if (class_addMethod(c, orig, method_getImplementation(m2), method_getTypeEncoding(m2)))
        class_replaceMethod(c, repl, method_getImplementation(m1), method_getTypeEncoding(m1));
    else method_exchangeImplementations(m1, m2);
}

static void YTStubMotion(void) {
    Class cm = CMMotionManager.class;
    SEL sels[] = {@selector(startAccelerometerUpdatesToQueue:withHandler:),
                  @selector(startGyroUpdatesToQueue:withHandler:),
                  @selector(startDeviceMotionUpdatesToQueue:withHandler:)};
    for (int i = 0; i < 3; i++) {
        Method m = class_getInstanceMethod(cm, sels[i]);
        if (m) method_setImplementation(m, imp_implementationWithBlock(^(id s, id q, id h) {
            YTLog(@"MOTION blocked");
        }));
    }
}

static UIWindow *YTKeyWindow(void) {
    for (UIScene *sc in UIApplication.sharedApplication.connectedScenes) {
        if ([sc isKindOfClass:UIWindowScene.class] &&
            ((UIWindowScene *)sc).activationState == UISceneActivationStateForegroundActive)
            for (UIWindow *w in ((UIWindowScene *)sc).windows) if (w.isKeyWindow) return w;
    }
    return nil;
}

static void YTShowReport(void) {
    NSString *text = gReport.length ? gReport : @"(未发现疑似开屏 VC)";
    UIPasteboard.generalPasteboard.string = text;
    UIViewController *top = YTKeyWindow().rootViewController;
    while (top.presentedViewController) top = top.presentedViewController;
    if (!top) { YTLog(@"no root vc"); return; }
    UIAlertController *ac = [UIAlertController alertControllerWithTitle:@"YTProbe 报告"
        message:text preferredStyle:UIAlertControllerStyleAlert];
    [ac addAction:[UIAlertAction actionWithTitle:@"已复制，关闭" style:UIAlertActionStyleDefault handler:nil]];
    [top presentViewController:ac animated:YES completion:nil];
}

@interface UIViewController (YTProbe)
- (void)ytprobe_viewDidAppear:(BOOL)animated;
- (void)ytprobe_motionBegan:(UIEventSubtype)motion withEvent:(UIEvent *)event;
@end
@implementation UIViewController (YTProbe)
- (void)ytprobe_viewDidAppear:(BOOL)animated {
    [self ytprobe_viewDidAppear:animated];
    NSString *cn = NSStringFromClass(self.class);
    if (!YTIsSuspect(cn)) return;
    YTLog([NSString stringWithFormat:@"VC %@", cn]);
    if (YTIsAdLike(cn)) YTTrySkip(self);
}
- (void)ytprobe_motionBegan:(UIEventSubtype)motion withEvent:(UIEvent *)event {
    if (motion == UIEventSubtypeMotionShake && YTIsAdLike(NSStringFromClass(self.class))) {
        YTLog(@"SHAKE blocked"); return;
    }
    [self ytprobe_motionBegan:motion withEvent:event];
}
@end

__attribute__((constructor))
static void YTEntry(void) {
    @autoreleasepool {
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(1.0 * NSEC_PER_SEC)),
                       dispatch_get_main_queue(), ^{
            YTSwizzle(UIViewController.class, @selector(viewDidAppear:), @selector(ytprobe_viewDidAppear:));
            YTSwizzle(UIViewController.class, @selector(motionBegan:withEvent:), @selector(ytprobe_motionBegan:));
            YTStubMotion();
            YTLog(@"probe installed");
            dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(8.0 * NSEC_PER_SEC)),
                           dispatch_get_main_queue(), ^{ YTShowReport(); });
        });
    }
}
