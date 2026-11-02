#import "../FoldDisplay/VPhoneFoldPanelState.h"
#include <assert.h>
#include <math.h>
#include <stdio.h>

int main(void) {
    @autoreleasepool {
        for (NSNumber *value in @[@NO, @YES]) {
            NSDictionary *record = VPhoneFoldPanelRecord(value.boolValue, getpid());
            NSData *wire = [NSPropertyListSerialization dataWithPropertyList:record
                format:NSPropertyListBinaryFormat_v1_0 options:0 error:nil];
            id decoded = [NSPropertyListSerialization propertyListWithData:wire options:0 format:nil error:nil];
            BOOL inner = !value.boolValue;
            pid_t pid = 0;
            assert(VPhoneFoldPanelDecode(decoded, &inner, &pid));
            assert(inner == value.boolValue && pid == getpid());
        }
        NSArray *invalid = @[
            @{}, @"inner", @{@"inner": @YES}, @{@"pid": @10},
            @{@"inner": @1, @"pid": @10}, @{@"inner": @"cover", @"pid": @10},
            @{@"inner": @YES, @"pid": @YES}, @{@"inner": @NO, @"pid": @0},
            @{@"inner": @YES, @"pid": @-1}, @{@"inner": @NO, @"pid": @1.5},
            @{@"inner": @YES, @"pid": @(INFINITY)}, @{@"inner": @YES, @"pid": @(NAN)},
            @{@"inner": @YES, @"pid": @((double)INT_MAX + 1)},
        ];
        for (id record in invalid) {
            BOOL inner = NO;
            pid_t pid = 0;
            assert(!VPhoneFoldPanelDecode(record, &inner, &pid));
        }
        puts("fold panel ownership protocol tests passed");
    }
    return 0;
}
