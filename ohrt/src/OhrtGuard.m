// Launch guard.
//
// A hook that crashes while the app starts would crash it on every start,
// and the switch that turns the hook off is inside the app. So every start
// is counted until the app has settled. After two in a row that did not,
// the next one runs with every switch read as off, ours and upstream's,
// which leaves plain Instagram with the settings page still reachable, and
// says what happened. The stored settings are not touched. (One switch is
// not read as off: the one against Instagram erasing its own data after
// crashes. OhrtCore.x says why.)
//
// The counting is in OhrtLogic.h, where it is tested. This file feeds it
// the app's events and keeps its one number between runs.
//
// iOS also starts apps ahead of time ("prewarming"): it loads the app and
// everything injected into it, stops short of launching, and often throws
// the process away. That is not a start anyone asked for, so such a process
// counts for nothing until the app is really launched in it.
//
// The same can be asked for by hand: the app's page in the iPhone's
// Settings app has a switch, "Start with everything off", for when the app
// will not stay up long enough to count anything.
#import "../../src/InstagramHeaders.h"
#import "Ohrt.h"
#import "OhrtLogic.h"

static NSString *const kOhrtUnfinishedKey = @"ohrt_unfinished_launches";
static NSString *const kOhrtForceSafeKey = @"ohrt_force_safe";

// Settled means this long at the front without dying.
static const NSTimeInterval kOhrtSettleAfter = 15;

static OhrtGuard gOhrtGuard;
static BOOL gOhrtForced;
static BOOL gOhrtLaunching;

// Asked on every preference read, so the environment is looked at once.
static BOOL OhrtPrewarmed(void) {
    static BOOL prewarmed;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        const char *value = getenv("ActivePrewarm");
        prewarmed = value && value[0] == '1';
    });
    return prewarmed;
}

// Applies one event to the guard and writes its number out if it moved.
static void OhrtGuardStep(void (^event)(void)) {
    long before = gOhrtGuard.stored;
    event();
    if (gOhrtGuard.stored == before) return;
    NSUserDefaults *defaults = [NSUserDefaults standardUserDefaults];
    [defaults setInteger:gOhrtGuard.stored forKey:kOhrtUnfinishedKey];
    // Out of this process before anything else gets the chance to end it.
    [defaults synchronize];
}

BOOL OhrtSafeLaunch(void) {
    static dispatch_once_t once;
    __block BOOL first = NO;
    // A process iOS loaded ahead of time may not be able to read the
    // preferences yet, and the switch in the Settings app can still change
    // before the app is opened in it. Until it is, this answers from what
    // can be read now and keeps nothing.
    if (OhrtPrewarmed() && !gOhrtLaunching) {
        NSUserDefaults *defaults = [NSUserDefaults standardUserDefaults];
        OhrtGuard peek;
        OhrtGuardStart(&peek, [defaults integerForKey:kOhrtUnfinishedKey]);
        return peek.safe || [defaults boolForKey:kOhrtForceSafeKey];
    }
    dispatch_once(&once, ^{
        NSUserDefaults *defaults = [NSUserDefaults standardUserDefaults];
        OhrtGuardStart(&gOhrtGuard, [defaults integerForKey:kOhrtUnfinishedKey]);
        gOhrtForced = [defaults boolForKey:kOhrtForceSafeKey];
        first = YES;
    });
    if (first) {
        // Written out after the answer is settled, not while settling it: a
        // write can run other code, and that code may ask this question.
        NSUserDefaults *defaults = [NSUserDefaults standardUserDefaults];
        [defaults setInteger:gOhrtGuard.stored forKey:kOhrtUnfinishedKey];
        [defaults synchronize];
        if (gOhrtGuard.safe) OhrtLog(@"guard: %ld starts in a row didn't settle; this one runs with every switch off", gOhrtGuard.before);
        if (gOhrtForced) OhrtLog(@"guard: started with every switch off, as set in the Settings app");
    }
    return gOhrtGuard.safe || gOhrtForced;
}

// Whether this start has every switch off because the Settings app says so,
// not because of crashes.
BOOL OhrtSafeForced(void) {
    if (OhrtPrewarmed() && !gOhrtLaunching) return [[NSUserDefaults standardUserDefaults] boolForKey:kOhrtForceSafeKey];
    OhrtSafeLaunch();
    return gOhrtForced;
}

BOOL OhrtFeature(NSString *key) {
    return !OhrtSafeLaunch() && OhrtBool(key);
}

// Called as the app delegate starts launching, which a prewarmed process
// only reaches if the app is really being opened in it.
void OhrtGuardAppLaunching(void) {
    gOhrtLaunching = YES;
    OhrtSafeLaunch();
    if ([UIApplication sharedApplication].applicationState == UIApplicationStateBackground) return;
    OhrtGuardStep(^{
        OhrtGuardLaunchingAtFront(&gOhrtGuard);
    });
}

void OhrtLaunchSettled(void) {
    OhrtSafeLaunch();
    OhrtGuardStep(^{
        OhrtGuardSettle(&gOhrtGuard);
    });
}

// Runs one piece of a feature that talks to Instagram's classes. If it
// throws (a method that is not there after all, a value of another kind),
// the feature is left off until the app restarts instead of taking the app
// down or throwing again on every call.
BOOL OhrtTry(NSString *feature, void (NS_NOESCAPE ^piece)(void)) {
    static NSMutableSet<NSString *> *broken;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        broken = [NSMutableSet set];
    });
    @synchronized(broken) {
        if ([broken containsObject:feature]) return NO;
    }
    @try {
        piece();
        return YES;
    } @catch (NSException *exception) {
        OhrtLog(@"%@ threw %@ (%@); it's off until the app restarts", feature, exception.name, exception.reason);
        @synchronized(broken) {
            [broken addObject:feature];
        }
        return NO;
    }
}

static void OhrtSaySafe(void) {
    UIViewController *top = topMostController();
    if (!top) return;
    NSString *way = @"on your profile, hold the three lines at the top right, or hold four fingers anywhere";
    NSString *message = gOhrtForced
        ? [NSString stringWithFormat:@"\"Start with everything off\" is switched on for ohrtstagram in the Settings app, so this is plain Insta\u2060gram. Your settings are kept. Change what you need to (%@), switch it off again in Settings, then restart.", way]
        : [NSString stringWithFormat:@"The last two starts ended before the app settled, so this one is plain Insta\u2060gram. Your settings are kept. Turn off what you changed last (%@), then restart.", way];
    UIAlertController *alert = [UIAlertController alertControllerWithTitle:@"ohrtstagram is running with its changes off"
                                                                   message:message
                                                            preferredStyle:UIAlertControllerStyleAlert];
    [alert addAction:[UIAlertAction actionWithTitle:@"OK" style:UIAlertActionStyleDefault handler:nil]];
    [top presentViewController:alert animated:YES completion:nil];
}

__attribute__((constructor)) static void OhrtGuardLoad(void) {
    // A prewarmed process may not be able to read the preferences yet (the
    // phone may not have been unlocked since it was switched on), so there
    // the guard starts when the app does.
    if (!OhrtPrewarmed()) OhrtSafeLaunch();
    NSNotificationCenter *center = [NSNotificationCenter defaultCenter];
    NSOperationQueue *main = [NSOperationQueue mainQueue];

    [center addObserverForName:UIApplicationDidFinishLaunchingNotification object:nil queue:main usingBlock:^(NSNotification *note) {
        gOhrtLaunching = YES;
        OhrtSafeLaunch();
        BOOL inBackground = [UIApplication sharedApplication].applicationState == UIApplicationStateBackground;
        OhrtGuardStep(^{
            OhrtGuardFinishedLaunching(&gOhrtGuard, inBackground);
        });
    }];

    [center addObserverForName:UIApplicationDidBecomeActiveNotification object:nil queue:main usingBlock:^(NSNotification *note) {
        gOhrtLaunching = YES;
        OhrtSafeLaunch();
        __block int first = 0;
        OhrtGuardStep(^{
            first = OhrtGuardBecameActive(&gOhrtGuard);
        });
        if (!first) return;
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(kOhrtSettleAfter * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
            OhrtLaunchSettled();
        });
        if (!OhrtSafeLaunch()) return;
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(3 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
            OhrtSaySafe();
        });
    }];

    // Going to the background or being closed is leaving. Merely going
    // inactive is not: a permission prompt over the app does that, and a
    // crash right behind it should still count.
    for (NSNotificationName name in @[ UIApplicationDidEnterBackgroundNotification, UIApplicationWillTerminateNotification ]) {
        [center addObserverForName:name object:nil queue:main usingBlock:^(NSNotification *note) {
            OhrtSafeLaunch();
            OhrtGuardStep(^{
                OhrtGuardLeft(&gOhrtGuard);
            });
        }];
    }
}
