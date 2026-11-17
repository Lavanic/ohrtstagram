// ohrtstagram's own code. Everything under ohrt/ is ours; upstream's src/ is
// built from, not edited, so pulling its changes stays easy.
#import <UIKit/UIKit.h>
#import <substrate.h>

// Every hook of ours goes in through OhrtHook.m, which says why. Logos
// writes its calls under the library's name, hence the define.
FOUNDATION_EXPORT void OhrtHookMessage(Class cls, SEL selector, IMP replacement, IMP *original);
#define MSHookMessageEx OhrtHookMessage

#define OHRT_VERSION @"0.1.0"

// Where our own screens mean Instagram itself, they write the word with a
// word joiner in the middle: "Insta\u2060gram". It shows as nothing, and it
// keeps the name feature (OhrtName.x) from turning the word into ours.
// OHRT_BUILD, the commit this was built from. Written by ohrt/build.sh.
#import "OhrtBuild.h"

// Settings, all in the app's own preferences.
FOUNDATION_EXPORT NSString *const kOhrtBudgetMinutesKey;  // minutes a day; 0 is no budget
FOUNDATION_EXPORT NSString *const kOhrtGrayscaleKey;
FOUNDATION_EXPORT NSString *const kOhrtDMModeKey;
FOUNDATION_EXPORT NSString *const kOhrtFollowingFeedKey;
FOUNDATION_EXPORT NSString *const kOhrtWallKey;
FOUNDATION_EXPORT NSString *const kOhrtWordmarkKey;
FOUNDATION_EXPORT NSString *const kOhrtNameKey;
FOUNDATION_EXPORT NSString *const kOhrtFactsKey;
FOUNDATION_EXPORT NSString *const kOhrtLikesKey;
FOUNDATION_EXPORT NSString *const kOhrtPostFactsKey;
FOUNDATION_EXPORT NSString *const kOhrtAboutTabKey;

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
FOUNDATION_EXPORT void OhrtInstallName(void);
FOUNDATION_EXPORT void OhrtInstallFacts(void);
FOUNDATION_EXPORT void OhrtInstallActivity(void);
FOUNDATION_EXPORT void OhrtInstallSuggested(void);
FOUNDATION_EXPORT void OhrtInstallMessages(void);
FOUNDATION_EXPORT void OhrtInstallLikes(void);
FOUNDATION_EXPORT void OhrtInstallPostFacts(void);
FOUNDATION_EXPORT void OhrtInstallFixes(void);
FOUNDATION_EXPORT void OhrtInstallTab(void);
// The "about you" screen (OhrtAbout.m).
// `bottomRoom` is how much of the bottom the tab bar covers.
FOUNDATION_EXPORT UIViewController *OhrtAboutScreen(CGFloat bottomRoom);
// The screen is kept between visits. It is told when it is shown again, to
// read everything afresh, and when its tab is pressed while it is open.
FOUNDATION_EXPORT void OhrtAboutShown(UIViewController *screen, CGFloat bottomRoom);
FOUNDATION_EXPORT void OhrtAboutToTop(UIViewController *screen);

// Log-only probes of what Instagram holds and does not show (OhrtProbe.m).
FOUNDATION_EXPORT void OhrtProbeSession(void);
FOUNDATION_EXPORT void OhrtProbeMedia(id media);
FOUNDATION_EXPORT void OhrtProbeThread(id metadata);
FOUNDATION_EXPORT void OhrtProbeUser(id user, BOOL mine);
// Lets a sideloaded copy make its device key pairs (OhrtSideloadKeys.m).
FOUNDATION_EXPORT void OhrtInstallSideloadKeys(void);
FOUNDATION_EXPORT void OhrtProbeRecipient(id entity);
// Makes one of upstream's switches read as off on this thread until the
// matching End, which takes what Begin returned. The key must outlive the
// pair: pass a literal.
FOUNDATION_EXPORT void *OhrtPrefOffBegin(NSString *key);
FOUNDATION_EXPORT void OhrtPrefOffEnd(void *before);

// The like count of a post that hides it, counted from who liked it
// (OhrtLikes.x): the number, and whether it is only a floor; NO until it
// has been read. OhrtLikesWant asks for it to be read and OhrtLikesUnwant
// takes that back; main thread. When it has been read, or has left the
// queue unread, kOhrtLikesCountedNotification is posted on the main thread
// with the post's id as its object.
FOUNDATION_EXPORT NSString *OhrtMediaId(id media);
FOUNDATION_EXPORT BOOL OhrtLikesCountedNumber(NSString *mediaId, long long *count, BOOL *more);
FOUNDATION_EXPORT void OhrtLikesWant(NSString *mediaId);
FOUNDATION_EXPORT void OhrtLikesUnwant(NSString *mediaId);
// Counted within the last few hours, so not read again yet.
FOUNDATION_EXPORT BOOL OhrtLikesIsFresh(NSString *mediaId);
// What to show for a hidden count not read yet: that it is being counted,
// or that reading is paused or capped. nil when nothing is coming.
FOUNDATION_EXPORT NSString *OhrtLikesWaitText(NSString *mediaId);
FOUNDATION_EXPORT NSString *const kOhrtLikesCountedNotification;

// The small red text of the facts lines (OhrtFacts.x), on a profile and
// under a post.
FOUNDATION_EXPORT UIFont *OhrtFactsLineFont(void);
FOUNDATION_EXPORT UIColor *OhrtFactsLineColor(void);

// What has changed on a profile since you last opened it (OhrtLooks.m), as
// facts for its line. Notes what it says now. Main thread.
FOUNDATION_EXPORT NSArray<NSString *> *OhrtLookedChanges(id user, NSString *pk);

// What a feature needs from the Instagram that is running (OhrtNeeds.m).
FOUNDATION_EXPORT NSString *OhrtMissing(NSString *feature);
FOUNDATION_EXPORT BOOL OhrtAvailable(NSString *feature);
FOUNDATION_EXPORT BOOL OhrtFeatureReady(NSString *key, NSString *feature);
FOUNDATION_EXPORT NSString *OhrtSelfCheck(void);

// The otop palette.
FOUNDATION_EXPORT UIColor *OhrtColor(uint32_t rgb);
#define OHRT_BLACK 0x000000
#define OHRT_TEXT 0xbcbcbc
#define OHRT_BODY 0xcccccc
#define OHRT_LINE 0x303030
#define OHRT_WHITE 0xffffff

// Time budget.
FOUNDATION_EXPORT NSTimeInterval OhrtTimeSpentToday(void);
FOUNDATION_EXPORT NSString *OhrtFormatDuration(NSTimeInterval seconds);

// The screen that lists who does not follow back.
FOUNDATION_EXPORT UIViewController *OhrtFollowBackScreen(void);

// Instagram's session for the account that is signed in, or nil before the
// tab bar exists.
FOUNDATION_EXPORT id OhrtCurrentSession(void);

// Your Instagram export, once read in (OhrtExport.m): what it says about
// an account by username, and about a conversation by the other's name.
FOUNDATION_EXPORT NSDictionary *OhrtExportPerson(NSString *username);
FOUNDATION_EXPORT NSDictionary *OhrtExportThread(NSString *fullName);
// Reads an unpacked export folder into the same shape as a facts file, or
// nil if the folder is not one. Slow: not for the main thread.
FOUNDATION_EXPORT NSDictionary *OhrtReadExportFolder(NSURL *folder);
FOUNDATION_EXPORT NSTimeInterval OhrtExportDate(void);
FOUNDATION_EXPORT NSString *OhrtExportStatus(void);
FOUNDATION_EXPORT void OhrtExportImport(void);

// What has been noted of your doings since (OhrtActivity.x): the day a
// follow began, and the times of your likes, comments, saves and stories
// watched, by account id. Main thread.
FOUNDATION_EXPORT NSNumber *OhrtActivityFollowed(NSString *pk);
FOUNDATION_EXPORT NSArray<NSNumber *> *OhrtActivityTimes(NSString *pk, NSString *kind);
FOUNDATION_EXPORT void OhrtActivityListen(void);
// When the notes were begun, in seconds since 1970: what they count is
// counted from then. 0 while it is not known who is signed in.
FOUNDATION_EXPORT NSTimeInterval OhrtActivityBegan(void);
// When you were last shown a story of `pk`'s that was for their close
// friends, or nil.
FOUNDATION_EXPORT NSNumber *OhrtActivityCloseFriends(NSString *pk);
// Messages with the account `pk`, read off a conversation that belongs to
// the account `viewer` (OhrtMessages.x): for each its time in milliseconds
// since 1970 and its id as a number. Those not noted before are. Main
// thread.
FOUNDATION_EXPORT void OhrtActivityNoteMessages(NSString *pk, NSString *viewer, NSArray<NSNumber *> *stamps, NSArray<NSNumber *> *ids);
// How many messages have been noted with `pk` beyond what the export
// counts, and in `since` the time they have been counted from.
FOUNDATION_EXPORT NSInteger OhrtActivityMessages(NSString *pk, NSTimeInterval *since);

// The following feed is on by its own switch, or because the wall needs it.
FOUNDATION_EXPORT BOOL OhrtFollowingFeedEnabled(void);

// Calls a method that may not exist in this Instagram version. Each returns
// nil or NO when the object does not respond.
FOUNDATION_EXPORT id OhrtCall(id object, NSString *selector);
FOUNDATION_EXPORT BOOL OhrtCallBool(id object, NSString *selector);
// What `object` answers to `selector` as an object, whatever kind of value
// the method returns (a number comes back as an NSNumber), or nil.
FOUNDATION_EXPORT id OhrtCallValue(id object, NSString *selector);
// 12347 as "12,347".
FOUNDATION_EXPORT NSString *OhrtGrouped(long long count);
FOUNDATION_EXPORT void OhrtCallVoid(id object, NSString *selector);
