// DM mode: the app opens on your messages and the home tab is gone.
//
// Hiding the tab is upstream's own "hide feed tab", switched on for us in
// OhrtCore.x. What is added here is where the app lands.
#import <objc/runtime.h>

#import "../../src/InstagramHeaders.h"
#import "Ohrt.h"

static char kOhrtLandedKey;

%group OhrtDMMode

%hook IGTabBarController
- (void)viewWillAppear:(BOOL)animated {
    %orig;
    // Once for each tab bar: switching accounts makes a new one.
    if (objc_getAssociatedObject(self, &kOhrtLandedKey)) return;
    objc_setAssociatedObject(self, &kOhrtLandedKey, @YES, OBJC_ASSOCIATION_RETAIN_NONATOMIC);

    __block BOOL landed = NO;
    BOOL ran = OhrtTry(@"DM mode", ^{
        if (!OhrtCallBool(self, @"_tabBarHasDirectInbox")) return;
        OhrtCallVoid(self, @"_directInboxButtonPressed");
        landed = YES;
    });
    OhrtLog(@"DM mode: %@", landed ? @"opened on the inbox" : ran ? @"this tab bar has no inbox tab" : @"failed");
    if (landed) return;
    // Some accounts still have the tab bar without Messages in it. With the
    // home tab hidden as well there would be nowhere to land, so DM mode
    // stands down and says why.
    [[NSUserDefaults standardUserDefaults] setBool:NO forKey:kOhrtDMModeKey];
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(2 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
        UIAlertController *alert = [UIAlertController alertControllerWithTitle:@"DM mode is off"
                                                                       message:@"This tab bar has no Messages tab to open on. Try another icon order under Navigation, then turn DM mode on again. The home tab comes back when you restart."
                                                                preferredStyle:UIAlertControllerStyleAlert];
        [alert addAction:[UIAlertAction actionWithTitle:@"OK" style:UIAlertActionStyleDefault handler:nil]];
        [topMostController() presentViewController:alert animated:YES completion:nil];
    });
}
%end

%end

%ctor {
    // Nothing is hooked unless the mode is on when the app starts.
    if (OhrtFeatureReady(kOhrtDMModeKey, @"dm")) %init(OhrtDMMode);
}
