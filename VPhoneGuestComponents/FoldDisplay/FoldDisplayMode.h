#pragma once
#import <Foundation/Foundation.h>
#import <objc/message.h>

// Fixed-inner startup assigns display1's UUID to the hardware scanout.
// Upstream folding keeps the cover as Main and adds a software inner display.
static inline BOOL VPhoneIsFixedDuoInnerDisplay(id display) {
    for (NSString *key in @[@"uniqueId", @"UUID"]) {
        SEL selector = NSSelectorFromString(key);
        if (![display respondsToSelector:selector]) continue;
        id identity = ((id (*)(id, SEL))objc_msgSend)(display, selector);
        if ([[[identity description] uppercaseString] isEqualToString:@"BF0DC480-5EE2-4EC1-B02B-C75E94759832"])
            return YES;
    }
    return NO;
}

static inline BOOL VPhoneHasFixedDuoInnerDisplay(id displays) {
    if ([displays isKindOfClass:NSDictionary.class]) displays = [displays allValues];
    if (![displays isKindOfClass:NSArray.class]) return NO;
    for (id display in displays)
        if (VPhoneIsFixedDuoInnerDisplay(display)) return YES;
    return NO;
}
