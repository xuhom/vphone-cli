/*
 * vphoned_pose — set a foldable guest's device pose.
 *
 * A VM has no hinge, and SpringBoard only consumes CoreMotion's hinge angle
 * and magic pose on a board CoreMotion recognizes with two always-connected
 * displays. SpringBoardServices' test-automation client sets the pose
 * directly: SpringBoard builds a synthetic magic pose from the device
 * orientation, hinge state and tabletop pose, and derives the hinge angle
 * from the hinge state. The server checks the client for
 * com.apple.springboard.testautomation, which vphoned carries.
 *
 * The class is resolved at run time, so a base without it reports false.
 */

#import "Include/VphonedNative.h"

#include <dlfcn.h>
#include <objc/message.h>

/// The override `-[SBSTestAutomationService setDevicePoseOverride:]` takes, as
/// SpringBoard's handler reads it: a 64-bit orientation, then the device
/// orientation, hinge state and tabletop pose as 32-bit values.
typedef struct {
    int64_t orientation;
    int32_t deviceOrientation;
    int32_t hingeState;
    int32_t tabletopPose;
} VPDevicePoseOverride;

bool vp_device_pose_set(int deviceOrientation, int hingeState, int tabletopPose) {
    static Class service;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        dlopen("/System/Library/PrivateFrameworks/SpringBoardServices.framework/SpringBoardServices", RTLD_NOW);
        service = NSClassFromString(@"SBSTestAutomationService");
    });
    SEL selector = NSSelectorFromString(@"setDevicePoseOverride:");
    if (!service || ![service instancesRespondToSelector:selector]) return false;
    id client = [service new];
    VPDevicePoseOverride pose = {deviceOrientation, deviceOrientation, hingeState, tabletopPose};
    ((void (*)(id, SEL, VPDevicePoseOverride))objc_msgSend)(client, selector, pose);
    return true;
}

// AX's legacy activeInterfaceOrientation can keep reporting the cover's
// portrait orientation while the Duo inner compositor is landscape. Icli's
// capture geometry and touch conversion use that same client, so correct its
// readback locally rather than rotate an already transformed screenshot.
#import <objc/runtime.h>
static NSString *const VPDuoInnerIdentifier = @"BF0DC480-5EE2-4EC1-B02B-C75E94759832";
static id VPDuoMainDisplay(void) {
    Class cls = NSClassFromString(@"CADisplay");
    SEL selector = sel_registerName("mainDisplay");
    return [cls respondsToSelector:selector] ? ((id (*)(id, SEL))objc_msgSend)(cls, selector) : nil;
}

bool vp_duo_inner_display(void) {
    @try {
        id display = VPDuoMainDisplay();
        id uuid = [display valueForKey:@"UUID"];
        return [[uuid description] isEqualToString:VPDuoInnerIdentifier];
    } @catch (__unused NSException *exception) {
        return false;
    }
}

static long (*VPOriginalActiveOrientation)(id, SEL);
static long VPDuoActiveOrientation(id object, SEL selector) {
    if (vp_duo_inner_display()) {
        @try {
            id display = VPDuoMainDisplay();
            if ([display respondsToSelector:sel_registerName("update")])
                ((void (*)(id, SEL))objc_msgSend)(display, sel_registerName("update"));
            NSString *rotation = [display valueForKey:@"currentOrientation"];
            if ([rotation isEqual:@"rot0"]) return 1;
            if ([rotation isEqual:@"rot90"]) return 4;
            if ([rotation isEqual:@"rot180"]) return 2;
            if ([rotation isEqual:@"rot270"]) return 3;
        } @catch (__unused NSException *exception) {}
    }
    return VPOriginalActiveOrientation(object, selector);
}

void vp_duo_prepare_orientation(void) {
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        dlopen("/System/Library/Frameworks/QuartzCore.framework/QuartzCore", RTLD_NOW);
        dlopen("/System/Library/PrivateFrameworks/AccessibilityUtilities.framework/AccessibilityUtilities", RTLD_NOW);
        Method method = class_getInstanceMethod(NSClassFromString(@"AXSpringBoardServer"),
            sel_registerName("activeInterfaceOrientation"));
        if (method) {
            VPOriginalActiveOrientation = (void *)method_getImplementation(method);
            method_setImplementation(method, (IMP)VPDuoActiveOrientation);
        }
    });
}
