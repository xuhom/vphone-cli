#import <Foundation/Foundation.h>
#import <CoreGraphics/CoreGraphics.h>
#include <assert.h>
#import "../Accelerometer/VPhoneDuoStatusBar.m"

@interface SidebarTestView : NSObject <VPhoneDuoStatusBarView>
@property CGRect frame;
@property CGRect bounds;
@property NSArray *subviews;
@property (weak) id superview;
@property BOOL movedToWindow;
- (id)window;
@property (getter=isHidden) BOOL hidden;
@property CGFloat alpha;
- (CGPoint)convertPoint:(CGPoint)point fromView:(id)view;
- (void)nativeSetHidden:(BOOL)hidden;
- (void)didMoveToWindow;
@end
@implementation SidebarTestView
- (instancetype)init {
    if ((self = [super init])) { _subviews = @[]; _alpha = 1; }
    return self;
}
- (CGPoint)convertPoint:(CGPoint)point fromView:(id)view {
    (void)view;
    return (CGPoint){point.x - self.frame.origin.x, point.y - self.frame.origin.y};
}
- (void)nativeSetHidden:(BOOL)hidden { _hidden = hidden; }
- (void)didMoveToWindow { self.movedToWindow = YES; }
- (id)window { return [self.superview window]; }
@end

// Model the observed sibling app/bar branches, which do not contain a
// SBMainDisplaySceneLayoutStatusBarView. Its first layout must see a sidebar.
@interface SidebarTestDisplay : NSObject
@property NSString *UUID;
+ (instancetype)mainDisplay;
@end
@implementation SidebarTestDisplay
+ (instancetype)mainDisplay {
    static SidebarTestDisplay *display;
    if (!display) display = [self new];
    return display;
}
@end
@interface STUIStatusBarVisualProvider_AxisAlignableSplit2853_VM : NSObject @end
@implementation STUIStatusBarVisualProvider_AxisAlignableSplit2853_VM @end
@interface STUIStatusBar : SidebarTestView
@property NSInteger preferredAxis;
@property NSInteger orientation;
@property Class providerClass;
@property id visualProvider;
- (Class)_visualProviderClass;
- (void)_setVisualProviderClass:(Class)cls;
- (id)_visualProviderIfExists;
- (void)resetVisualProvider;
- (void)_prepareVisualProviderIfNeeded;
- (void)setNeedsLayout;
@end
@implementation STUIStatusBar
- (instancetype)init {
    if ((self = [super init])) {
        _preferredAxis = 1;
        _providerClass = [NSObject class];
        _visualProvider = [NSObject new];
    }
    return self;
}
- (Class)_visualProviderClass { return self.providerClass; }
- (void)_setVisualProviderClass:(Class)cls { self.providerClass = cls; }
- (id)_visualProviderIfExists { return self.visualProvider; }
- (void)resetVisualProvider { self.providerClass = [NSObject class]; }
- (void)_prepareVisualProviderIfNeeded { self.visualProvider = [self.providerClass new]; }
- (void)setNeedsLayout {}
@end
@interface STUIStatusBar_Wrapper : SidebarTestView
@property NSInteger preferredAxis;
@property NSInteger orientation;
@property BOOL preparedAtLayout;
@property BOOL replaceBarDuringLayout;
- (void)layoutSubviews;
@end
@implementation STUIStatusBar_Wrapper
- (void)layoutSubviews {
    STUIStatusBar *bar = self.subviews.firstObject;
    self.preparedAtLayout = self.preferredAxis == 2 && bar.preferredAxis == 2
        && self.orientation == bar.orientation
        && [bar.visualProvider isKindOfClass:[STUIStatusBarVisualProvider_AxisAlignableSplit2853_VM class]];
    // A reused wrapper can replace its implementation during native layout.
    if (self.replaceBarDuringLayout) self.subviews = @[[STUIStatusBar new]];
}
@end
@interface SBDeviceApplicationSceneView : SidebarTestView
@property NSInteger orientation;
@end
@implementation SBDeviceApplicationSceneView @end
@interface SBMainSwitcherWindow : SidebarTestView @end
@implementation SBMainSwitcherWindow
- (id)window { return self; }
@end


static STUIStatusBar_Wrapper *makeBar(id parent) {
    STUIStatusBar_Wrapper *wrapper = [STUIStatusBar_Wrapper new];
    wrapper.superview = parent;
    wrapper.preferredAxis = 1;
    wrapper.orientation = 4;
    wrapper.subviews = @[[STUIStatusBar new]];
    return wrapper;
}
static void assertSidebar(STUIStatusBar_Wrapper *wrapper, NSInteger orientation) {
    STUIStatusBar *bar = wrapper.subviews.firstObject;
    assert(bar.preferredAxis == 2 && wrapper.preferredAxis == 2);
    assert(bar.orientation == orientation && wrapper.orientation == orientation);
    assert([bar.visualProvider isKindOfClass:[STUIStatusBarVisualProvider_AxisAlignableSplit2853_VM class]]);
}
static void testSidebarLifecycle(void) {
    Method displayMethod = class_getClassMethod(NSClassFromString(@"CADisplay"), sel_registerName("mainDisplay"));
    assert(displayMethod);
    IMP testDisplay = imp_implementationWithBlock(^id(__unused id cls) { return SidebarTestDisplay.mainDisplay; });
    IMP nativeDisplay = method_setImplementation(displayMethod, testDisplay);
    VPhoneDuoInstallSidebarLifecycleHooks();
    SidebarTestDisplay.mainDisplay.UUID = @"BF0DC480-5EE2-4EC1-B02B-C75E94759832";
    SBMainSwitcherWindow *window = [SBMainSwitcherWindow new];
    SidebarTestView *content = [SidebarTestView new];
    content.superview = window;
    SBDeviceApplicationSceneView *scene = [SBDeviceApplicationSceneView new];
    scene.superview = content;

    SidebarTestView *orientationContainer = [SidebarTestView new];
    SidebarTestView *touchContainer = [SidebarTestView new];
    // Retained live hierarchy: scene and bar-orientation wrapper both at depth
    // 19, shared UIView at 18, status wrapper at 22. Scene is NOT an ancestor.
    orientationContainer.superview = content;
    content.subviews = @[scene, orientationContainer];

    touchContainer.superview = orientationContainer;
    for (NSInteger orientation = 1; orientation <= 4; orientation++) {
        scene.orientation = 0; // The unrelated sibling must not drive bar rotation.
        STUIStatusBar_Wrapper *wrapper = makeBar(touchContainer);
        wrapper.orientation = orientation;
        [wrapper layoutSubviews];
        assert(wrapper.preparedAtLayout);
        assertSidebar(wrapper, orientation);
        wrapper.replaceBarDuringLayout = YES;
        [wrapper layoutSubviews];
        assertSidebar(wrapper, orientation);
        wrapper.hidden = NO;
        assert(!wrapper.hidden && wrapper.alpha == 1); // Native visibility is untouched.
    }
    // A detached reuse-pool bar is left alone, then fixed as soon as it attaches.
    STUIStatusBar_Wrapper *reused = makeBar(nil);
    [reused layoutSubviews];
    assert(!reused.preparedAtLayout && reused.preferredAxis == 1);
    reused.superview = touchContainer;
    [reused didMoveToWindow];
    assert(reused.movedToWindow);
    assertSidebar(reused, 4);
    // Existing bars follow their own content orientation, not a sibling scene.
    reused.orientation = 2;
    [reused layoutSubviews];
    assertSidebar(reused, 2);

    // Home and other windows keep their existing lifecycle, even for the inner UUID.
    SidebarTestView *home = [SidebarTestView new];
    objc_setAssociatedObject(home, &VPhoneDuoHomeOwnerKey, @YES, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    STUIStatusBar_Wrapper *homeBar = makeBar(home);
    [homeBar didMoveToWindow];
    [homeBar layoutSubviews];
    assert(homeBar.movedToWindow && !homeBar.preparedAtLayout && homeBar.preferredAxis == 1);
    STUIStatusBar_Wrapper *unrelatedBar = makeBar([SidebarTestView new]);
    [unrelatedBar layoutSubviews];
    assert(!unrelatedBar.preparedAtLayout);
    SidebarTestView *ordinaryView = [SidebarTestView new];
    [ordinaryView didMoveToWindow];
    assert(ordinaryView.movedToWindow); // Inherited base implementation remains intact.

    scene.orientation = 0;
    STUIStatusBar_Wrapper *unknown = makeBar(touchContainer);
    unknown.orientation = 0;
    [unknown layoutSubviews];
    assert(!unknown.preparedAtLayout);
    scene.orientation = 4;
    for (id UUID in @[@"outer-display", [NSNull null]]) {
        SidebarTestDisplay.mainDisplay.UUID = UUID == [NSNull null] ? nil : UUID;
        STUIStatusBar_Wrapper *outer = makeBar(touchContainer);
        [outer didMoveToWindow];
        [outer layoutSubviews];
        assert(!outer.preparedAtLayout && outer.preferredAxis == 1);
    }
    method_setImplementation(displayMethod, nativeDisplay);
    imp_removeBlock(testDisplay);
    puts("Duo sidebar lifecycle: sibling app/bar branches, first layout, attachment, reuse, rotation and window isolation passed");
}

static SidebarTestView *makeView(CGFloat x, CGFloat y, CGFloat width, CGFloat height) {
    SidebarTestView *view = [SidebarTestView new];
    view.frame = (CGRect){{x,y},{width,height}};
    view.bounds = (CGRect){{0,0},{width,height}};
    return view;
}
int main(void) {
    @autoreleasepool {
        CGFloat area = 669 * 951;
        SidebarTestView *canvas = makeView(0,0,669,951);
        SidebarTestView *background = makeView(0,0,669,951);
        SidebarTestView *battery = makeView(600,20,40,40);
        canvas.subviews = @[background,battery];
        assert(!VPhoneDuoPointInVisibleItem(canvas,(CGPoint){300,400},area,0));
        assert(VPhoneDuoPointInVisibleItem(canvas,(CGPoint){620,40},area,0));
        battery.hidden = YES;
        assert(!VPhoneDuoPointInVisibleItem(canvas,(CGPoint){620,40},area,0));
        battery.hidden = NO;
        battery.alpha = 0;
        assert(!VPhoneDuoPointInVisibleItem(canvas,(CGPoint){620,40},area,0));
        battery.alpha = 1;
        SidebarTestView *nested = makeView(550,10,100,100);
        battery.frame = (CGRect){{20,20},{40,40}};
        nested.subviews = @[battery];
        canvas.subviews = @[background,nested];
        assert(VPhoneDuoPointInVisibleItem(canvas,(CGPoint){580,40},area,0));
        assert(!VPhoneDuoPointInVisibleItem(canvas,(CGPoint){300,400},area,0));
        canvas.subviews = @[background];
        assert(!VPhoneDuoPointInVisibleItem(canvas,(CGPoint){300,400},area,0));
        puts("Duo sidebar hit regions: visible items, nested coordinates and transparent canvas passed");
        testSidebarLifecycle();
    }
    return 0;
}
