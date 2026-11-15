// ohrtstagram's own code. Everything under ohrt/ is ours; upstream's src/ is
// built from, not edited, so pulling its changes stays easy.
#import <UIKit/UIKit.h>

#define OHRT_VERSION @"0.1.0"

// Settings, all in the app's own preferences.
FOUNDATION_EXPORT NSString *const kOhrtBudgetMinutesKey;  // minutes a day; 0 is no budget
FOUNDATION_EXPORT NSString *const kOhrtGrayscaleKey;
FOUNDATION_EXPORT NSString *const kOhrtDMModeKey;
FOUNDATION_EXPORT NSString *const kOhrtFollowingFeedKey;
FOUNDATION_EXPORT NSString *const kOhrtWallKey;

FOUNDATION_EXPORT BOOL OhrtBool(NSString *key);

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

// The following feed is on by its own switch, or because the wall needs it.
FOUNDATION_EXPORT BOOL OhrtFollowingFeedEnabled(void);

// Calls a method that may not exist in this Instagram version. Each returns
// nil or NO when the object does not respond.
FOUNDATION_EXPORT id OhrtCall(id object, NSString *selector);
FOUNDATION_EXPORT BOOL OhrtCallBool(id object, NSString *selector);
FOUNDATION_EXPORT void OhrtCallVoid(id object, NSString *selector);
