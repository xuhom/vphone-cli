#import <Foundation/Foundation.h>
#import <CoreGraphics/CoreGraphics.h>
#import <objc/message.h>
#import <objc/runtime.h>
#include <unistd.h>

// This library also loads in backboardd: do not link UIKit or declare a UIKit
// subclass. The fallback belongs only to the fixed-inner SpringBoard Home.
@protocol VPhoneDuoWallpaperView <NSObject>
@property CGRect frame;
@property (readonly) CGRect bounds;
@property (readonly) NSArray *subviews;
@property (readonly) id superview;
@property BOOL hidden;
@property BOOL userInteractionEnabled;
@property BOOL accessibilityElementsHidden;
@property BOOL clipsToBounds;
@property NSUInteger autoresizingMask;
@property NSInteger contentMode;
@property id image;
- (void)insertSubview:(id)view atIndex:(NSInteger)index;
- (void)removeFromSuperview;
@end

static char VPhoneDuoHomeWallpaperKey;

static BOOL VPhoneDuoWallpaperIsInner(void) {
    id display = ((id (*)(id, SEL))objc_msgSend)(NSClassFromString(@"CADisplay"), sel_registerName("mainDisplay"));
    return [[[[display valueForKey:@"UUID"] description] uppercaseString]
        isEqualToString:@"BF0DC480-5EE2-4EC1-B02B-C75E94759832"];
}

// Home uses a cached native snapshot even when no renderer FBScene exists.
// Read the UIImage already supplied to that snapshot view; do not select a
// wallpaper file, alter its cache, or accidentally copy Lock's clock layers.
static id VPhoneDuoSnapshotImage(id<VPhoneDuoWallpaperView> view, BOOL inSnapshot, NSUInteger depth) {
    if (!view || depth > 16) return nil;
    inSnapshot |= [view isKindOfClass:NSClassFromString(@"PBUISnapshotReplicaView")];
    if (inSnapshot && [view isKindOfClass:NSClassFromString(@"UIImageView")]) {
        id image = view.image;
        if ([image isKindOfClass:NSClassFromString(@"UIImage")]) return image;
    }
    for (id child in view.subviews) {
        id image = VPhoneDuoSnapshotImage(child, inSnapshot, depth + 1);
        if (image) return image;
    }
    return nil;
}

static id VPhoneDuoHomeSnapshot(id controller, NSUInteger depth) {
    if (!controller || depth > 16) return nil;
    if ([controller isKindOfClass:NSClassFromString(@"PBUIPosterHomeViewController")]) {
        // viewIfLoaded avoids constructing an inactive wallpaper hierarchy.
        return VPhoneDuoSnapshotImage([controller valueForKey:@"viewIfLoaded"], NO, 0);
    }
    for (id child in [controller valueForKey:@"childViewControllers"]) {
        id image = VPhoneDuoHomeSnapshot(child, depth + 1);
        if (image) return image;
    }
    return nil;
}

static void VPhoneDuoUpdateHomeWallpaper(id window, id image) {
    id<VPhoneDuoWallpaperView> background = objc_getAssociatedObject(window, &VPhoneDuoHomeWallpaperKey);
    id<VPhoneDuoWallpaperView> root = [[window valueForKey:@"rootViewController"] valueForKey:@"viewIfLoaded"];
    if (!root || !image || root.bounds.size.width <= 0 || root.bounds.size.height <= 0) {
        // An absent snapshot must reveal the native wallpaper, not stale art.
        [background removeFromSuperview];
        objc_setAssociatedObject(window, &VPhoneDuoHomeWallpaperKey, nil, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        return;
    }
    if (!background) {
        id allocated = ((id (*)(id, SEL))objc_msgSend)(NSClassFromString(@"UIImageView"), sel_registerName("alloc"));
        background = ((id (*)(id, SEL, CGRect))objc_msgSend)(allocated, sel_registerName("initWithFrame:"), root.bounds);
        background.userInteractionEnabled = NO;
        background.accessibilityElementsHidden = YES;
        background.clipsToBounds = YES;
        background.contentMode = 2; // UIViewContentModeScaleAspectFill
        background.autoresizingMask = (1 << 1) | (1 << 4); // flexible width/height
        objc_setAssociatedObject(window, &VPhoneDuoHomeWallpaperKey, background, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    }
    if (background.superview != root) {
        [background removeFromSuperview];
        [root insertSubview:background atIndex:0];
    }
    CGRect frame = background.frame, bounds = root.bounds;
    if (frame.origin.x != bounds.origin.x || frame.origin.y != bounds.origin.y
        || frame.size.width != bounds.size.width || frame.size.height != bounds.size.height)
        background.frame = bounds;
    if (background.image != image) background.image = image;
    background.hidden = NO;
}

static void VPhoneDuoRefreshHomeWallpaper(void) {
    @try {
        if (!VPhoneDuoWallpaperIsInner()) return;
        id app = ((id (*)(id, SEL))objc_msgSend)(NSClassFromString(@"UIApplication"), sel_registerName("sharedApplication"));
        for (id scene in [app valueForKey:@"connectedScenes"]) {
            if (![scene isKindOfClass:NSClassFromString(@"UIWindowScene")]) continue;
            NSArray *windows = [scene valueForKey:@"windows"];
            id image = nil;
            for (id window in windows) {
                if ([window isKindOfClass:NSClassFromString(@"_SBWallpaperSecureWindow")]) {
                    image = VPhoneDuoHomeSnapshot([window valueForKey:@"rootViewController"], 0);
                    if (image) break;
                }
            }
            for (id window in windows) {
                if ([window isKindOfClass:NSClassFromString(@"SBHomeScreenWindow")])
                    VPhoneDuoUpdateHomeWallpaper(window, image);
            }
        }
    } @catch (NSException *exception) {
        static BOOL reported;
        if (!reported) { NSLog(@"[duo] Home wallpaper unavailable: %@", exception.name); reported = YES; }
    }
}

__attribute__((constructor)) static void VPhoneDuoHomeWallpaperStart(void) {
    if (strcmp(getprogname(), "SpringBoard")) return;
    // A small controller/snapshot subtree, once per second. Rotation sizing is
    // handled by Home's existing UIKit layout; unchanged images aren't copied.
    // Polling also picks up a newly selected wallpaper after its async snapshot
    // arrives, without hooks into private cache production or global rotation.
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, 3 * NSEC_PER_SEC), dispatch_get_main_queue(), ^{
        static dispatch_source_t timer;
        timer = dispatch_source_create(DISPATCH_SOURCE_TYPE_TIMER, 0, 0, dispatch_get_main_queue());
        dispatch_source_set_timer(timer, DISPATCH_TIME_NOW, NSEC_PER_SEC, NSEC_PER_SEC / 10);
        dispatch_source_set_event_handler(timer, ^{ VPhoneDuoRefreshHomeWallpaper(); });
        dispatch_resume(timer);
    });
}
