// ohrtstagram's own code. Everything under ohrt/ is ours; upstream's src/ is
// built from, not edited, so pulling its changes stays easy.
#import <UIKit/UIKit.h>
#import <substrate.h>

// Every hook of ours goes in through OhrtHook.m, which says why. Logos
// writes its calls under the library's name, hence the define.
FOUNDATION_EXPORT void OhrtHookMessage(Class cls, SEL selector, IMP replacement, IMP *original);
#define MSHookMessageEx OhrtHookMessage

#define OHRT_VERSION @"0.1.0"
// OHRT_BUILD, the commit this was built from. Written by ohrt/build.sh.
#import "OhrtBuild.h"

// Settings, all in the app's own preferences.
FOUNDATION_EXPORT NSString *const kOhrtBudgetMinutesKey;  // minutes a day; 0 is no budget
FOUNDATION_EXPORT NSString *const kOhrtGrayscaleKey;
FOUNDATION_EXPORT NSString *const kOhrtDMModeKey;
FOUNDATION_EXPORT NSString *const kOhrtFollowingFeedKey;
FOUNDATION_EXPORT NSString *const kOhrtWallKey;
FOUNDATION_EXPORT NSString *const kOhrtWordmarkKey;

FOUNDATION_EXPORT BOOL OhrtBool(NSString *key);

// Logged as one finished line marked public. The system log blanks out
// whatever is filled in at run time otherwise, and what these lines fill in
// (names of classes and feeds, counts) is what makes them worth reading.
// Nothing that identifies a person goes into one.
FOUNDATION_EXPORT void OhrtLogText(NSString *text);
#define OhrtLog(format, ...) OhrtLogText([NSString stringWithFormat:format, ##__VA_ARGS__])

// The launch guard (OhrtGuard.m). OhrtFeature is a switch that also reads
// as off in safe mode.
FOUNDATION_EXPORT BOOL OhrtSafeLaunch(void);
FOUNDATION_EXPORT BOOL OhrtSafeForced(void);
FOUNDATION_EXPORT BOOL OhrtFeature(NSString *key);
FOUNDATION_EXPORT void OhrtLaunchSettled(void);
FOUNDATION_EXPORT BOOL OhrtTry(NSString *feature, void (NS_NOESCAPE ^piece)(void));

FOUNDATION_EXPORT void OhrtGuardAppLaunching(void);

// Each puts in its hooks if its switch is on. Called once, as the app
// launches: the preferences cannot always be read any earlier.
FOUNDATION_EXPORT void OhrtInstallDMMode(void);
FOUNDATION_EXPORT void OhrtInstallFollowing(void);
FOUNDATION_EXPORT void OhrtInstallWall(void);
FOUNDATION_EXPORT void OhrtInstallBrand(void);

// What a feature needs from the Instagram that is running (OhrtNeeds.m).
FOUNDATION_EXPORT NSString *OhrtMissing(NSString *feature);
FOUNDATION_EXPORT BOOL OhrtAvailable(NSString *feature);
FOUNDATION_EXPORT BOOL OhrtFeatureReady(NSString *key, NSString *feature);
FOUNDATION_EXPORT NSString *OhrtSelfCheck(void);

// The otop palette.
FOUNDATION_EXPORT UIColor *OhrtColor(uint32_t rgb);
#define OHRT_BLACK 0x000000
#define OHRT_RED 0xf05050
#define OHRT_GREEN 0x50f095
#define OHRT_YELLOW 0xf0c050
#define OHRT_BLUE 0x4897d4
#define OHRT_MAGENTA 0xff40b6
#define OHRT_TEAL 0x5f8787
#define OHRT_TEXT 0xbcbcbc
#define OHRT_BODY 0xcccccc
#define OHRT_GREY 0x555555
#define OHRT_LINE 0x303030
#define OHRT_WHITE 0xffffff

// Time budget.
FOUNDATION_EXPORT NSTimeInterval OhrtTimeSpentToday(void);
FOUNDATION_EXPORT NSString *OhrtFormatDuration(NSTimeInterval seconds);

// The screen that lists who does not follow back.
FOUNDATION_EXPORT UIViewController *OhrtFollowBackScreen(void);

// The following feed is on by its own switch, or because the wall needs it.
FOUNDATION_EXPORT BOOL OhrtFollowingFeedEnabled(void);

// Calls a method that may not exist in this Instagram version. Each returns
// nil or NO when the object does not respond.
FOUNDATION_EXPORT id OhrtCall(id object, NSString *selector);
FOUNDATION_EXPORT BOOL OhrtCallBool(id object, NSString *selector);
FOUNDATION_EXPORT void OhrtCallVoid(id object, NSString *selector);
