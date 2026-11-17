// A tab of our own in the bottom bar, between home and messages: the calico
// jack, in outline until it is open and filled while it is. It opens the
// "about you" screen (OhrtAbout.m).
//
// It is not one of Instagram's surfaces. The bar is filled by Instagram and
// ours is then put in after the home button; the screen is laid over the
// tab that is open, under the bar, and taken away when any of Instagram's
// own tabs is pressed or chosen. Instagram counts its tabs without ours, so
// where it tells the bar which one is selected, the count is moved along by
// one from ours on.
#import <objc/message.h>
#import <objc/runtime.h>

#import "Ohrt.h"

NSString *const kOhrtAboutTabKey = @"ohrt_about_tab";

@interface IGTabBarController : UIViewController
@end

@interface IGTabBar : UIView
@end

@interface IGLiquidGlassInteractiveTabBar : UIView
@end

// The calico jack, made simple for a tab: nine points, in a 24 point box.
static const CGPoint kOhrtJack[] = {
    {17.75, 13.87}, {19.09, 18.38}, {13.77, 17.78}, {11.92, 21.51}, {10.23, 17.78}, {5.53, 19.44}, {6.62, 14.74}, {2.92, 13.93}, {6.07, 10.85},
    {4.35, 8.10},   {7.34, 8.16},   {7.06, 3.61},   {11.16, 6.02},  {14.56, 2.78},  {15.47, 7.05}, {19.22, 6.46}, {17.70, 9.98}, {22.60, 11.91},
};

static UIImage *OhrtJackImage(BOOL filled) {
    // Drawn larger than its 24 point box: the points leave more air around
    // the shape than Instagram's own icons have, so at 24 it looked small
    // beside them.
    const CGFloat size = 29;
    UIGraphicsImageRenderer *renderer = [[UIGraphicsImageRenderer alloc] initWithSize:CGSizeMake(size, size)];
    UIImage *image = [renderer imageWithActions:^(UIGraphicsImageRendererContext *context) {
        CGContextScaleCTM(context.CGContext, size / 24, size / 24);
        UIBezierPath *path = [UIBezierPath bezierPath];
        [path moveToPoint:kOhrtJack[0]];
        for (size_t index = 1; index < sizeof(kOhrtJack) / sizeof(kOhrtJack[0]); index++) [path addLineToPoint:kOhrtJack[index]];
        [path closePath];
        path.lineWidth = 1.7 * 24 / size;
        path.lineJoinStyle = kCGLineJoinRound;
        [[UIColor blackColor] set];
        if (filled) [path fill];
        [path stroke];
    }];
    return [image imageWithRenderingMode:UIImageRenderingModeAlwaysTemplate];
}

static UIButton *gOhrtTabButton;
static NSInteger gOhrtTabIndex = NSNotFound;
static BOOL gOhrtTabRaw;
static UIViewController *gOhrtTabScreen;
static NSInteger gOhrtTabBefore = NSNotFound;
static __weak UIViewController *gOhrtTabController;

static id OhrtTabIvar(id object, const char *name) {
    Ivar ivar = object ? class_getInstanceVariable([object class], name) : NULL;
    return ivar ? object_getIvar(object, ivar) : nil;
}

static UIView *OhrtTabBar(UIViewController *controller) {
    id bar = OhrtTabIvar(controller, "_tabBar");
    return [bar isKindOfClass:[UIView class]] ? bar : nil;
}

static NSArray *OhrtTabButtons(UIView *bar) {
    id buttons = OhrtCallValue(bar, @"buttons");
    return [buttons isKindOfClass:[NSArray class]] ? [buttons copy] : nil;
}

// Tells the bar which button is the selected one, counted with ours.
static void OhrtTabSelect(UIView *bar, NSInteger index) {
    SEL select = NSSelectorFromString(@"setSelectedTabBarItemIndex:");
    if (index == NSNotFound || ![bar respondsToSelector:select]) return;
    gOhrtTabRaw = YES;
    ((void (*)(id, SEL, NSInteger))objc_msgSend)(bar, select, index);
    gOhrtTabRaw = NO;
}

static BOOL OhrtTabHasOurs(UIView *bar) {
    return gOhrtTabButton && gOhrtTabIndex != NSNotFound && gOhrtTabButton.superview && [gOhrtTabButton isDescendantOfView:bar];
}

// The screen last shown, kept so that it comes back where it was left, and
// the tab bar controller it was shown on.
static UIViewController *gOhrtTabKept;
static __weak UIViewController *gOhrtTabKeptOn;

static void OhrtTabClose(void) {
    UIViewController *screen = gOhrtTabScreen;
    if (!screen) return;
    gOhrtTabScreen = nil;
    gOhrtTabKept = screen;
    gOhrtTabKeptOn = gOhrtTabController;
    [screen willMoveToParentViewController:nil];
    [screen.view removeFromSuperview];
    [screen removeFromParentViewController];
    gOhrtTabButton.selected = NO;
    UIView *bar = OhrtTabBar(gOhrtTabController);
    if (bar) OhrtTabSelect(bar, gOhrtTabBefore);
}

@interface OhrtTabTarget : NSObject
@end

@implementation OhrtTabTarget

- (void)pressed {
    OhrtTry(@"about tab", ^{
        // Pressed while open: as Instagram's own tabs do, up to the top.
        if (gOhrtTabScreen) {
            OhrtAboutToTop(gOhrtTabScreen);
            return;
        }
        UIViewController *controller = gOhrtTabController;
        UIView *bar = OhrtTabBar(controller);
        if (!controller || !bar) return;
        NSArray *buttons = OhrtTabButtons(bar);
        gOhrtTabBefore = NSNotFound;
        for (NSUInteger index = 0; index < buttons.count; index++) {
            id button = buttons[index];
            if (button != gOhrtTabButton && [button isKindOfClass:[UIControl class]] && [(UIControl *)button isSelected]) gOhrtTabBefore = index;
        }
        CGRect barFrame = [bar convertRect:bar.bounds toView:controller.view];
        CGFloat bottomRoom = MAX(0, controller.view.bounds.size.height - barFrame.origin.y);
        UIViewController *screen = gOhrtTabKeptOn == controller ? gOhrtTabKept : nil;
        gOhrtTabKept = nil;
        if (screen) OhrtAboutShown(screen, bottomRoom);
        else screen = OhrtAboutScreen(bottomRoom);
        [controller addChildViewController:screen];
        screen.view.frame = controller.view.bounds;
        screen.view.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
        if (bar.superview == controller.view) [controller.view insertSubview:screen.view belowSubview:bar];
        else [controller.view addSubview:screen.view];
        [screen didMoveToParentViewController:controller];
        gOhrtTabScreen = screen;
        OhrtTabSelect(bar, [buttons indexOfObject:gOhrtTabButton]);
        gOhrtTabButton.selected = YES;
    });
}

@end

// Puts our button into a bar Instagram has just filled, after the home one.
static void OhrtTabInsert(UIViewController *controller) {
    UIView *bar = OhrtTabBar(controller);
    SEL add = NSSelectorFromString(@"addTabButton:"), clear = NSSelectorFromString(@"clearTabButtons");
    NSArray *buttons = OhrtTabButtons(bar);
    if (!buttons.count || ![bar respondsToSelector:add] || ![bar respondsToSelector:clear]) return;
    // A new tab bar, as after switching account: the screen on the old one
    // is closed while that one is still known.
    if (controller != gOhrtTabController) {
        OhrtTabClose();
        gOhrtTabKept = nil;
    }
    gOhrtTabController = controller;
    if (gOhrtTabButton && [buttons containsObject:gOhrtTabButton]) {
        gOhrtTabIndex = [buttons indexOfObject:gOhrtTabButton];
        return;
    }
    Class buttonClass = NSClassFromString(@"IGTabBarButton");
    if (!buttonClass) return;
    if (!gOhrtTabButton) {
        static OhrtTabTarget *target;
        target = [OhrtTabTarget new];
        UIButton *button = [[buttonClass alloc] initWithFrame:CGRectMake(0, 0, 44, 44)];
        if (![button isKindOfClass:[UIButton class]]) return;
        [button setImage:OhrtJackImage(NO) forState:UIControlStateNormal];
        [button setImage:OhrtJackImage(YES) forState:UIControlStateSelected];
        [button setImage:OhrtJackImage(YES) forState:UIControlStateSelected | UIControlStateHighlighted];
        button.tintColor = [UIColor labelColor];
        button.accessibilityLabel = @"About you";
        [button addTarget:target action:@selector(pressed) forControlEvents:UIControlEventTouchUpInside];
        gOhrtTabButton = button;
    }
    NSInteger selected = NSNotFound;
    for (NSUInteger index = 0; index < buttons.count; index++) {
        if ([buttons[index] isKindOfClass:[UIControl class]] && [(UIControl *)buttons[index] isSelected]) selected = index;
    }
    id home = OhrtTabIvar(controller, "_timelineButton");
    NSUInteger after = home ? [buttons indexOfObject:home] : NSNotFound;
    NSUInteger at = after == NSNotFound ? MIN((NSUInteger)1, buttons.count) : after + 1;
    NSMutableArray *with = [buttons mutableCopy];
    [with insertObject:gOhrtTabButton atIndex:at];
    ((void (*)(id, SEL))objc_msgSend)(bar, clear);
    for (id button in with) ((void (*)(id, SEL, id))objc_msgSend)(bar, add, button);
    gOhrtTabIndex = at;
    if (selected != NSNotFound) OhrtTabSelect(bar, selected >= (NSInteger)at ? selected + 1 : selected);
    [bar setNeedsLayout];
    static BOOL said;
    if (!said) {
        said = YES;
        OhrtLog(@"about tab: put in at place %lu of %lu in a %@", (unsigned long)at, (unsigned long)with.count, NSStringFromClass([bar class]));
    }
}

static NSInteger OhrtTabShift(UIView *bar, NSInteger index) {
    if (gOhrtTabRaw || !OhrtTabHasOurs(bar)) return index;
    return index >= gOhrtTabIndex ? index + 1 : index;
}

static double OhrtTabShiftFraction(UIView *bar, double index) {
    if (gOhrtTabRaw || !OhrtTabHasOurs(bar)) return index;
    double before = (double)gOhrtTabIndex - 1;
    if (index <= before) return index;
    if (index >= (double)gOhrtTabIndex) return index + 1;
    return before + (index - before) * 2;
}

%group OhrtTab

%hook IGTabBarController
- (void)_updateTabBarButtonsAndUpdateViewControllersIfNeeded {
    %orig;
    OhrtTry(@"about tab", ^{
        OhrtTabInsert(self);
    });
}
- (void)_setSelectedTabBarSurface:(id)surface isTabBarAction:(BOOL)action animated:(BOOL)animated navigationAction:(NSUInteger)navigation skipMainFeedFetch:(BOOL)skip {
    OhrtTabClose();
    %orig;
}
- (void)_timelineButtonPressed {
    OhrtTabClose();
    %orig;
}
- (void)_exploreButtonPressed {
    OhrtTabClose();
    %orig;
}
- (void)_discoverVideoButtonPressed {
    OhrtTabClose();
    %orig;
}
- (void)_panoramaCameraButtonPressed {
    OhrtTabClose();
    %orig;
}
- (void)_newsButtonPressed {
    OhrtTabClose();
    %orig;
}
- (void)_profileButtonPressed {
    OhrtTabClose();
    %orig;
}
- (void)_directInboxButtonPressed {
    OhrtTabClose();
    %orig;
}
%end

%hook IGTabBar
- (void)setSelectedTabBarItemIndex:(NSInteger)index {
    %orig(OhrtTabShift(self, index));
}
- (void)setSelectedTabBarItemIndex:(NSInteger)index animateIndicator:(BOOL)animate {
    %orig(OhrtTabShift(self, index), animate);
}
- (void)setSelectedTabBarItemFractionalIndex:(double)index {
    %orig(OhrtTabShiftFraction(self, index));
}
%end

%hook IGLiquidGlassInteractiveTabBar
- (void)setSelectedTabBarItemIndex:(NSInteger)index {
    %orig(OhrtTabShift(self, index));
}
- (void)setSelectedTabBarItemIndex:(NSInteger)index animateIndicator:(BOOL)animate {
    %orig(OhrtTabShift(self, index), animate);
}
- (void)setSelectedTabBarItemFractionalIndex:(double)index {
    %orig(OhrtTabShiftFraction(self, index));
}
%end

%end

void OhrtInstallTab(void) {
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        if (!OhrtFeatureReady(kOhrtAboutTabKey, @"abouttab")) return;
        %init(OhrtTab);
    });
}
