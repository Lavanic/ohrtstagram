// What makes the build ohrtstagram and not stock SCInsta, short of features:
// its defaults, its first run, and the small helpers the features share.
#import <objc/message.h>

#import "../../src/InstagramHeaders.h"
#import "../../src/Tweak.h"
#import "../../src/Utils.h"
#import "Ohrt.h"

NSString *const kOhrtDMModeKey = @"ohrt_dm_mode";
NSString *const kOhrtFollowingFeedKey = @"ohrt_following_feed";
NSString *const kOhrtWallKey = @"ohrt_wall";

static NSString *const kOhrtWelcomedKey = @"ohrt_welcomed";

BOOL OhrtBool(NSString *key) {
    return [[NSUserDefaults standardUserDefaults] boolForKey:key];
}

UIColor *OhrtColor(uint32_t rgb) {
    return [UIColor colorWithRed:((rgb >> 16) & 0xff) / 255.0 green:((rgb >> 8) & 0xff) / 255.0 blue:(rgb & 0xff) / 255.0 alpha:1.0];
}

BOOL OhrtFollowingFeedEnabled(void) {
    return OhrtBool(kOhrtFollowingFeedKey) || OhrtBool(kOhrtWallKey);
}

id OhrtCall(id object, NSString *selector) {
    SEL sel = NSSelectorFromString(selector);
    if (!object || ![object respondsToSelector:sel]) return nil;
    return ((id (*)(id, SEL))objc_msgSend)(object, sel);
}

BOOL OhrtCallBool(id object, NSString *selector) {
    SEL sel = NSSelectorFromString(selector);
    if (!object || ![object respondsToSelector:sel]) return NO;
    return ((BOOL (*)(id, SEL))objc_msgSend)(object, sel);
}

void OhrtCallVoid(id object, NSString *selector) {
    SEL sel = NSSelectorFromString(selector);
    if (!object || ![object respondsToSelector:sel]) return;
    ((void (*)(id, SEL))objc_msgSend)(object, sel);
}

// Defaults are registered, not written: a switch the user has touched keeps
// its value, and one they have not follows this list as it changes.
static void OhrtRegisterDefaults(void) {
    [[NSUserDefaults standardUserDefaults] registerDefaults:@{
        // No Reels, nothing suggested, no ads.
        @"hide_ads" : @YES,
        @"hide_reels_tab" : @YES,
        @"disable_scrolling_reels" : @YES,
        @"prevent_doom_scrolling" : @YES,
        @"no_suggested_post" : @YES,
        @"no_suggested_account" : @YES,
        @"no_suggested_reels" : @YES,
        @"no_suggested_threads" : @YES,
        @"no_suggested_users" : @YES,
        @"no_suggested_chats" : @YES,
        @"hide_explore_grid" : @YES,
        @"hide_meta_ai" : @YES,
        // Upstream turns these on. They work against the person on the other
        // end of a message, and ohrtstagram leaves them out.
        @"remove_screenshot_alert" : @NO,
        @"keep_deleted_message" : @NO,
        // Ours start off, so a bad hook in a new feature cannot spoil a
        // first launch.
        kOhrtBudgetMinutesKey : @0,
        kOhrtGrayscaleKey : @NO,
        kOhrtDMModeKey : @NO,
        kOhrtFollowingFeedKey : @NO,
        kOhrtWallKey : @NO,
    }];
}

static void OhrtWelcome(void) {
    NSUserDefaults *defaults = [NSUserDefaults standardUserDefaults];
    if ([defaults boolForKey:kOhrtWelcomedKey]) return;
    UIViewController *top = topMostController();
    if (!top) return;
    UIAlertController *alert = [UIAlertController alertControllerWithTitle:@"ohrtstagram"
                                                                   message:@"Settings: on your profile, hold the three lines at the top right. Or hold four fingers anywhere."
                                                            preferredStyle:UIAlertControllerStyleAlert];
    [alert addAction:[UIAlertAction actionWithTitle:@"OK" style:UIAlertActionStyleDefault handler:nil]];
    [top presentViewController:alert animated:YES completion:^{
        [defaults setBool:YES forKey:kOhrtWelcomedKey];
    }];
}

%hook IGInstagramAppDelegate
- (_Bool)application:(UIApplication *)application willFinishLaunchingWithOptions:(id)options {
    // This is the first moment that is certainly a real launch with the
    // preferences readable. iOS loads the app ahead of time, sometimes on a
    // phone that has not been unlocked since it was switched on, and what
    // our constructors could read then is not to be trusted. So the guard is
    // told, and the features that hook Instagram decide here whether to.
    OhrtGuardAppLaunching();
    OhrtInstallDMMode();
    OhrtInstallFollowing();
    OhrtInstallWall();

    // Upstream registers its defaults in its own hook of this method, which
    // runs inside the call below. Ours are registered before it so our own
    // keys are there during the call, and again after it so that where both
    // name a key (the two it turns on and we do not), ours is the later one.
    OhrtRegisterDefaults();
    _Bool result = %orig;
    OhrtRegisterDefaults();
    // Upstream opens its settings on a first run and signs off as SCInsta.
    // Telling it the first run is over keeps that from happening.
    NSUserDefaults *defaults = [NSUserDefaults standardUserDefaults];
    if (![[defaults objectForKey:@"SCInstaFirstRun"] isEqual:SCIVersionString]) [defaults setObject:SCIVersionString forKey:@"SCInstaFirstRun"];
    return result;
}
- (_Bool)application:(UIApplication *)application didFinishLaunchingWithOptions:(id)options {
    _Bool result = %orig;
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(4 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
        OhrtWelcome();
    });
    return result;
}
%end

%hook SCIUtils
// Upstream empties Library/Caches on every launch, which throws away every
// picture Instagram had cached and makes each start slow. The analytics
// queue is still cleared.
+ (void)cleanCache {
    NSFileManager *files = [NSFileManager defaultManager];
    NSString *support = [NSSearchPathForDirectoriesInDomains(NSLibraryDirectory, NSUserDomainMask, YES).firstObject stringByAppendingPathComponent:@"Application Support"];
    // Under Instagram's own name, and under whatever this copy is called.
    NSMutableOrderedSet<NSString *> *owners = [NSMutableOrderedSet orderedSetWithObject:@"com.burbn.instagram"];
    NSString *identifier = [NSBundle mainBundle].bundleIdentifier;
    if (identifier) [owners addObject:identifier];
    for (NSString *owner in owners) {
        NSString *analytics = [[support stringByAppendingPathComponent:owner] stringByAppendingPathComponent:@"analytics"];
        for (NSString *name in [files contentsOfDirectoryAtPath:analytics error:nil]) {
            [files removeItemAtPath:[analytics stringByAppendingPathComponent:name] error:nil];
        }
    }
}

// In safe mode every switch reads as off (OhrtGuard.m). Otherwise DM mode
// borrows upstream's own switch for hiding the feed tab, as long as this
// Instagram has what DM mode needs to land on the inbox.
+ (BOOL)getBoolPref:(NSString *)key {
    if (OhrtSafeLaunch()) return NO;
    if ([key isEqualToString:@"hide_feed_tab"] && OhrtBool(kOhrtDMModeKey)) {
        static BOOL available;
        static dispatch_once_t once;
        dispatch_once(&once, ^{
            available = OhrtAvailable(@"dm");
        });
        if (available) return YES;
    }
    return %orig;
}
+ (double)getDoublePref:(NSString *)key {
    if (OhrtSafeLaunch()) return 0;
    return %orig;
}
+ (NSString *)getStringPref:(NSString *)key {
    if (OhrtSafeLaunch()) return @"";
    return %orig;
}
%end
