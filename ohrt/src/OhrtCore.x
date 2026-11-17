// What makes the build ohrtstagram and not stock SCInsta, short of features:
// its defaults, its first run, and the small helpers the features share.
#import <objc/message.h>
#import <os/log.h>

#import "../../src/InstagramHeaders.h"
#import "../../src/Tweak.h"
#import "../../src/Utils.h"
#import "Ohrt.h"
#import "OhrtLogic.h"

NSString *const kOhrtDMModeKey = @"ohrt_dm_mode";
NSString *const kOhrtFollowingFeedKey = @"ohrt_following_feed";
NSString *const kOhrtWallKey = @"ohrt_wall";

static NSString *const kOhrtWelcomedKey = @"ohrt_welcomed";

void OhrtLogText(NSString *text) {
    os_log(OS_LOG_DEFAULT, "[ohrt] %{public}s", text.UTF8String ?: "");
}

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

NSString *OhrtGrouped(long long count) {
    char text[32];
    OhrtGroupDigits(count, text, sizeof(text));
    return @(text);
}

// One of upstream's switches, read as off on this thread for the length of
// a call (OhrtFixes.x).
static __thread void *tOhrtPrefOff;

void *OhrtPrefOffBegin(NSString *key) {
    void *before = tOhrtPrefOff;
    tOhrtPrefOff = (__bridge void *)key;
    return before;
}

void OhrtPrefOffEnd(void *before) {
    tOhrtPrefOff = before;
}

id OhrtCallValue(id object, NSString *selector) {
    SEL sel = NSSelectorFromString(selector);
    if (!object || ![object respondsToSelector:sel]) return nil;
    NSMethodSignature *signature = [object methodSignatureForSelector:sel];
    if (signature.numberOfArguments != 2) return nil;
    switch (signature.methodReturnType[0]) {
    case '@':
        return ((id (*)(id, SEL))objc_msgSend)(object, sel);
    case 'q':
    case 'l':
        return @(((long long (*)(id, SEL))objc_msgSend)(object, sel));
    case 'Q':
    case 'L':
        return @(((unsigned long long (*)(id, SEL))objc_msgSend)(object, sel));
    case 'i':
        return @(((int (*)(id, SEL))objc_msgSend)(object, sel));
    case 'B':
    case 'c':
        return @(((BOOL (*)(id, SEL))objc_msgSend)(object, sel));
    case 'd':
        return @(((double (*)(id, SEL))objc_msgSend)(object, sel));
    default:
        return nil;
    }
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
        // The two of ours that start on: they are the app's name, like the
        // icon. The launch guard still turns them off with the rest.
        kOhrtWordmarkKey : @YES,
        kOhrtNameKey : @YES,
        // On from the start: each only adds a line or a tab. Hidden likes
        // also makes a request per post, within the caps in OhrtLikes.x.
        kOhrtFactsKey : @YES,
        kOhrtLikesKey : @YES,
        kOhrtPostFactsKey : @YES,
        kOhrtAboutTabKey : @YES,
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

// The app is launching: the first moment that is certainly a real start
// with the preferences readable. iOS loads the app ahead of time, sometimes
// on a phone that has not been unlocked since it was switched on, and what
// our constructors could read then is not to be trusted. So the guard is
// told, and the features that hook Instagram decide here whether to. Each
// step only happens once however often this is called.
static void OhrtAppLaunching(void) {
    // Before anything is decided: a switch nobody has touched reads as its
    // default, and one of ours defaults to on.
    OhrtRegisterDefaults();
    OhrtGuardAppLaunching();
    OhrtInstallBrand();
    OhrtInstallName();
    OhrtInstallFacts();
    OhrtInstallActivity();
    OhrtInstallMessages();
    OhrtInstallLikes();
    OhrtInstallPostFacts();
    OhrtInstallFixes();
    OhrtInstallSideloadKeys();
    OhrtInstallTab();
    OhrtInstallSuggested();
    OhrtInstallDMMode();
    OhrtInstallFollowing();
    OhrtInstallWall();
}

// Normally reached from the hook below, before Instagram has done anything.
// If that hook ever fails to attach, this still gets the features in, late
// but in, and the self-check in settings shows the hook as missing.
__attribute__((constructor)) static void OhrtCoreLoad(void) {
    OhrtLog(@"ohrtstagram %@ (%@) loaded into %@ %@", OHRT_VERSION, OHRT_BUILD, [NSBundle mainBundle].bundleIdentifier,
            [[NSBundle mainBundle] objectForInfoDictionaryKey:@"CFBundleShortVersionString"]);
    [[NSNotificationCenter defaultCenter] addObserverForName:UIApplicationDidFinishLaunchingNotification object:nil queue:[NSOperationQueue mainQueue]
                                                  usingBlock:^(NSNotification *note) {
        OhrtAppLaunching();
        OhrtRegisterDefaults();
    }];
}

%hook IGInstagramAppDelegate
- (_Bool)application:(UIApplication *)application willFinishLaunchingWithOptions:(id)options {
    OhrtAppLaunching();

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
    // Instagram's own answer to a few crashes in a row is to erase its
    // data: the login, the preferences, and with them every switch here and
    // the launch guard's count. Upstream has a switch against that. It is
    // asked for after crashes, which is exactly when our safe mode is on,
    // and reading it as off then would let Instagram erase the settings
    // that safe mode says are kept. So safe mode after crashes leaves this
    // one switch alone. "Start with everything off" still turns it off.
    if ([key isEqualToString:@"disable_safe_mode"] && !OhrtSafeForced()) return %orig;
    if (OhrtSafeLaunch()) return NO;
    if (tOhrtPrefOff && [(__bridge NSString *)tOhrtPrefOff isEqualToString:key]) return NO;
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
