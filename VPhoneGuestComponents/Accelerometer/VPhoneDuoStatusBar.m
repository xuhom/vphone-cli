#import <Foundation/Foundation.h>
#import <CoreGraphics/CoreGraphics.h>
#import <objc/message.h>
#import <objc/runtime.h>
#include <unistd.h>

// UIKit is resolved at runtime: backboardd also loads this motion library.
@protocol VPhoneDuoStatusBarView <NSObject>
@property CGRect frame;
@property CGRect bounds;
@property (readonly) NSArray *subviews;
@property (readonly, getter=isHidden) BOOL hidden;
@property (readonly) CGFloat alpha;
@end

static char VPhoneDuoHomeSidebarKey;
static char VPhoneDuoHomeOwnerKey;
static char VPhoneDuoSidebarConfiguringKey;
static char VPhoneDuoSidebarLayoutKey;
static BOOL VPhoneDuoSidebarHitEnabled(void) {
    @try {
        id display = ((id (*)(id, SEL))objc_msgSend)(NSClassFromString(@"CADisplay"), sel_registerName("mainDisplay"));
        return [[[[display valueForKey:@"UUID"] description] uppercaseString]
            isEqualToString:@"BF0DC480-5EE2-4EC1-B02B-C75E94759832"];
    } @catch (__unused NSException *exception) { return NO; }
}

static BOOL VPhoneDuoPointInVisibleItem(id<VPhoneDuoStatusBarView> view, CGPoint point, CGFloat canvasArea, int depth) {
    if (depth > 32) return NO;
    for (id<VPhoneDuoStatusBarView> child in view.subviews) {
        if (child.hidden || child.alpha <= 0) continue;
        CGPoint local = ((CGPoint (*)(id, SEL, CGPoint, id))objc_msgSend)(child,
            sel_registerName("convertPoint:fromView:"), point, view);
        CGRect bounds = child.bounds;
        CGFloat area = bounds.size.width * bounds.size.height;
        if (child.subviews.count == 0 && area > 0 && area < canvasArea / 4
            && local.x >= bounds.origin.x && local.y >= bounds.origin.y
            && local.x <= bounds.origin.x + bounds.size.width && local.y <= bounds.origin.y + bounds.size.height)
            return YES;
        if (VPhoneDuoPointInVisibleItem(child, local, canvasArea, depth + 1)) return YES;
    }
    return NO;
}

static void VPhoneDuoInstallSidebarHooks(void) {
    SEL hitSelector = sel_registerName("hitTest:withEvent:");
    for (NSString *name in @[@"SBStatusBarWindow", @"STUIStatusBarForegroundView", @"STUIStatusBar",
                            @"STUIStatusBar_Wrapper", @"SBFStatusBarLegibilityView", @"SBMainDisplaySceneLayoutStatusBarView"]) {
        Class cls = NSClassFromString(name);
        Method method = class_getInstanceMethod(cls, hitSelector);
        if (!method) continue;
        id (*original)(id, SEL, CGPoint, id) = (void *)method_getImplementation(method);
        IMP replacement = imp_implementationWithBlock(^id(id<VPhoneDuoStatusBarView> view, CGPoint point, id event) {
            id<VPhoneDuoStatusBarView> hit = original(view, hitSelector, point, event);
            if (!hit || !VPhoneDuoSidebarHitEnabled()) return hit;
            CGFloat canvasArea = view.bounds.size.width * view.bounds.size.height;
            CGFloat hitArea = hit.bounds.size.width * hit.bounds.size.height;
            if ((hit == view || hitArea >= canvasArea / 2)
                && !VPhoneDuoPointInVisibleItem(view, point, canvasArea, 0)) return nil;
            return hit;
        });
        // Do not replace an inherited UIView implementation globally.
        if (!class_addMethod(cls, hitSelector, replacement, method_getTypeEncoding(method)))
            method_setImplementation(method, replacement);
    }
    Class owner = NSClassFromString(@"SBMainDisplaySceneLayoutStatusBarView");
    SEL frameSelector = sel_registerName("_statusBarFrameForOrientation:");
    Method method = class_getInstanceMethod(owner, frameSelector);
    if (method) {
        CGRect (*original)(id, SEL, NSInteger) = (void *)method_getImplementation(method);
        IMP replacement = imp_implementationWithBlock(^CGRect(id view, NSInteger orientation) {
            if (objc_getAssociatedObject(view, &VPhoneDuoHomeOwnerKey) && VPhoneDuoSidebarHitEnabled()) {
                id window = [view valueForKey:@"window"];
                if (window) {
                    CGRect bounds = ((CGRect (*)(id, SEL))objc_msgSend)(window, sel_registerName("bounds"));
                    CGFloat shortSide = MIN(bounds.size.width, bounds.size.height);
                    CGFloat longSide = MAX(bounds.size.width, bounds.size.height);
                    // The native inner sidebar has a full canvas, not the zero
                    // height returned for an ordinary landscape phone bar.
                    return CGRectMake(0, 0, orientation == 3 || orientation == 4 ? longSide : shortSide,
                        orientation == 3 || orientation == 4 ? shortSide : longSide);
                }
            }
            return original(view, frameSelector, orientation);
        });
        if (!class_addMethod(owner, frameSelector, replacement, method_getTypeEncoding(method)))
            method_setImplementation(method, replacement);
    }
}

static void VPhoneDuoConfigureSidebar(id view, NSInteger orientation) {
    Class statusClass = NSClassFromString(@"STUIStatusBar");
    BOOL status = statusClass && [view isKindOfClass:statusClass];
    BOOL wrapper = [view isKindOfClass:NSClassFromString(@"STUIStatusBar_Wrapper")];
    if (status || wrapper) {
        SEL axis = sel_registerName("setPreferredAxis:");
        if ([view respondsToSelector:axis] && [[view valueForKey:@"preferredAxis"] integerValue] != 2)
            ((void (*)(id, SEL, NSInteger))objc_msgSend)(view, axis, 2);
        SEL turn = sel_registerName("setOrientation:");
        if ([view respondsToSelector:turn] && [[view valueForKey:@"orientation"] integerValue] != orientation)
            ((void (*)(id, SEL, NSInteger))objc_msgSend)(view, turn, orientation);
    }
    if (status) {
        Class provider = NSClassFromString(@"STUIStatusBarVisualProvider_AxisAlignableSplit2853_VM");
        SEL setter = sel_registerName("_setVisualProviderClass:");
        if (provider && [view respondsToSelector:setter]) {
            if ([view valueForKey:@"_visualProviderClass"] != provider)
                ((void (*)(id, SEL, Class))objc_msgSend)(view, setter, provider);
            id current = [view valueForKey:@"_visualProviderIfExists"];
            if (current && ![current isKindOfClass:provider]) {
                // The class setter alone does not replace the cached instance.
                // Reset the native items/regions before preparing its replacement.
                [view setValue:nil forKey:@"_visualProvider"];
                ((void (*)(id, SEL))objc_msgSend)(view, sel_registerName("resetVisualProvider"));
                ((void (*)(id, SEL, Class))objc_msgSend)(view, setter, provider);
                ((void (*)(id, SEL))objc_msgSend)(view, sel_registerName("_prepareVisualProviderIfNeeded"));
                ((void (*)(id, SEL))objc_msgSend)(view, sel_registerName("setNeedsLayout"));
            }
        }
    }
    for (id child in [view valueForKey:@"subviews"]) VPhoneDuoConfigureSidebar(child, orientation);
}

static void VPhoneDuoPrepareSidebar(id view, NSInteger orientation) {
    if (!view || orientation < 1 || orientation > 4 || !VPhoneDuoSidebarHitEnabled()
        || objc_getAssociatedObject(view, &VPhoneDuoSidebarConfiguringKey)) return;
    objc_setAssociatedObject(view, &VPhoneDuoSidebarConfiguringKey, @YES, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    @try {
        VPhoneDuoConfigureSidebar(view, orientation);
    } @catch (NSException *exception) {
        static BOOL reported;
        if (!reported) { NSLog(@"[duo] Sidebar preparation unavailable: %@", exception.name); reported = YES; }
    } @finally {
        objc_setAssociatedObject(view, &VPhoneDuoSidebarConfiguringKey, nil, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    }
}

static NSInteger VPhoneDuoApplicationSidebarOrientation(id bar) {
    if (!VPhoneDuoSidebarHitEnabled()) return 0;
    @try {
        Class appWindowClass = NSClassFromString(@"SBMainSwitcherWindow");
        if (!appWindowClass || ![[bar valueForKey:@"window"] isKindOfClass:appWindowClass]) return 0;
        // The bar's orientation wrapper is a SIBLING of the application scene
        // view. Its own orientation describes that local content space; the
        // enclosing switcher window can still have portrait bounds.
        // Home, Lock, detached pool bars and the legacy window stay untouched.
        NSInteger orientation = [[bar valueForKey:@"orientation"] integerValue];
        return orientation >= 1 && orientation <= 4 ? orientation : 0;
    } @catch (__unused NSException *exception) {}
    return 0;
}

static void VPhoneDuoInstallSidebarLifecycleHooks(void) {
    Class wrapper = NSClassFromString(@"STUIStatusBar_Wrapper");
    for (NSString *name in @[@"didMoveToWindow", @"layoutSubviews"]) {
        SEL selector = NSSelectorFromString(name);
        Method method = class_getInstanceMethod(wrapper, selector);
        if (!method) continue;
        void (*original)(id, SEL) = (void *)method_getImplementation(method);
        IMP replacement = imp_implementationWithBlock(^(id bar) {
            NSInteger orientation = VPhoneDuoApplicationSidebarOrientation(bar);
            if (!orientation || objc_getAssociatedObject(bar, &VPhoneDuoSidebarLayoutKey)) {
                original(bar, selector);
                return;
            }
            objc_setAssociatedObject(bar, &VPhoneDuoSidebarLayoutKey, @YES, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
            @try {
                // Configure before the wrapper's first native layout/attachment
                // commits, including a reused bar already laid out in its pool.
                VPhoneDuoPrepareSidebar(bar, orientation);
                original(bar, selector);
                // Native layout can reset the axis or replace the inner bar.
                VPhoneDuoPrepareSidebar(bar, orientation);
            } @finally {
                objc_setAssociatedObject(bar, &VPhoneDuoSidebarLayoutKey, nil, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
            }
        });
        // didMoveToWindow may be inherited; never swizzle UIView globally.
        if (!class_addMethod(wrapper, selector, replacement, method_getTypeEncoding(method)))
            method_setImplementation(method, replacement);
    }
}

static void VPhoneDuoRefreshSidebars(void) {
    if (!VPhoneDuoSidebarHitEnabled()) return;
    @try {
        id display = ((id (*)(id, SEL))objc_msgSend)(NSClassFromString(@"CADisplay"), sel_registerName("mainDisplay"));
        if ([display respondsToSelector:sel_registerName("update")])
            ((void (*)(id, SEL))objc_msgSend)(display, sel_registerName("update"));
        NSString *turn = [display valueForKey:@"currentOrientation"];
        NSInteger orientation;
        if ([turn isEqualToString:@"rot90"]) orientation = 4;
        else if ([turn isEqualToString:@"rot270"]) orientation = 3;
        else if ([turn isEqualToString:@"rot180"]) orientation = 2;
        else if ([turn isEqualToString:@"rot0"]) orientation = 1;
        else return;
        id app = ((id (*)(id, SEL))objc_msgSend)(NSClassFromString(@"UIApplication"), sel_registerName("sharedApplication"));
        for (id scene in [app valueForKey:@"connectedScenes"]) {
            if (![scene isKindOfClass:NSClassFromString(@"UIWindowScene")]) continue;
            for (id window in [scene valueForKey:@"windows"]) {
                NSString *name = NSStringFromClass([window class]);
                if ([name isEqualToString:@"SBStatusBarWindow"]) {
                    // Scene-based status windows ignore the legacy orientation
                    // setter. Keep this native backing window in the same space.
                    SEL setTurn = sel_registerName("_setStatusBarWindowOrientation:");
                    SEL update = sel_registerName("_updateToInterfaceOrientation:duration:force:");
                    if ([window respondsToSelector:setTurn] && [window respondsToSelector:update]
                        && [[window valueForKey:@"orientation"] integerValue] != orientation) {
                        ((void (*)(id, SEL, NSInteger))objc_msgSend)(window, setTurn, orientation);
                        ((void (*)(id, SEL, NSInteger, double, BOOL))objc_msgSend)(window, update, orientation, 0, YES);
                    }
                    id bar = [window valueForKey:@"statusBar"];
                    [bar setValue:@YES forKey:@"hidden"];
                    [bar setValue:@0 forKey:@"alpha"];
                    VPhoneDuoConfigureSidebar(window, orientation);
                } else if ([name isEqualToString:@"SBHomeScreenWindow"]) {
                    id owner = objc_getAssociatedObject(window, &VPhoneDuoHomeSidebarKey);
                    CGRect bounds = ((CGRect (*)(id, SEL))objc_msgSend)(window, sel_registerName("bounds"));
                    if (!owner) {
                        Class ownerClass = NSClassFromString(@"SBMainDisplaySceneLayoutStatusBarView");
                        if (!ownerClass) continue;
                        id allocated = ((id (*)(id, SEL))objc_msgSend)(ownerClass, sel_registerName("alloc"));
                        owner = ((id (*)(id, SEL, CGRect))objc_msgSend)(allocated, sel_registerName("initWithFrame:"), bounds);
                        if (!owner) continue;
                        objc_setAssociatedObject(owner, &VPhoneDuoHomeOwnerKey, @YES, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
                        objc_setAssociatedObject(window, &VPhoneDuoHomeSidebarKey, owner, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
                        [owner setValue:@18 forKey:@"autoresizingMask"];
                        ((void (*)(id, SEL, id))objc_msgSend)(window, sel_registerName("addSubview:"), owner);
                        // This owner supplies the real state-provider/reuse-pool
                        // lifecycle. A standalone wrapper has no live data here.
                        ((void (*)(id, SEL, id))objc_msgSend)(owner,
                            sel_registerName("beginRequiringStatusBarForReason:"), @"VPhoneFixedInnerHome");
                    }
                    ((void (*)(id, SEL, CGRect))objc_msgSend)(owner, sel_registerName("setFrame:"), bounds);
                    ((void (*)(id, SEL, NSInteger))objc_msgSend)(owner, sel_registerName("setContainerOrientation:"), orientation);
                    ((void (*)(id, SEL, NSInteger))objc_msgSend)(owner,
                        sel_registerName("layoutStatusBarForSpringBoardRotationToOrientation:"), orientation);
                    [owner setValue:@NO forKey:@"hidden"];
                    [owner setValue:@1 forKey:@"alpha"];
                    ((void (*)(id, SEL, id))objc_msgSend)(window, sel_registerName("bringSubviewToFront:"), owner);
                    VPhoneDuoConfigureSidebar(owner, orientation);
                } else if ([name isEqualToString:@"SBMainSwitcherWindow"]
                    || ([name isEqualToString:@"SBCoverSheetWindow"] && ![[window valueForKey:@"hidden"] boolValue])) {
                    VPhoneDuoConfigureSidebar(window, orientation);
                }
            }
        }
    } @catch (NSException *exception) {
        static BOOL reported;
        if (!reported) {
            NSLog(@"[duo] Native sidebar compatibility unavailable: %@", exception.name);
            reported = YES;
        }
    }
}

__attribute__((constructor)) static void VPhoneDuoSidebarStart(void) {
    if (strcmp(getprogname(), "SpringBoard") != 0) return;
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, 3 * NSEC_PER_SEC), dispatch_get_main_queue(), ^{
        VPhoneDuoInstallSidebarHooks();
        VPhoneDuoInstallSidebarLifecycleHooks();
        // Refresh only native status/app-host subtrees, not Home's widgets.
        // Recovery and Home/window rotation only: newly created application bars
        // are configured at attachment/layout inside their application scene.
        static dispatch_source_t timer;
        timer = dispatch_source_create(DISPATCH_SOURCE_TYPE_TIMER, 0, 0, dispatch_get_main_queue());
        dispatch_source_set_timer(timer, DISPATCH_TIME_NOW, NSEC_PER_SEC, NSEC_PER_SEC / 10);
        dispatch_source_set_event_handler(timer, ^{ @autoreleasepool { VPhoneDuoRefreshSidebars(); } });
        dispatch_resume(timer);
    });
}
