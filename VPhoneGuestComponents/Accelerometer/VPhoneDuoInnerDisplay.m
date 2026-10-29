#import <Foundation/Foundation.h>
#import <objc/message.h>
#import <objc/runtime.h>
#include <unistd.h>

// A fixed-inner VM has one scanout carrying V68 display1's real identifier.
// Never apply these single-panel compatibility rules to a Duo cover or another
// device. SBS display class 25 is distinct from UIKit's legacy screen types.
static NSString *const VPhoneDuoInnerIdentifier = @"BF0DC480-5EE2-4EC1-B02B-C75E94759832";

static BOOL VPhoneDuoMainIsInner(void) {
    @try {
        id display = ((id (*)(id, SEL))objc_msgSend)(NSClassFromString(@"CADisplay"), sel_registerName("mainDisplay"));
        return [[[[display valueForKey:@"UUID"] description] uppercaseString] isEqual:VPhoneDuoInnerIdentifier];
    } @catch (__unused NSException *exception) { return NO; }
}

static BOOL VPhoneDuoInnerScene(id scene) {
    @try {
        id configuration = [[scene valueForKey:@"screen"] valueForKey:@"displayConfiguration"];
        return [[configuration valueForKey:@"hardwareIdentifier"] isEqual:VPhoneDuoInnerIdentifier];
    } @catch (__unused NSException *exception) { return NO; }
}

static NSInteger (*originalResolverSurface)(id, SEL, id);
static NSInteger (*originalSceneSurface)(id, SEL);
static NSInteger VPhoneDuoSceneSurface(id scene, SEL selector) {
    return VPhoneDuoInnerScene(scene) ? 2 : originalSceneSurface(scene, selector);
}
static NSInteger VPhoneDuoResolverSurface(id resolver, SEL selector, id scene) {
    return VPhoneDuoInnerScene(scene) ? 2 : originalResolverSurface(resolver, selector, scene);
}

static void (*originalStartResolving)(id, SEL, id);
static void VPhoneDuoStartResolving(id resolver, SEL selector, id proxy) {
    originalStartResolving(resolver, selector, proxy);
    @try {
        // Native resolution waits for cover + inner. Admit only this exact
        // one-inner topology, using the existing primary-content resolver.
        NSDictionary *displays = [resolver valueForKey:@"_displayProxies"];
        if (displays.count != 1 || ![[proxy valueForKey:@"identifier"] isEqual:VPhoneDuoInnerIdentifier]
            || [[proxy valueForKey:@"surfaceType"] integerValue] != 2
            || [[resolver valueForKey:@"_isReadyToResolve"] boolValue]) return;
        [resolver setValue:@YES forKey:@"_isReadyToResolve"];
        ((void (*)(id, SEL))objc_msgSend)(resolver, sel_registerName("_updateResolvedContentModesForDisplays"));
    } @catch (NSException *exception) {
        NSLog(@"[duo] Fixed-inner content resolution unavailable: %@", exception.name);
    }
}

__attribute__((constructor)) static void VPhoneDuoInnerDisplayStart(void) {
    if (strcmp(getprogname(), "SpringBoard") != 0) return;
    Class context = NSClassFromString(@"SBSDisplayConfigurationContext");
    SEL selector = sel_registerName("contextFromFBSDisplayConfiguration:screenClass:");
    Method method = class_getClassMethod(context, selector);
    if (method) {
        id (*original)(id, SEL, id, NSInteger) = (void *)method_getImplementation(method);
        method_setImplementation(method, imp_implementationWithBlock(^id(id object, id configuration, NSInteger screenClass) {
            BOOL inner = [[configuration valueForKey:@"hardwareIdentifier"] isEqual:VPhoneDuoInnerIdentifier];
            return original(object, selector, configuration, inner ? 25 : screenClass);
        }));
    }
    Class resolver = NSClassFromString(@"SBFDisplayContentModeResolver");
    Method resolverSurface = class_getInstanceMethod(resolver, sel_registerName("_surfaceTypeForWindowScene:"));
    Method start = class_getInstanceMethod(resolver, sel_registerName("_startResolvingContentModeOfDisplay:"));
    if (resolverSurface && start
        && class_getInstanceVariable(resolver, "_isReadyToResolve")
        && class_getInstanceVariable(resolver, "_displayProxies")
        && [resolver instancesRespondToSelector:sel_registerName("_updateResolvedContentModesForDisplays")]) {
        originalResolverSurface = (void *)method_setImplementation(resolverSurface, (IMP)VPhoneDuoResolverSurface);
        originalStartResolving = (void *)method_setImplementation(start, (IMP)VPhoneDuoStartResolving);
    }
    method = class_getInstanceMethod(NSClassFromString(@"SBWindowScene"), sel_registerName("surfaceType"));
    if (method) originalSceneSurface = (void *)method_setImplementation(method, (IMP)VPhoneDuoSceneSurface);
}

__attribute__((constructor)) static void VPhoneDuoSyntheticPoseStart(void) {
    if (strcmp(getprogname(), "SpringBoard") != 0) return;
    // The legacy test initializer leaves iOS 27's per-panel/stability fields
    // ambiguous. Complete missing fields on synthetic requests only; real
    // motion events and explicitly supplied fields retain their native values.
    Class synthetic = NSClassFromString(@"SBFSyntheticMagicPoseEvent");
    for (NSString *name in @[@"deviceOrientation0", @"deviceOrientation1", @"stableOrientationState"]) {
        SEL selector = NSSelectorFromString(name);
        Method method = class_getInstanceMethod(synthetic, selector);
        if (!method) continue;
        NSInteger (*original)(id, SEL) = (void *)method_getImplementation(method);
        IMP replacement = imp_implementationWithBlock(^NSInteger(id object) {
            NSInteger value = original(object, selector);
            if (value == 0 && VPhoneDuoMainIsInner())
                return [name isEqualToString:@"stableOrientationState"] ? 1
                    : ((NSInteger (*)(id, SEL))objc_msgSend)(object, sel_registerName("deviceOrientation"));
            return value;
        });
        // An inherited getter belongs to real CMMagicPoseEvent too.
        if (!class_addMethod(synthetic, selector, replacement, method_getTypeEncoding(method)))
            method_setImplementation(method, replacement);
    }
    Class manager = NSClassFromString(@"CMMagicPoseManager");
    SEL selector = sel_registerName("orientationForMagicPose:deviceSurface:");
    Method method = class_getClassMethod(manager, selector);
    if (method) {
        NSInteger (*original)(id, SEL, id, NSInteger) = (void *)method_getImplementation(method);
        method_setImplementation(method, imp_implementationWithBlock(^NSInteger(id object, id pose, NSInteger surface) {
            NSInteger orientation = original(object, selector, pose, surface);
            // The research board cannot resolve the synthetic inner surface.
            // Leave any future native resolution intact, including real events.
            if (orientation == 0 && surface == 2 && VPhoneDuoMainIsInner()
                && [pose isKindOfClass:synthetic])
                return ((NSInteger (*)(id, SEL))objc_msgSend)(pose, sel_registerName("deviceOrientation"));
            return orientation;
        }));
    }
}
