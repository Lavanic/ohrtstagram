// Keeps your history with each account going. An Instagram export says
// what you did up to the day it was made (OhrtExport.m). From then on this
// file notes it as it happens in the app: each follow, like, comment, save
// and story you watch, with the time, under the account it was about.
//
// It listens where Instagram itself announces these things, so that it does
// not matter which button or gesture did them:
//  - a follow or unfollow, a comment and a save are announced on the
//    session to whoever has asked to hear;
//  - every like of a post goes through one method on the post;
//  - a story counts as seen where the story viewer marks it seen, and as
//    liked where the viewer sends the like.
// Messages are not noted: the export counts both directions, and what
// arrives would have to be counted as well as what is sent.
//
// What is kept is a time per event, by account id, in a file of the app's
// own on this phone. A time and not a running count, so that a later export
// can be read in without anything being counted twice: only what happened
// after an export was made is added to what the export says.
#import <objc/message.h>
#import <objc/runtime.h>

#import "Ohrt.h"

static NSString *const kOhrtFollowedKind = @"followed";

// What Instagram calls a follow when it announces a change of friendship.
// Read out of its own listener for new follows, which acts only on this.
static const long long kOhrtFollowAction = 0;

@interface IGMedia : NSObject
@end

@interface IGStoryViewerViewController : UIViewController
@end

@interface IGStoryLikesInteractionControllingImpl : NSObject
@end

static id OhrtActivityIvar(id object, const char *name) {
    Ivar ivar = object ? class_getInstanceVariable([object class], name) : NULL;
    return ivar ? object_getIvar(object, ivar) : nil;
}

static NSString *OhrtActivityText(id value) {
    if ([value isKindOfClass:[NSString class]]) return value;
    if ([value isKindOfClass:[NSNumber class]]) return [value stringValue];
    return nil;
}

static NSString *OhrtActivityAccount(void) {
    return OhrtActivityText(OhrtCall(OhrtCall(OhrtCurrentSession(), @"user"), @"pk"));
}

static NSString *OhrtActivityFolder(void) {
    NSString *support = NSSearchPathForDirectoriesInDomains(NSApplicationSupportDirectory, NSUserDomainMask, YES).firstObject;
    return [support stringByAppendingPathComponent:@"ohrt"];
}

// Everything below this line and above the listener touches the notes, and
// runs on the main thread only.

static NSMutableDictionary<NSString *, NSMutableDictionary *> *gOhrtNotes;
static NSString *gOhrtNotesAccount;
static BOOL gOhrtNotesUnsaved;

static NSString *OhrtNotesPath(NSString *account) {
    return [OhrtActivityFolder() stringByAppendingPathComponent:[NSString stringWithFormat:@"activity-%@.plist", account]];
}

static NSMutableDictionary<NSString *, NSMutableDictionary *> *OhrtNotes(void) {
    NSString *account = OhrtActivityAccount();
    if (!account.length) return nil;
    if (gOhrtNotes && [gOhrtNotesAccount isEqualToString:account]) return gOhrtNotes;
    gOhrtNotesAccount = [account copy];
    gOhrtNotes = [NSMutableDictionary dictionary];
    NSDictionary *kept = [NSDictionary dictionaryWithContentsOfFile:OhrtNotesPath(account)];
    for (NSString *pk in kept) {
        NSDictionary *person = kept[pk];
        if (![pk isKindOfClass:[NSString class]] || ![person isKindOfClass:[NSDictionary class]]) continue;
        NSMutableDictionary *mine = [NSMutableDictionary dictionary];
        for (NSString *kind in person) {
            id value = person[kind];
            mine[kind] = [value isKindOfClass:[NSArray class]] ? [value mutableCopy] : value;
        }
        gOhrtNotes[pk] = mine;
    }
    // Follows noted by the first version of this, which kept them apart.
    NSDictionary *older = [NSDictionary dictionaryWithContentsOfFile:[OhrtActivityFolder() stringByAppendingPathComponent:[NSString stringWithFormat:@"followed-%@.plist", account]]];
    for (NSString *pk in older) {
        if (![older[pk] isKindOfClass:[NSNumber class]]) continue;
        NSMutableDictionary *person = gOhrtNotes[pk] ?: (gOhrtNotes[pk] = [NSMutableDictionary dictionary]);
        if (!person[kOhrtFollowedKind]) person[kOhrtFollowedKind] = older[pk];
    }
    OhrtLog(@"activity: notes on %lu accounts are on file", (unsigned long)gOhrtNotes.count);
    return gOhrtNotes;
}

static void OhrtNotesSave(void) {
    if (!gOhrtNotesUnsaved || !gOhrtNotes || !gOhrtNotesAccount.length) return;
    gOhrtNotesUnsaved = NO;
    [[NSFileManager defaultManager] createDirectoryAtPath:OhrtActivityFolder() withIntermediateDirectories:YES attributes:nil error:nil];
    if (![gOhrtNotes writeToFile:OhrtNotesPath(gOhrtNotesAccount) atomically:YES]) OhrtLog(@"activity: the notes could not be written");
}

// Stories go by quickly, so the file is written a moment after the last
// thing noted, not once for each.
static void OhrtNotesChanged(void) {
    if (gOhrtNotesUnsaved) return;
    gOhrtNotesUnsaved = YES;
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(5 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
        OhrtNotesSave();
    });
}

static NSMutableDictionary *OhrtNotesPerson(NSString *pk, BOOL make) {
    NSMutableDictionary<NSString *, NSMutableDictionary *> *notes = OhrtNotes();
    if (!notes || !pk.length || [pk isEqualToString:gOhrtNotesAccount]) return nil;
    NSMutableDictionary *person = notes[pk];
    if (!person && make) person = notes[pk] = [NSMutableDictionary dictionary];
    return person;
}

static void OhrtSay(NSString *kind, BOOL happened) {
    static NSMutableSet<NSString *> *said;
    if (!said) said = [NSMutableSet set];
    NSString *what = [NSString stringWithFormat:@"%@ %@", kind, happened ? @"noted" : @"taken back"];
    if ([said containsObject:what]) return;
    [said addObject:what];
    OhrtLog(@"activity: first %@ since the app started", what);
}

// Something of `kind` was done to the account `pk` just now, or undone.
static void OhrtNoteOnMain(NSString *kind, NSString *pk, BOOL happened) {
    NSMutableDictionary *person = OhrtNotesPerson(pk, happened);
    if (!person) return;
    NSNumber *now = @((long long)[NSDate date].timeIntervalSince1970);
    if ([kind isEqualToString:kOhrtFollowedKind]) {
        // One day per account: when the follow that stands began.
        if (happened) person[kind] = now;
        else [person removeObjectForKey:kind];
    } else {
        NSMutableArray *times = person[kind];
        if (happened) {
            if (!times) times = person[kind] = [NSMutableArray array];
            [times addObject:now];
        } else if (times.count) {
            // An unlike takes back the latest like of that account.
            [times removeLastObject];
        } else {
            return;
        }
    }
    OhrtSay(kind, happened);
    OhrtNotesChanged();
}

// Announcements arrive on whichever thread makes them.
static void OhrtNote(NSString *kind, id account, BOOL happened) {
    NSString *pk = OhrtActivityText(OhrtCall(account, @"pk"));
    if (!pk.length) return;
    dispatch_async(dispatch_get_main_queue(), ^{
        OhrtTry(@"activity", ^{
            OhrtNoteOnMain(kind, pk, happened);
        });
    });
}

NSNumber *OhrtActivityFollowed(NSString *pk) {
    id when = OhrtNotesPerson(pk, NO)[kOhrtFollowedKind];
    return [when isKindOfClass:[NSNumber class]] ? when : nil;
}

NSArray<NSNumber *> *OhrtActivityTimes(NSString *pk, NSString *kind) {
    id times = OhrtNotesPerson(pk, NO)[kind];
    return [times isKindOfClass:[NSArray class]] ? [times copy] : nil;
}

// Hears what Instagram announces. An announcer may tell its listeners more
// than the things wanted here, and a listener that does not know a message
// would bring the app down, so every other message is taken and dropped.
@interface OhrtActivityListener : NSObject
@end

@implementation OhrtActivityListener

- (void)friendStatusChangedForUser:(id)user withUserAction:(long long)action {
    if (action == kOhrtFollowAction) {
        OhrtNote(kOhrtFollowedKind, user, YES);
        return;
    }
    // Some other change. If the account is one that says whether it is
    // still followed, and it is not, the day goes. Otherwise it stays: it
    // is only ever shown for an account that is followed.
    if ([user respondsToSelector:NSSelectorFromString(@"followedByCurrentUser")] && !OhrtCallBool(user, @"followedByCurrentUser")) OhrtNote(kOhrtFollowedKind, user, NO);
}

- (void)commentPosted:(id)comment media:(id)media {
    OhrtNote(@"comments", OhrtCall(media, @"user"), YES);
}

- (void)savableObject:(id)object didUpdateSaveStatusWithHasSaved:(BOOL)saved saveAction:(long long)action {
    OhrtNote(@"saved", OhrtCall(object, @"user"), saved);
}

- (NSMethodSignature *)methodSignatureForSelector:(SEL)selector {
    return [super methodSignatureForSelector:selector] ?: [NSMethodSignature signatureWithObjCTypes:"v@:"];
}

- (void)forwardInvocation:(NSInvocation *)invocation {
}

@end

// Asks the session's announcers to tell our listener. They hold their
// listeners loosely, so ours is kept here, and a session is only asked
// once: signing in to another account makes a new one.
static void OhrtListen(void) {
    static OhrtActivityListener *listener;
    static __weak id heard;
    id session = OhrtCurrentSession();
    if (!session || session == heard) return;
    if (!listener) listener = [OhrtActivityListener new];
    NSMutableArray<NSString *> *asked = [NSMutableArray array];
    for (NSString *name in @[ @"friendStatusChangedAnnouncer", @"commentPostedAnnouncer", @"saveStatusAnnouncer" ]) {
        id announcer = OhrtCall(session, name);
        SEL add = NSSelectorFromString(@"addListener:");
        if (![announcer respondsToSelector:add]) continue;
        ((void (*)(id, SEL, id))objc_msgSend)(announcer, add, listener);
        [asked addObject:name];
    }
    heard = session;
    OhrtLog(@"activity: listening to %@", asked.count ? [asked componentsJoinedByString:@", "] : @"nothing, this session has none of the announcers");
}

%group OhrtActivity

%hook IGMedia
- (void)performLike:(id)like userInfo:(id)info navState:(id)state analyticsModule:(id)module requestSourceParams:(id)params userSession:(id)session sponsoredSupportConfiguration:(id)sponsored completion:(id)completion {
    if ([like respondsToSelector:NSSelectorFromString(@"isLike")]) OhrtNote(@"likes", OhrtCall(self, @"user"), OhrtCallBool(like, @"isLike"));
    %orig;
}
%end

%hook IGStoryViewerViewController
- (void)fullscreenSectionController:(id)controller didMarkItemAsSeen:(id)item {
    %orig;
    // The viewer can mark one story more than once while it is open.
    static NSMutableSet<NSString *> *seen;
    if (!seen) seen = [NSMutableSet set];
    NSString *media = OhrtActivityText(OhrtCall(item, @"mediaID")) ?: OhrtActivityText(OhrtCall(item, @"pk"));
    if (!media.length || [seen containsObject:media]) return;
    if (seen.count > 4000) [seen removeAllObjects];
    [seen addObject:media];
    OhrtNote(@"stories_seen", OhrtCall(item, @"user"), YES);
}
%end

%hook IGStoryLikesInteractionControllingImpl
- (void)_sendStoryLikeWithLikeButton:(UIButton *)button {
    // The heart is the like: Instagram turns it on or off here and sends
    // which. A story that cannot be liked leaves it as it was.
    BOOL isButton = [button isKindOfClass:[UIControl class]];
    BOOL before = isButton && button.selected;
    %orig;
    BOOL after = isButton && button.selected;
    if (!isButton || before == after) return;
    id item = OhrtCall(OhrtActivityIvar(self, "_storyItemContext"), @"storyItem");
    id owner = OhrtCall(OhrtCall(item, @"media"), @"user") ?: OhrtCall(item, @"user");
    OhrtNote(@"story_likes", owner, after);
}
%end

%end

void OhrtInstallActivity(void) {
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        if (!OhrtFeatureReady(kOhrtFactsKey, @"activity")) return;
        %init(OhrtActivity);
        NSNotificationCenter *center = [NSNotificationCenter defaultCenter];
        // The session exists once the tab bar does, which is some time
        // after the app is launched. Coming to the front is after that,
        // and happens again after an account is switched.
        [center addObserverForName:UIApplicationDidBecomeActiveNotification object:nil queue:[NSOperationQueue mainQueue] usingBlock:^(NSNotification *note) {
            dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(3 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
                OhrtTry(@"activity", ^{
                    OhrtListen();
                });
            });
        }];
        [center addObserverForName:UIApplicationWillResignActiveNotification object:nil queue:[NSOperationQueue mainQueue] usingBlock:^(NSNotification *note) {
            OhrtNotesSave();
        }];
    });
}

// Also asked for when a profile is opened, in case the session was not
// there yet when the app came to the front.
void OhrtActivityListen(void) {
    OhrtTry(@"activity", ^{
        OhrtListen();
    });
}
