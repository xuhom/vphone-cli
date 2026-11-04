#import "../FoldDisplay/FoldDisplayPrivate.h"
#include <assert.h>

// This test exercises digitizer routing without creating a render server.
void vpPrepareExternalRenderDisplays(id server) { (void)server; }

@interface InjectedTouchDisplay : NSObject
@property NSString *uniqueId;
@property BOOL enabled;
@property BOOL isBlanked;
@end
@implementation InjectedTouchDisplay
@end

@interface InjectedTouchServer : NSObject
@property NSArray *displays;
+ (id)serverIfRunning;
@end
static InjectedTouchServer *server;
@implementation InjectedTouchServer
+ (id)serverIfRunning { return server; }
@end

static Class injectedTouchClass(const char *name) {
    return strcmp(name, "CAWindowServer") == 0 ? InjectedTouchServer.class : objc_getClass(name);
}
#define objc_getClass injectedTouchClass
#import "../FoldDisplay/FoldDisplayBackboard.m"
#undef objc_getClass

static id injectedUUID;
static id originalDisplayUUID(id object, SEL selector, id service) { return injectedUUID; }

int main(void) { @autoreleasepool {
    server = [InjectedTouchServer new];
    InjectedTouchDisplay *cover = [InjectedTouchDisplay new];
    cover.uniqueId = @"cover";
    InjectedTouchDisplay *inner = [InjectedTouchDisplay new];
    inner.uniqueId = @"inner-current";
    inner.enabled = YES;
    server.displays = @[cover, inner];
    vpInnerRenderDisplay = inner;
    vpOriginalDigitizerDisplayUUID = (IMP)originalDisplayUUID;
    SEL selector = sel_registerName("_queue_displayUUIDForDigitizerService:");
    injectedUUID = @"inner-before-restart";
    assert([vpInnerDigitizerDisplayUUID(nil, selector, nil) isEqual:inner.uniqueId]);
    injectedUUID = cover.uniqueId;
    assert([vpInnerDigitizerDisplayUUID(nil, selector, nil) isEqual:cover.uniqueId]);
    injectedUUID = inner.uniqueId;
    assert([vpInnerDigitizerDisplayUUID(nil, selector, nil) isEqual:inner.uniqueId]);
    injectedUUID = nil;
    assert([vpInnerDigitizerDisplayUUID(nil, selector, nil) isEqual:inner.uniqueId]);
    inner.isBlanked = YES;
    injectedUUID = @"inner-before-restart";
    assert(vpInnerDigitizerDisplayUUID(nil, selector, nil) == nil);
    inner.isBlanked = NO;
    inner.uniqueId = @"inner-after-restart";
    injectedUUID = @"inner-current";
    assert([vpInnerDigitizerDisplayUUID(nil, selector, nil) isEqual:inner.uniqueId]);
    vpInnerRenderDisplay = nil; // Fixed-inner mode never creates a software display.
    assert(vpInnerDigitizerDisplayUUID(nil, selector, nil) == nil);
    puts("Duo injected touch: stale UUID recovery, explicit live IDs, blanking and restart passed");
} }
