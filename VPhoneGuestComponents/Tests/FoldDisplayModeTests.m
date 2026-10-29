#import "../FoldDisplay/FoldDisplayMode.h"
#include <assert.h>

@interface ModeTestDisplay : NSObject
@property id uniqueId;
@property id UUID;
@end
@implementation ModeTestDisplay
@end

int main(void) { @autoreleasepool {
    ModeTestDisplay *cover = [ModeTestDisplay new];
    cover.uniqueId = @"Main";
    ModeTestDisplay *inner = [ModeTestDisplay new];
    inner.uniqueId = [NSUUID UUID];
    assert(!VPhoneHasFixedDuoInnerDisplay(@[cover, inner]));
    ModeTestDisplay *fixed = [ModeTestDisplay new];
    fixed.UUID = [[NSUUID alloc] initWithUUIDString:@"BF0DC480-5EE2-4EC1-B02B-C75E94759832"];
    assert(VPhoneIsFixedDuoInnerDisplay(fixed));
    assert(VPhoneHasFixedDuoInnerDisplay(@[fixed]));
    assert(VPhoneHasFixedDuoInnerDisplay(@{@"primary": fixed}));
    fixed.UUID = nil;
    fixed.uniqueId = @"bf0dc480-5ee2-4ec1-b02b-c75e94759832";
    assert(VPhoneIsFixedDuoInnerDisplay(fixed));
    assert(!VPhoneIsFixedDuoInnerDisplay(nil));
    assert(!VPhoneHasFixedDuoInnerDisplay(nil));
    assert(!VPhoneHasFixedDuoInnerDisplay(@"unavailable"));
    puts("Duo topology isolation: fixed hardware, dynamic cover/inner and absent displays passed");
} }
