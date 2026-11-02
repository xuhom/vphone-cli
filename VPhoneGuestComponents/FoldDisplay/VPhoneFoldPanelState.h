#pragma once
#import <Foundation/Foundation.h>
#include <limits.h>
#include <unistd.h>

// Published only by SpringBoard's actual primary-content ownership callback.
// The hinge preference is a requested target and cannot substitute for this.
#define VP_FOLD_PANEL_DOMAIN "com.vphone.folddisplay"
#define VP_FOLD_PANEL_KEY "PanelOwner"

static inline NSDictionary *VPhoneFoldPanelRecord(BOOL inner, pid_t pid) {
    return @{@"inner": @(inner), @"pid": @(pid)};
}

static inline BOOL VPhoneFoldPanelDecode(id record, BOOL *inner, pid_t *pid) {
    if (![record isKindOfClass:NSDictionary.class]) return NO;
    id owner = record[@"inner"], process = record[@"pid"];
    if (![owner isKindOfClass:NSNumber.class] || CFGetTypeID((__bridge CFTypeRef)owner) != CFBooleanGetTypeID() ||
        ![process isKindOfClass:NSNumber.class] || CFGetTypeID((__bridge CFTypeRef)process) == CFBooleanGetTypeID())
        return NO;
    double value = [process doubleValue];
    if (value < 1 || value > INT_MAX || value != [process intValue]) return NO;
    *inner = [owner boolValue];
    *pid = [process intValue];
    return YES;
}
