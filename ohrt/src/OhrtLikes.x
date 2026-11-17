// The like count of a post whose owner hid it.
//
// Instagram does not send that count: a post with hidden likes comes with
// a stand-in, the real count up to 3 and then 3, the same for everyone. Of
// the two lists of who liked a post, the usual one ("/media/<id>/likers/")
// names about a hundred and gives the same stand-in as its total, and
// offers no next page. The newest-first one ("/media/<id>/likers_chrono/")
// gives the real total (145 for a post whose usual list said 3; up to
// 30,519 seen), so that is read, and the usual one only if it fails. From
// the usual list the names are the count, "at least" when it is full.
//
// The list is asked for when a hidden post comes on screen, through the
// same reader Instagram's own "Liked by" screen uses, and dropped from the
// queue if the post leaves the screen first. List reads are metered, so
// they go one at a time, a moment apart, newest on screen first, with an
// hourly and a daily cap, only while the app is in front. A refusal from
// Instagram stops them for a while; a dropped connection or a slow answer
// only skips that post. A count is kept and shown at once next time, and
// read again once it is some hours old. Opening "Liked by" yourself puts
// the count at the top of that screen.
#import <objc/message.h>
#import <objc/runtime.h>

#import "Ohrt.h"

NSString *const kOhrtLikesKey = @"ohrt_hidden_likes";
NSString *const kOhrtLikesCountedNotification = @"OhrtLikesCounted";

// Counts kept under the earlier keys came from the usual list alone, which
// stops at about a hundred; they are dropped and read again.
static NSString *const kOhrtCountedKey = @"ohrt_counted_likes_3";
// The usual list names about a hundred, sometimes fewer: from this many on,
// a list whose total is a stand-in is taken as full.
static const long long kOhrtLikersFloor = 80;
static NSString *const kOhrtAskedKey = @"ohrt_likers_asked";
static NSString *const kOhrtPausedKey = @"ohrt_likers_paused";
static const NSUInteger kOhrtCountedKept = 500;
static const NSTimeInterval kOhrtCountedFresh = 6 * 60 * 60;
// The follower check that read about 160 lists 2 to 4 s apart went through;
// a second one straight after was refused. These stay under that.
static const NSTimeInterval kOhrtLikersGap = 1.5;
static const NSUInteger kOhrtLikersPerHour = 150;
static const NSUInteger kOhrtLikersPerDay = 600;
static const NSTimeInterval kOhrtLikersPause = 15 * 60;
// Instagram's reader is told to give up after the first; ours waits a
// little longer in case it does not say so.
static const NSTimeInterval kOhrtReaderTimeout = 6;
static const NSTimeInterval kOhrtLikersTimeout = 8;
static const NSUInteger kOhrtWantedKept = 8;

typedef id (*OhrtLikersInit)(__attribute__((ns_consumed)) id, SEL, id, id, id) __attribute__((ns_returns_retained));

@interface IGFollowListViewController : UIViewController
@end

NSString *OhrtMediaId(id media) {
    id value = OhrtCallValue(media, @"mediaID") ?: OhrtCallValue(media, @"mediaId");
    if ([value isKindOfClass:[NSNumber class]]) value = [value stringValue];
    return [value isKindOfClass:[NSString class]] && [value length] ? value : nil;
}

static BOOL OhrtIsConnectionError(id error) {
    for (int depth = 0; depth < 4 && [error isKindOfClass:[NSError class]]; depth++) {
        if ([[(NSError *)error domain] isEqualToString:NSURLErrorDomain]) return YES;
        error = [(NSError *)error userInfo][NSUnderlyingErrorKey];
    }
    return NO;
}

// Counted so far, by post id, as {count, more, when}. Read from whichever
// thread makes a post's rows, so behind a lock.
static NSMutableDictionary<NSString *, NSArray<NSNumber *> *> *gOhrtCounted;
static BOOL gOhrtCountedUnsaved;

static NSObject *OhrtCountedLock(void) {
    static NSObject *lock;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        lock = [NSObject new];
        gOhrtCounted = [NSMutableDictionary dictionary];
        for (NSString *old in @[ @"ohrt_counted_likes", @"ohrt_counted_likes_2" ]) [[NSUserDefaults standardUserDefaults] removeObjectForKey:old];
        NSDictionary *kept = [[NSUserDefaults standardUserDefaults] dictionaryForKey:kOhrtCountedKey];
        for (NSString *mediaId in kept) {
            NSArray *entry = kept[mediaId];
            if ([mediaId isKindOfClass:[NSString class]] && [entry isKindOfClass:[NSArray class]] && entry.count == 3) gOhrtCounted[mediaId] = entry;
        }
    });
    return lock;
}

static NSString *OhrtLikesText(long long count, BOOL more) {
    return [NSString stringWithFormat:@"%@%@ %@", more ? @"at least " : @"", OhrtGrouped(count), count == 1 && !more ? @"like" : @"likes"];
}

static NSArray<NSNumber *> *OhrtLikesEntry(NSString *mediaId) {
    if (!mediaId) return nil;
    @synchronized(OhrtCountedLock()) {
        return gOhrtCounted[mediaId];
    }
}

BOOL OhrtLikesCountedNumber(NSString *mediaId, long long *count, BOOL *more) {
    NSArray<NSNumber *> *counted = OhrtLikesEntry(mediaId);
    if (!counted) return NO;
    if (count) *count = counted[0].longLongValue;
    if (more) *more = counted[1].boolValue;
    return YES;
}

BOOL OhrtLikesIsFresh(NSString *mediaId) {
    NSArray<NSNumber *> *counted = OhrtLikesEntry(mediaId);
    return counted && [NSDate date].timeIntervalSince1970 - counted[2].doubleValue < kOhrtCountedFresh;
}

static void OhrtLikesAnnounce(NSString *mediaId) {
    if (mediaId) [[NSNotificationCenter defaultCenter] postNotificationName:kOhrtLikesCountedNotification object:mediaId];
}

// Main thread. Counts come a few seconds apart, so they are saved together.
static void OhrtLikesKeep(NSString *mediaId, long long count, BOOL more) {
    @synchronized(OhrtCountedLock()) {
        gOhrtCounted[mediaId] = @[ @(count), @(more), @((long long)[NSDate date].timeIntervalSince1970) ];
        if (gOhrtCounted.count > kOhrtCountedKept) {
            NSArray<NSString *> *oldest = [gOhrtCounted keysSortedByValueUsingComparator:^NSComparisonResult(NSArray *one, NSArray *other) {
                return [one[2] compare:other[2]];
            }];
            [gOhrtCounted removeObjectsForKeys:[oldest subarrayWithRange:NSMakeRange(0, gOhrtCounted.count - kOhrtCountedKept)]];
        }
    }
    if (gOhrtCountedUnsaved) return;
    gOhrtCountedUnsaved = YES;
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(5 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
        gOhrtCountedUnsaved = NO;
        NSDictionary *save;
        @synchronized(OhrtCountedLock()) {
            save = [gOhrtCounted copy];
        }
        [[NSUserDefaults standardUserDefaults] setObject:save forKey:kOhrtCountedKey];
    });
}

// The count a likers reader that has loaded gives: its total when that is
// real, otherwise those it names plus those it says it left unnamed, which
// is only a floor when the list is full.
static long long OhrtLikesCountIn(id source, BOOL *floor, NSString **told) {
    long long listed = [OhrtCallValue(source, @"numberOfResults") longLongValue];
    long long total = [OhrtCallValue(source, @"totalUsersCount") longLongValue];
    Ivar ivar = class_getInstanceVariable([source class], "_anonymousUsersCount");
    id unnamed = ivar ? object_getIvar(source, ivar) : nil;
    long long named = listed + ([unnamed isKindOfClass:[NSNumber class]] ? MAX([unnamed longLongValue], 0) : 0);
    // A total above the stand-in's ceiling, or one the names do not pass,
    // is the real count.
    BOOL real = total > 3 || total >= named;
    *floor = !real && listed >= kOhrtLikersFloor;
    if (told) *told = [NSString stringWithFormat:@"%lld named, a total of %lld given", named, total];
    return real ? MAX(total, named) : named;
}

// Reading one post's likers.

@interface OhrtLikersFetch : NSObject
@property (nonatomic, copy) NSString *mediaId;
@property (nonatomic, strong) id source;
// The newest-first list, which gives the real total. If it fails, the
// usual list is read instead.
@property (nonatomic) BOOL chrono;
@property (nonatomic) BOOL wantsPlain;
@property (nonatomic) CFTimeInterval asked;
@property (nonatomic, copy) void (^done)(BOOL refused);
@end

static void OhrtLikersArrived(OhrtLikersFetch *fetch);

@implementation OhrtLikersFetch

- (void)end:(BOOL)refused {
    void (^done)(BOOL) = self.done;
    self.done = nil;
    if (done) done(refused);
}

- (void)dataSourceDidFinishLoading:(id)source {
    dispatch_async(dispatch_get_main_queue(), ^{
        if (!self.done) return;
        if (!OhrtTry(@"likes", ^{
                OhrtLikersArrived(self);
            })) [self end:NO];
    });
}

- (void)dataSourceDidFailLoad:(id)source {
    dispatch_async(dispatch_get_main_queue(), ^{
        if (!self.done) return;
        BOOL connection = OhrtIsConnectionError(OhrtCallValue(self.source, @"fetchError"));
        OhrtLog(@"likes: reading %@ failed, %@", self.chrono ? @"the newest likers" : @"who liked a post", connection ? @"the connection" : @"refused");
        // The newest-first list may not be open to everyone for every post;
        // the usual one is tried before treating it as a refusal.
        if (self.chrono && !connection) self.wantsPlain = YES;
        [self end:!connection && !self.chrono];
    });
}

// The reader tells its delegate more than these two.
- (NSMethodSignature *)methodSignatureForSelector:(SEL)selector {
    return [super methodSignatureForSelector:selector] ?: [NSMethodSignature signatureWithObjCTypes:"v@:"];
}

- (void)forwardInvocation:(NSInvocation *)invocation {
}

@end

// The queue. Main thread only.

static NSMutableOrderedSet<NSString *> *gOhrtWanted;
static NSMutableArray<NSNumber *> *gOhrtAsked;
static OhrtLikersFetch *gOhrtFetching;
static NSTimeInterval gOhrtNextAsk;
static NSTimeInterval gOhrtPausedUntil;
static BOOL gOhrtPumpScheduled;
// A post whose newest-first read was refused, waiting out the gap before
// the usual list is tried. Nothing else is read meanwhile.
static NSString *gOhrtFallingBack;
// Newest-first reads refused in a row with nothing read in between.
static NSUInteger gOhrtRefusedRun;
static const NSUInteger kOhrtRefusedRunMost = 3;
// Posts given up on this run: failed, skipped or scrolled past. Shown with
// no count until they come on screen again.
static NSMutableSet<NSString *> *gOhrtSkipped;

// When reads were made in the last day, and any pause, survive a restart.
static void OhrtLikesLoadLimits(void) {
    if (gOhrtAsked) return;
    NSUserDefaults *defaults = [NSUserDefaults standardUserDefaults];
    gOhrtAsked = [NSMutableArray array];
    NSTimeInterval now = [NSDate date].timeIntervalSince1970;
    for (id when in [defaults arrayForKey:kOhrtAskedKey]) {
        if ([when isKindOfClass:[NSNumber class]] && now - [when doubleValue] < 86400) [gOhrtAsked addObject:when];
    }
    gOhrtPausedUntil = [defaults doubleForKey:kOhrtPausedKey];
}

static void OhrtLikesSaveLimits(void) {
    NSUserDefaults *defaults = [NSUserDefaults standardUserDefaults];
    [defaults setObject:gOhrtAsked forKey:kOhrtAskedKey];
    [defaults setDouble:gOhrtPausedUntil forKey:kOhrtPausedKey];
}

// Whether a read may go out now under the caps, and if not, when to look
// again.
static BOOL OhrtLikesMayAsk(NSTimeInterval *retryAt) {
    OhrtLikesLoadLimits();
    NSTimeInterval now = [NSDate date].timeIntervalSince1970;
    if (gOhrtPausedUntil > now) {
        *retryAt = 0;
        return NO;
    }
    if (gOhrtNextAsk > now) {
        *retryAt = gOhrtNextAsk;
        return NO;
    }
    while (gOhrtAsked.count && now - gOhrtAsked.firstObject.doubleValue >= 86400) [gOhrtAsked removeObjectAtIndex:0];
    NSUInteger lastHour = 0;
    for (NSNumber *when in gOhrtAsked) lastHour += now - when.doubleValue < 3600;
    if (gOhrtAsked.count >= kOhrtLikersPerDay || lastHour >= kOhrtLikersPerHour) {
        static BOOL said;
        if (!said) OhrtLog(@"likes: the %@ cap on reading likers is reached, waiting", gOhrtAsked.count >= kOhrtLikersPerDay ? @"daily" : @"hourly");
        said = YES;
        *retryAt = now + 300;
        return NO;
    }
    return YES;
}

static void OhrtLikesNoteAsk(void) {
    NSTimeInterval now = [NSDate date].timeIntervalSince1970;
    [gOhrtAsked addObject:@(now)];
    OhrtLikesSaveLimits();
    gOhrtNextAsk = now + kOhrtLikersGap + arc4random_uniform(1000) / 1000.0;
}

static void OhrtLikesSkip(NSString *mediaId) {
    if (!mediaId) return;
    if (!gOhrtSkipped) gOhrtSkipped = [NSMutableSet set];
    [gOhrtSkipped addObject:mediaId];
}

static void OhrtLikesDrop(NSString *mediaId) {
    [gOhrtWanted removeObject:mediaId];
    if (!OhrtLikesEntry(mediaId)) OhrtLikesSkip(mediaId);
    OhrtLikesAnnounce(mediaId);
}

BOOL OhrtLikesWillCount(NSString *mediaId) {
    if (!mediaId || !OhrtFeature(kOhrtLikesKey) || OhrtSafeLaunch()) return NO;
    OhrtLikesLoadLimits();
    if (gOhrtPausedUntil > [NSDate date].timeIntervalSince1970) return NO;
    return ![gOhrtSkipped containsObject:mediaId];
}

static void OhrtLikesPump(void);

static void OhrtLikesPumpAt(NSTimeInterval when) {
    if (gOhrtPumpScheduled) return;
    gOhrtPumpScheduled = YES;
    NSTimeInterval wait = MAX(0.05, when - [NSDate date].timeIntervalSince1970);
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(wait * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
        gOhrtPumpScheduled = NO;
        OhrtTry(@"likes", ^{
            OhrtLikesPump();
        });
    });
}

static BOOL OhrtLikersStart(NSString *mediaId, BOOL chrono) {
    Class reader = NSClassFromString(@"IGUserListNetworkDataSource");
    SEL make = NSSelectorFromString(@"initWithUserSession:fetchPath:endpointLoggingIdentifier:");
    SEL setDelegate = NSSelectorFromString(@"setDelegate:");
    SEL setTimeout = NSSelectorFromString(@"setCustomTimeoutInterval:");
    id session = OhrtCurrentSession();
    if (!reader || ![reader instancesRespondToSelector:make] || ![reader instancesRespondToSelector:setDelegate] || !session) return NO;
    OhrtLikersFetch *fetch = [OhrtLikersFetch new];
    fetch.mediaId = mediaId;
    fetch.chrono = chrono;
    NSString *path = [NSString stringWithFormat:chrono ? @"/media/%@/likers_chrono/" : @"/media/%@/likers/", mediaId];
    fetch.source = ((OhrtLikersInit)objc_msgSend)([reader alloc], make, session, path, @"media.likers");
    if (!fetch.source) return NO;
    ((void (*)(id, SEL, id))objc_msgSend)(fetch.source, setDelegate, fetch);
    if ([fetch.source respondsToSelector:setTimeout]) ((void (*)(id, SEL, id))objc_msgSend)(fetch.source, setTimeout, @(kOhrtReaderTimeout));
    gOhrtFetching = fetch;
    __weak OhrtLikersFetch *weakFetch = fetch;
    fetch.done = ^(BOOL refused) {
        if (gOhrtFetching == weakFetch) gOhrtFetching = nil;
        if (weakFetch.wantsPlain) {
            // The usual list is read once the gap since the refused read
            // has passed. A run of refusals with nothing read in between
            // is Instagram saying no to both.
            if (++gOhrtRefusedRun >= kOhrtRefusedRunMost) {
                refused = YES;
            } else {
                NSTimeInterval retryAt = 0;
                if (OhrtLikesMayAsk(&retryAt)) {
                    if (OhrtLikersStart(mediaId, NO)) return;
                } else if (retryAt > 0 && retryAt == gOhrtNextAsk) {
                    gOhrtFallingBack = mediaId;
                    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(MAX(0.05, retryAt - [NSDate date].timeIntervalSince1970) * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
                        OhrtTry(@"likes", ^{
                            gOhrtFallingBack = nil;
                            NSTimeInterval again = 0;
                            if (OhrtLikesMayAsk(&again) && OhrtLikersStart(mediaId, NO)) return;
                            OhrtLikesDrop(mediaId);
                            OhrtLikesPump();
                        });
                    });
                    return;
                }
            }
        }
        if (!OhrtLikesEntry(mediaId)) OhrtLikesSkip(mediaId);
        OhrtLikesAnnounce(mediaId);
        if (refused) {
            gOhrtPausedUntil = [NSDate date].timeIntervalSince1970 + kOhrtLikersPause;
            OhrtLikesSaveLimits();
            NSArray<NSString *> *waiting = gOhrtWanted.array;
            [gOhrtWanted removeAllObjects];
            for (NSString *other in waiting) OhrtLikesAnnounce(other);
            gOhrtRefusedRun = 0;
            OhrtLog(@"likes: Instagram refused, no more likers read for %.0f minutes", kOhrtLikersPause / 60);
            return;
        }
        OhrtLikesPump();
    };
    OhrtLikesNoteAsk();
    fetch.asked = CACurrentMediaTime();
    OhrtCallVoid(fetch.source, @"fetchData");
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(kOhrtLikersTimeout * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
        if (!weakFetch.done) return;
        OhrtLog(@"likes: no answer about who liked a post, skipping it");
        [weakFetch end:NO];
    });
    return YES;
}

static void OhrtLikersArrived(OhrtLikersFetch *fetch) {
    gOhrtRefusedRun = 0;
    BOOL floor = NO;
    NSString *told = nil;
    long long count = OhrtLikesCountIn(fetch.source, &floor, &told);
    static NSUInteger said;
    if (said < 12) {
        said++;
        OhrtLog(@"likes: %@, %@, answered in %.0f ms", fetch.chrono ? @"newest likers" : @"likers", told, (CACurrentMediaTime() - fetch.asked) * 1000);
    }
    if (count > 0) {
        OhrtLikesKeep(fetch.mediaId, count, floor);
        OhrtLikesAnnounce(fetch.mediaId);
    }
    [fetch end:NO];
}

static void OhrtLikesPump(void) {
    if (gOhrtFetching || gOhrtFallingBack || !gOhrtWanted.count) return;
    if ([UIApplication sharedApplication].applicationState != UIApplicationStateActive) return;
    NSTimeInterval retryAt = 0;
    if (!OhrtLikesMayAsk(&retryAt)) {
        if (retryAt > 0) OhrtLikesPumpAt(retryAt);
        return;
    }
    // Newest wanted first: the post on screen now.
    NSString *mediaId = gOhrtWanted.lastObject;
    if (OhrtLikesIsFresh(mediaId)) {
        OhrtLikesDrop(mediaId);
        OhrtLikesPump();
        return;
    }
    [gOhrtWanted removeObject:mediaId];
    if (!OhrtLikersStart(mediaId, YES)) OhrtLikesDrop(mediaId);
}

void OhrtLikesWant(NSString *mediaId) {
    if (!mediaId || !OhrtFeature(kOhrtLikesKey) || OhrtSafeLaunch() || OhrtLikesIsFresh(mediaId)) return;
    OhrtLikesLoadLimits();
    if (gOhrtPausedUntil > [NSDate date].timeIntervalSince1970) return;
    if ([gOhrtFetching.mediaId isEqualToString:mediaId] || [gOhrtFallingBack isEqualToString:mediaId]) return;
    if (!gOhrtWanted) gOhrtWanted = [NSMutableOrderedSet orderedSet];
    if ([gOhrtSkipped containsObject:mediaId]) {
        [gOhrtSkipped removeObject:mediaId];
        OhrtLikesAnnounce(mediaId);
    }
    // On screen again: to the front.
    [gOhrtWanted removeObject:mediaId];
    [gOhrtWanted addObject:mediaId];
    while (gOhrtWanted.count > kOhrtWantedKept) OhrtLikesDrop(gOhrtWanted.firstObject);
    OhrtLikesPump();
}

// Off the screen before its turn: not read.
void OhrtLikesUnwant(NSString *mediaId) {
    if (mediaId && [gOhrtWanted containsObject:mediaId]) OhrtLikesDrop(mediaId);
}

// "Liked by", opened by hand.
static void OhrtLikesTitle(IGFollowListViewController *list) {
    Ivar ivar = class_getInstanceVariable([list class], "_networkDataSource");
    id source = ivar ? object_getIvar(list, ivar) : nil;
    id media = OhrtCallValue(source, @"media");
    if (!media || ![OhrtCallValue(media, @"likeAndViewCountsDisabled") boolValue]) return;
    if (![OhrtCallValue(source, @"numberOfResults") longLongValue]) return;
    // This screen reads the usual list, which stops at about a hundred. A
    // real total read before is kept and shown instead.
    NSString *mediaId = OhrtMediaId(media);
    long long count = 0;
    BOOL plus = NO;
    if (!OhrtLikesCountedNumber(mediaId, &count, &plus) || plus) {
        count = OhrtLikesCountIn(source, &plus, NULL);
        if (mediaId && count > 0) {
            OhrtLikesKeep(mediaId, count, plus);
            OhrtLikesAnnounce(mediaId);
        }
    }
    if (count <= 0) return;
    NSString *title = OhrtLikesText(count, plus);
    list.navigationItem.title = title;
    if ([list.navigationItem.titleView isKindOfClass:[UILabel class]]) {
        ((UILabel *)list.navigationItem.titleView).text = title;
        [list.navigationItem.titleView sizeToFit];
    }
}

%group OhrtLikes

%hook IGFollowListViewController
- (void)_updateTitle {
    %orig;
    OhrtTry(@"likes", ^{
        OhrtLikesTitle(self);
    });
}
%end

%end

void OhrtInstallLikes(void) {
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        if (!OhrtFeatureReady(kOhrtLikesKey, @"likes")) return;
        %init(OhrtLikes);
        [[NSNotificationCenter defaultCenter] addObserverForName:UIApplicationDidBecomeActiveNotification object:nil queue:[NSOperationQueue mainQueue] usingBlock:^(NSNotification *note) {
            OhrtLikesPumpAt([NSDate date].timeIntervalSince1970 + 1);
        }];
    });
}
