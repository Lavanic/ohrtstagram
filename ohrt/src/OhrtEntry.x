// A way into the settings that asks nothing of Instagram.
//
// Upstream opens its settings from the menu button on the profile page,
// through a hook on one of Instagram's classes. If that class changes, or
// an account's profile is laid out another way, there would be no way in at
// all. Holding four fingers anywhere for a second opens the same page with
// nothing of Instagram's involved. Upstream's own gestures use three
// fingers (saving media) and five (FLEX).
#import <objc/runtime.h>

#import "../../src/InstagramHeaders.h"
#import "../../src/Settings/SCISettingsViewController.h"
#import "Ohrt.h"

@interface OhrtEntry : NSObject <UIGestureRecognizerDelegate>
@end

@implementation OhrtEntry

+ (instancetype)shared {
    static OhrtEntry *shared;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        shared = [OhrtEntry new];
    });
    return shared;
}

- (void)held:(UILongPressGestureRecognizer *)recognizer {
    if (recognizer.state != UIGestureRecognizerStateBegan) return;
    UIViewController *top = topMostController();
    if (!top) return;
    // Already open, on its first page or one further in.
    for (UIViewController *shown in top.navigationController.viewControllers) {
        if ([shown isKindOfClass:[SCISettingsViewController class]]) return;
    }
    if ([top isKindOfClass:[SCISettingsViewController class]]) return;
    OhrtLog(@"settings opened with four fingers");
    UINavigationController *navigation = [[UINavigationController alloc] initWithRootViewController:[SCISettingsViewController new]];
    [top presentViewController:navigation animated:YES completion:nil];
}

// The hold must not take touches away from whatever is underneath.
- (BOOL)gestureRecognizer:(UIGestureRecognizer *)recognizer shouldRecognizeSimultaneouslyWithGestureRecognizer:(UIGestureRecognizer *)other {
    return YES;
}

@end

static char kOhrtEntryKey;

%hook UIWindow
- (void)makeKeyAndVisible {
    %orig;
    // The app's own windows only: not alerts, the keyboard or the lock.
    if (self.windowLevel != UIWindowLevelNormal || objc_getAssociatedObject(self, &kOhrtEntryKey)) return;
    UILongPressGestureRecognizer *hold = [[UILongPressGestureRecognizer alloc] initWithTarget:[OhrtEntry shared] action:@selector(held:)];
    hold.numberOfTouchesRequired = 4;
    hold.minimumPressDuration = 1.0;
    hold.cancelsTouchesInView = NO;
    hold.delegate = [OhrtEntry shared];
    [self addGestureRecognizer:hold];
    objc_setAssociatedObject(self, &kOhrtEntryKey, hold, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
}
%end
