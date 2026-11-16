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
//    liked where the viewer sends the like. A story seen that was for its
//    owner's close friends means you are on their list, and the day is
//    noted.
// Messages are kept here too, but are not noted as they are sent: they are
// read off the conversations (OhrtMessages.x), so that what arrives counts
// as well as what is sent.
//
// What is kept is a time per event, by account id, in a file of the app's
// own on this phone. A time and not a running count, so that a later export
// can be read in without anything being counted twice: only what happened
// after an export was made is added to what the export says.
#import <objc/message.h>
#import <objc/runtime.h>

#import "Ohrt.h"
#import "OhrtLogic.h"

static NSString *const kOhrtFollowedKind = @"followed";
static NSString *const kOhrtCloseFriendsKind = @"close_friends";
static NSString *const kOhrtMessageStamps = @"messages_ms";
static NSString *const kOhrtMessageIds = @"messages_id";

// The notes' own entry, filed like an account under a name none can have.
static NSString *const kOhrtNotesOwn = @"_";
static NSString *const kOhrtNotesBegan = @"began";

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
    OhrtLog(@"activity: notes on %lu accounts are on file", (unsigned long)gOhrtNotes.count);
    return gOhrtNotes;
}

// The notes are made into a file here and written off the main thread.
static void OhrtNotesSave(void) {
    if (!gOhrtNotesUnsaved || !gOhrtNotes || !gOhrtNotesAccount.length) return;
    gOhrtNotesUnsaved = NO;
    NSData *data = [NSPropertyListSerialization dataWithPropertyList:gOhrtNotes format:NSPropertyListBinaryFormat_v1_0 options:0 error:nil];
    NSString *folder = OhrtActivityFolder(), *path = OhrtNotesPath(gOhrtNotesAccount);
    if (!data) return;
    dispatch_async(dispatch_get_global_queue(QOS_CLASS_UTILITY, 0), ^{
        [[NSFileManager defaultManager] createDirectoryAtPath:folder withIntermediateDirectories:YES attributes:nil error:nil];
        if (![data writeToFile:path atomically:YES]) OhrtLog(@"activity: the notes could not be written");
    });
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
    if ([kind isEqualToString:kOhrtFollowedKind] || [kind isEqualToString:kOhrtCloseFriendsKind]) {
        // One day per account: when the follow that stands began, or when
        // a close friends story was last seen.
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

NSNumber *OhrtActivityCloseFriends(NSString *pk) {
    id when = OhrtNotesPerson(pk, NO)[kOhrtCloseFriendsKind];
    return [when isKindOfClass:[NSNumber class]] ? when : nil;
}

NSArray<NSNumber *> *OhrtActivityTimes(NSString *pk, NSString *kind) {
    id times = OhrtNotesPerson(pk, NO)[kind];
    return [times isKindOfClass:[NSArray class]] ? [times copy] : nil;
}

NSTimeInterval OhrtActivityBegan(void) {
    NSMutableDictionary<NSString *, NSMutableDictionary *> *notes = OhrtNotes();
    if (!notes) return 0;
    NSMutableDictionary *own = notes[kOhrtNotesOwn] ?: (notes[kOhrtNotesOwn] = [NSMutableDictionary dictionary]);
    NSNumber *began = own[kOhrtNotesBegan];
    if ([began isKindOfClass:[NSNumber class]]) return began.doubleValue;
    // Notes that were begun before this was kept: the earliest thing in
    // them. Messages are filed in other units and came later anyway.
    double earliest = [NSDate date].timeIntervalSince1970;
    for (NSString *pk in notes) {
        NSDictionary *person = notes[pk];
        for (NSString *kind in person) {
            if ([kind hasPrefix:@"messages_"]) continue;
            id value = person[kind];
            for (id time in [value isKindOfClass:[NSArray class]] ? value : @[ value ]) {
                if ([time isKindOfClass:[NSNumber class]] && [time doubleValue] > 1e9 && [time doubleValue] < earliest) earliest = [time doubleValue];
            }
        }
    }
    own[kOhrtNotesBegan] = @((long long)earliest);
    OhrtNotesChanged();
    return earliest;
}

// The time from which messages are counted here: when the export was made,
// since it counts the ones before. With no export it is when the notes
// were begun, because a conversation only ever shows its latest stretch,
// and counting that would give a number that grows as you scroll back. 0
// while it is not known whose notes these are.
static NSTimeInterval OhrtMessagesAfter(void) {
    if (!OhrtNotes()) return 0;
    NSTimeInterval exported = OhrtExportDate();
    return exported > 0 ? exported : OhrtActivityBegan();
}

// Conversations are read from the moment the app starts, which is before
// it is known who is signed in. What is read until then waits here.
static NSMutableArray<NSArray *> *gOhrtMessagesWaiting;

// The whole numbers filed under `kind` for a person, with room for `more`.
static long long *OhrtNumbersKept(NSDictionary *person, NSString *kind, size_t more, size_t *count) {
    NSArray *kept = [person[kind] isKindOfClass:[NSArray class]] ? person[kind] : nil;
    *count = kept.count;
    long long *numbers = malloc((kept.count + more + 1) * sizeof(long long));
    if (!numbers) return NULL;
    for (size_t index = 0; index < kept.count; index++) numbers[index] = [kept[index] isKindOfClass:[NSNumber class]] ? [kept[index] longLongValue] : 0;
    return numbers;
}

static NSMutableArray *OhrtNumbersToAddTo(NSMutableDictionary *person, NSString *kind) {
    id kept = person[kind];
    if ([kept isKindOfClass:[NSMutableArray class]]) return kept;
    return person[kind] = [kept isKindOfClass:[NSArray class]] ? [kept mutableCopy] : [NSMutableArray array];
}

static void OhrtNoteMessagesNow(NSString *pk, NSString *viewer, NSArray<NSNumber *> *stamps, NSArray<NSNumber *> *ids) {
    if (stamps.count != ids.count) return;
    // Another account's conversations, if the app has them loaded as well.
    if (viewer.length && ![viewer isEqualToString:gOhrtNotesAccount]) {
        static BOOL said;
        if (!said) OhrtLog(@"activity: messages in a conversation that is not this account's are left out");
        said = YES;
        return;
    }
    NSTimeInterval after = OhrtMessagesAfter();
    NSMutableDictionary *person = OhrtNotesPerson(pk, NO);
    size_t stampCount = 0, idCount = 0;
    long long *notedStamps = OhrtNumbersKept(person, kOhrtMessageStamps, stamps.count, &stampCount);
    long long *notedIds = OhrtNumbersKept(person, kOhrtMessageIds, ids.count, &idCount);
    NSMutableArray<NSNumber *> *freshStamps = [NSMutableArray array], *freshIds = [NSMutableArray array];
    NSUInteger early = 0;
    for (NSUInteger index = 0; notedStamps && notedIds && index < stamps.count; index++) {
        long long at = stamps[index].longLongValue, number = ids[index].longLongValue;
        if (!((double)at / 1000.0 > after)) {
            early++;
            continue;
        }
        if (OhrtNoted(notedIds, idCount, number, 0) || OhrtNoted(notedStamps, stampCount, at, 1)) continue;
        notedStamps[stampCount++] = at;
        notedIds[idCount++] = number;
        [freshStamps addObject:@(at)];
        [freshIds addObject:@(number)];
    }
    free(notedStamps);
    free(notedIds);

    static NSUInteger told;
    if (told < 24) {
        told++;
        OhrtLog(@"activity: of %lu messages read, %lu are from before %@ and %lu are new", (unsigned long)stamps.count, (unsigned long)early, OhrtExportDate() > 0 ? @"the export" : @"counting began", (unsigned long)freshStamps.count);
    }
    if (!freshStamps.count) return;
    person = OhrtNotesPerson(pk, YES);
    if (!person) return;
    [OhrtNumbersToAddTo(person, kOhrtMessageStamps) addObjectsFromArray:freshStamps];
    [OhrtNumbersToAddTo(person, kOhrtMessageIds) addObjectsFromArray:freshIds];
    OhrtSay(@"messages", YES);
    OhrtNotesChanged();
}

static void OhrtMessagesCatchUp(void) {
    if (!gOhrtMessagesWaiting.count || !OhrtNotes()) return;
    NSArray<NSArray *> *waiting = gOhrtMessagesWaiting;
    gOhrtMessagesWaiting = nil;
    for (NSArray *one in waiting) OhrtNoteMessagesNow(one[0], [one[1] length] ? one[1] : nil, one[2], one[3]);
}

void OhrtActivityNoteMessages(NSString *pk, NSString *viewer, NSArray<NSNumber *> *stamps, NSArray<NSNumber *> *ids) {
    if (!pk.length || !stamps.count || !ids) return;
    if (!OhrtNotes()) {
        if (!gOhrtMessagesWaiting) gOhrtMessagesWaiting = [NSMutableArray array];
        if (gOhrtMessagesWaiting.count < 4000) [gOhrtMessagesWaiting addObject:@[ pk, viewer ?: @"", stamps, ids ]];
        return;
    }
    OhrtMessagesCatchUp();
    OhrtNoteMessagesNow(pk, viewer, stamps, ids);
}

NSInteger OhrtActivityMessages(NSString *pk, NSTimeInterval *since) {
    OhrtMessagesCatchUp();
    NSTimeInterval after = OhrtMessagesAfter();
    *since = after;
    id stamps = OhrtNotesPerson(pk, NO)[kOhrtMessageStamps];
    if (![stamps isKindOfClass:[NSArray class]] || ![stamps count]) return 0;
    size_t length = [stamps count];
    double *times = malloc(length * sizeof(double));
    if (!times) return 0;
    for (size_t index = 0; index < length; index++) times[index] = [stamps[index] doubleValue] / 1000.0;
    double latest = 0;
    NSInteger count = (NSInteger)OhrtCountAfter(times, length, after, &latest);
    free(times);
    return count;
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
    OhrtMessagesCatchUp();
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
    id owner = OhrtCall(item, @"user");
    OhrtNote(@"stories_seen", owner, YES);
    // Instagram's word for a story only close friends are shown.
    id audience = OhrtCallValue(item, @"audience") ?: OhrtCallValue(OhrtCall(item, @"media"), @"audience");
    static BOOL said;
    if (!said) {
        said = YES;
        OhrtLog(@"activity: stories come %@", [audience isKindOfClass:[NSString class]] ? @"saying who they were for" : @"without saying who they were for");
    }
    if ([audience isKindOfClass:[NSString class]] && [[audience lowercaseString] isEqualToString:@"besties"]) OhrtNote(kOhrtCloseFriendsKind, owner, YES);
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
