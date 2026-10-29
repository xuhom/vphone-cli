#import <Foundation/Foundation.h>
#import <CoreGraphics/CoreGraphics.h>
#import <objc/message.h>
#import <objc/runtime.h>
#include <unistd.h>

typedef struct {
    CGSize size;
    CGFloat scale;
    uint8_t orientation;
    CGRect bounds;
} VPhoneDuoDisplayGeometry;
_Static_assert(sizeof(VPhoneDuoDisplayGeometry) == 64, "BackBoard display geometry ABI");
typedef struct { double values[16]; } VPhoneDuoDisplayTransform;
_Static_assert(sizeof(VPhoneDuoDisplayTransform) == 128, "BackBoard layer transform ABI");

// The VM has one digitizer. Its events use the default (nil) display identity,
// whereas the fixed-inner scanout has V68's explicit display1 UUID. BackBoard's
// nil-display cache then misses, before UIKit can receive or hit-test the touch.
static id VPhoneDuoTouchDisplayID(id identifier) {
    if (identifier) return identifier;
    @try {
        Class displayClass = NSClassFromString(@"CADisplay");
        id display = ((id (*)(id, SEL))objc_msgSend)(displayClass, sel_registerName("mainDisplay"));
        NSString *uuid = [[display valueForKey:@"UUID"] description];
        if ([uuid isEqualToString:@"BF0DC480-5EE2-4EC1-B02B-C75E94759832"])
            return uuid;
    } @catch (__unused NSException *exception) {}
    return identifier;
}

__attribute__((constructor)) static void VPhoneDuoTouchDisplayStart(void) {
    if (strcmp(getprogname(), "backboardd") != 0) return;
    Class attributes = NSClassFromString(@"BKSHIDEventDigitizerAttributes");
    SEL displaySelector = sel_registerName("display");
    Method displayMethod = class_getInstanceMethod(attributes, displaySelector);
    if (displayMethod) {
        id (*original)(id, SEL) = (void *)method_getImplementation(displayMethod);
        IMP replacement = imp_implementationWithBlock(^id(id object) {
            id display = original(object, displaySelector);
            SEL builtin = sel_registerName("_isBuiltinDisplay");
            BOOL isBuiltin = !display || ([display respondsToSelector:builtin]
                && ((BOOL (*)(id, SEL))objc_msgSend)(display, builtin));
            id uuid = isBuiltin ? VPhoneDuoTouchDisplayID(nil) : nil;
            Class eventDisplay = NSClassFromString(@"BKSHIDEventDisplay");
            SEL factory = sel_registerName("displayWithHardwareIdentifier:");
            if (uuid && [eventDisplay respondsToSelector:factory])
                return ((id (*)(id, SEL, id))objc_msgSend)(eventDisplay, factory, uuid);
            return display;
        });
        // `display` is inherited from the common event attributes. Restrict
        // the mapping to digitizers, preserving keyboard/pointer semantics.
        if (!class_addMethod(attributes, displaySelector, replacement, method_getTypeEncoding(displayMethod)))
            method_setImplementation(displayMethod, replacement);
    }
    Class controller = NSClassFromString(@"BKDisplayController");
    SEL geometrySelector = sel_registerName("geometryForDisplayUUID:");
    Method geometryMethod = class_getInstanceMethod(controller, geometrySelector);
    if (geometryMethod) {
        VPhoneDuoDisplayGeometry (*original)(id, SEL, id) = (void *)method_getImplementation(geometryMethod);
        IMP replacement = imp_implementationWithBlock(^VPhoneDuoDisplayGeometry(id object, id uuid) {
            return original(object, geometrySelector, VPhoneDuoTouchDisplayID(uuid));
        });
        method_setImplementation(geometryMethod, replacement);
    }
    SEL lookupSelector = sel_registerName("displayForUUID:");
    Method lookupMethod = class_getInstanceMethod(controller, lookupSelector);
    if (lookupMethod) {
        id (*original)(id, SEL, id) = (void *)method_getImplementation(lookupMethod);
        IMP replacement = imp_implementationWithBlock(^id(id object, id uuid) {
            return original(object, lookupSelector, VPhoneDuoTouchDisplayID(uuid));
        });
        method_setImplementation(lookupMethod, replacement);
    }
    SEL hostSelector = sel_registerName("hostTargetIDForEmbeddedTargetID:displayUUID:");
    Method hostMethod = class_getInstanceMethod(controller, hostSelector);
    if (hostMethod) {
        uint32_t (*original)(id, SEL, uint32_t, id) = (void *)method_getImplementation(hostMethod);
        IMP replacement = imp_implementationWithBlock(^uint32_t(id object, uint32_t target, id uuid) {
            return original(object, hostSelector, target, VPhoneDuoTouchDisplayID(uuid));
        });
        method_setImplementation(hostMethod, replacement);
    }
    SEL transformSelector = sel_registerName("transformFromLayerId:contextID:displayUUID:");
    Method transformMethod = class_getInstanceMethod(controller, transformSelector);
    if (transformMethod) {
        VPhoneDuoDisplayTransform (*original)(id, SEL, id, id, id) = (void *)method_getImplementation(transformMethod);
        IMP replacement = imp_implementationWithBlock(^VPhoneDuoDisplayTransform(id object, id layer, id context, id uuid) {
            return original(object, transformSelector, layer, context, VPhoneDuoTouchDisplayID(uuid));
        });
        method_setImplementation(transformMethod, replacement);
    }
    for (NSString *name in @[@"convertReferenceLocation:toScreenLocationForDisplayUUID:",
                             @"convertScreenLocation:toReferenceLocationForDisplayUUID:"]) {
        SEL selector = NSSelectorFromString(name);
        Method method = class_getInstanceMethod(controller, selector);
        if (!method) continue;
        CGPoint (*original)(id, SEL, CGPoint, id) = (void *)method_getImplementation(method);
        IMP replacement = imp_implementationWithBlock(^CGPoint(id object, CGPoint point, id uuid) {
            return original(object, selector, point, VPhoneDuoTouchDisplayID(uuid));
        });
        method_setImplementation(method, replacement);
    }
    for (NSString *name in @[@"convertContextLocation:inTargetID:toScreenLocationForDisplayUUID:",
                             @"convertScreenLocation:toTargetID:displayUUID:"]) {
        SEL selector = NSSelectorFromString(name);
        Method method = class_getInstanceMethod(controller, selector);
        if (!method) continue;
        CGPoint (*original)(id, SEL, CGPoint, uint32_t, id) = (void *)method_getImplementation(method);
        IMP replacement = imp_implementationWithBlock(^CGPoint(id object, CGPoint point, uint32_t target, id uuid) {
            return original(object, selector, point, target, VPhoneDuoTouchDisplayID(uuid));
        });
        method_setImplementation(method, replacement);
    }
    SEL selector = sel_registerName("targetIDAtScreenLocation:displayUUID:options:securityAnalysis:results:");
    Method method = class_getInstanceMethod(controller, selector);
    if (method) {
        BOOL (*original)(id, SEL, CGPoint, id, id, id *, void *) = (void *)method_getImplementation(method);
        IMP replacement = imp_implementationWithBlock(^BOOL(id object, CGPoint point, id uuid, id options,
                                                            id *analysis, void *results) {
            BOOL hit = original(object, selector, point, VPhoneDuoTouchDisplayID(uuid), options, analysis, results);
            return hit;
        });
        method_setImplementation(method, replacement);
    }
    selector = sel_registerName("getClientTaskNamePort:clientConnectionIdentifier:forTargetID:displayUUID:");
    method = class_getInstanceMethod(controller, selector);
    if (method) {
        SEL taskSelector = selector;
        void (*original)(id, SEL, uint32_t *, uint64_t *, uint32_t, id) = (void *)method_getImplementation(method);
        IMP replacement = imp_implementationWithBlock(^(id object, uint32_t *port, uint64_t *connection,
                                                       uint32_t target, id uuid) {
            original(object, taskSelector, port, connection, target, VPhoneDuoTouchDisplayID(uuid));
        });
        method_setImplementation(method, replacement);
    }
}
