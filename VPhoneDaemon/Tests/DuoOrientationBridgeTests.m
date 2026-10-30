#import <Foundation/Foundation.h>
#include <assert.h>
#include <stdio.h>

static id testDisplay;
static NSUInteger originalReads;
@interface DuoTestDisplay : NSObject
@property NSUUID *UUID;
@property NSString *currentOrientation;
+ (id)mainDisplay;
@end
@implementation DuoTestDisplay
+ (id)mainDisplay { return testDisplay; }
@end
@interface DuoTestAXServer : NSObject
- (long)activeInterfaceOrientation;
@end
@implementation DuoTestAXServer
- (long)activeInterfaceOrientation { originalReads++; return 2; }
@end
@interface DuoTestMotionManager : NSObject
+ (BOOL)isAvailable;
@end
@implementation DuoTestMotionManager
+ (BOOL)isAvailable { return YES; }
@end
static Class testClass(NSString *name) {
    if ([name isEqual:@"CADisplay"]) return DuoTestDisplay.class;
    if ([name isEqual:@"AXSpringBoardServer"]) return DuoTestAXServer.class;
    if ([name isEqual:@"CMAngleManager"] || [name isEqual:@"CMDeviceStateManager"])
        return DuoTestMotionManager.class;
    return NSClassFromString(name);
}
#define NSClassFromString(name) testClass(name)
#include "../Native/vphoned_pose.m"
#undef NSClassFromString

int main(void) { @autoreleasepool {
    vp_duo_prepare_orientation();
    vp_duo_prepare_orientation();
    DuoTestAXServer *server = [DuoTestAXServer new];
    assert([server activeInterfaceOrientation] == 2);
    DuoTestDisplay *display = [DuoTestDisplay new];
    testDisplay = display;
    display.UUID = NSUUID.UUID;
    display.currentOrientation = @"rot90";
    assert(vp_core_motion_hinge());
    assert([server activeInterfaceOrientation] == 2);
    display.UUID = [[NSUUID alloc] initWithUUIDString:@"BF0DC480-5EE2-4EC1-B02B-C75E94759832"];
    assert(!vp_core_motion_hinge());
    NSArray *values = @[@"rot0", @"rot90", @"rot180", @"rot270"];
    long expected[] = {1, 4, 2, 3};
    for (NSUInteger i = 0; i < values.count; i++) {
        display.currentOrientation = values[i];
        assert([server activeInterfaceOrientation] == expected[i]);
    }
    assert(originalReads == 2);
    display.currentOrientation = @"unknown";
    assert([server activeInterfaceOrientation] == 2);
    assert(originalReads == 3);
    display.UUID = NSUUID.UUID;
    assert(vp_core_motion_hinge());
    puts("Duo AX orientation bridge: four rotations, fallback, repeated preparation and fixed/relayed mode isolation passed");
} }
