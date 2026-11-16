// The like count of a post whose owner hid it.
//
// Instagram does not send that count: a post with hidden likes comes with
// a stand-in, the real count up to 3 and then 3, the same for everyone. Of
// the two lists of who liked a post, the usual one ("/media/<id>/likers/")
// names about a hundred and gives the same stand-in as its total. The
// newest-first one ("/media/<id>/likers_chrono/") gives the real total
// (145 for a post whose usual list said 3), so that is read, and the usual
// one only if it fails. A total that is still a stand-in falls back to the
// names counted, as "at least" when the list is full; should the server
// then offer a next page, up to ten are read.
//
// The list is asked for when a hidden post's facts row comes on screen,
// through the same reader and the same request ("/media/<id>/likers/") as
// Instagram's own "Liked by" screen. List reads are metered, so they go one
// at a time, a moment apart, newest on screen first, with an hourly and a
// daily cap, only while the app is in front. A refusal from Instagram stops
// them for a while; a dropped connection only skips that post. Each post is
// counted once and kept. Opening "Liked by" yourself counts it too, and puts
// the count at the top of that screen.
#import <objc/message.h>
#import <objc/runtime.h>

#import "Ohrt.h"

NSString *const kOhrtLikesKey = @"ohrt_hidden_likes";
NSString *const kOhrtLikesCountedNotification = @"OhrtLikesCounted";

// The first key held full lists counted as exact; they are dropped.
static NSString *const kOhrtCountedKey = @"ohrt_counted_likes_2";
static NSString *const kOhrtCountedOldKey = @"ohrt_counted_likes";
// The usual list names about a hundred, sometimes fewer: from this many on,
// a list whose total is a stand-in is taken as full.
static const long long kOhrtLikersFloor = 80;
static NSString *const kOhrtAskedKey = @"ohrt_likers_asked";
static NSString *const kOhrtPausedKey = @"ohrt_likers_paused";
static const NSUInteger kOhrtCountedKept = 500;
// The follower check that read about 160 lists 2 to 4 s apart went through;
// a second one straight after was refused. These stay under that.
static const NSTimeInterval kOhrtLikersGap = 1.5;
static const NSUInteger kOhrtLikersPerHour = 150;
static const NSUInteger kOhrtLikersPerDay = 600;
static const NSTimeInterval kOhrtLikersPause = 15 * 60;
static const NSTimeInterval kOhrtLikersTimeout = 15;
static const NSUInteger kOhrtWantedKept = 8;
// Pages of likers read for one post when the server offers more.
static const NSUInteger kOhrtLikersPages = 10;

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

static NSObject *OhrtCountedLock(void) {
    static NSObject *lock;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        lock = [NSObject new];
        gOhrtCounted = [NSMutableDictionary dictionary];
        [[NSUserDefaults standardUserDefaults] removeObjectForKey:kOhrtCountedOldKey];
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

BOOL OhrtLikesCountedNumber(NSString *mediaId, long long *count, BOOL *more) {
    if (!mediaId) return NO;
    NSArray<NSNumber *> *counted;
    @synchronized(OhrtCountedLock()) {
        counted = gOhrtCounted[mediaId];
    }
    if (!counted) return NO;
    if (count) *count = counted[0].longLongValue;
    if (more) *more = counted[1].boolValue;
    return YES;
}

NSString *OhrtLikesCountedFor(NSString *mediaId) {
    long long count = 0;
    BOOL more = NO;
    return OhrtLikesCountedNumber(mediaId, &count, &more) ? OhrtLikesText(count, more) : nil;
}

static void OhrtLikesAnnounce(NSString *mediaId) {
    if (mediaId) [[NSNotificationCenter defaultCenter] postNotificationName:kOhrtLikesCountedNotification object:mediaId];
}

// Main thread.
static void OhrtLikesKeep(NSString *mediaId, long long count, BOOL more) {
    NSDictionary *save;
    @synchronized(OhrtCountedLock()) {
        gOhrtCounted[mediaId] = @[ @(count), @(more), @((long long)[NSDate date].timeIntervalSince1970) ];
        if (gOhrtCounted.count > kOhrtCountedKept) {
            NSArray<NSString *> *oldest = [gOhrtCounted keysSortedByValueUsingComparator:^NSComparisonResult(NSArray *one, NSArray *other) {
                return [one[2] compare:other[2]];
            }];
            [gOhrtCounted removeObjectsForKeys:[oldest subarrayWithRange:NSMakeRange(0, gOhrtCounted.count - kOhrtCountedKept)]];
        }
        save = [gOhrtCounted copy];
    }
    [[NSUserDefaults standardUserDefaults] setObject:save forKey:kOhrtCountedKey];
}

// The count from a likers reader that has loaded: those it names, plus
// those it says it left unnamed, or the total it gives if that is larger.
static void OhrtLikesFromList(id source, NSString *how, long long *count, BOOL *plus) {
    long long listed = [OhrtCallValue(source, @"numberOfResults") longLongValue];
    long long total = [OhrtCallValue(source, @"totalUsersCount") longLongValue];
    Ivar ivar = class_getInstanceVariable([source class], "_anonymousUsersCount");
    id unnamed = ivar ? object_getIvar(source, ivar) : nil;
    long long anonymous = [unnamed isKindOfClass:[NSNumber class]] ? [unnamed longLongValue] : 0;
    BOOL more = [OhrtCallValue(source, @"moreAvailable") boolValue];
    *count = MAX(listed + MAX(anonymous, 0), total);
    // A full list stops at about a hundred names and says there are no
    // more, so a count that reaches that is only a floor.
    *plus = total <= 3 && listed + anonymous > total && listed >= kOhrtLikersFloor;
    static NSUInteger told;
    if (told < 10) {
        told++;
        OhrtLog(@"likes: %@, %lld listed, %lld unnamed, a total of %lld given, %@ more to load", how, listed, anonymous, total, more ? @"with" : @"no");
    }
}

// The other count fields a hidden post comes with, logged for the first
// few, in case the server fills one of them with the real number.
void OhrtLikesDescribe(id media) {
    static NSUInteger told;
    static NSObject *lock;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        lock = [NSObject new];
    });
    @synchronized(lock) {
        if (told >= 6) return;
        told++;
    }
    NSMutableArray<NSString *> *found = [NSMutableArray array];
    for (NSString *field in @[ @"likeCount", @"igLikeCount", @"totalRelevantLikeCount", @"thLikeCount", @"fbLikeCount", @"likeCountDeliveredWithLastUpdate" ]) {
        id value = OhrtCallValue(media, field);
        [found addObject:[NSString stringWithFormat:@"%@ %@", field, [value isKindOfClass:[NSNumber class]] ? [value stringValue] : @"none"]];
    }
    OhrtLog(@"likes: a hidden post came with %@", [found componentsJoinedByString:@", "]);
}

// Reading one post's likers.

@interface OhrtLikersFetch : NSObject
@property (nonatomic, copy) NSString *mediaId;
@property (nonatomic, strong) id source;
// The newest-first list, which gives the real total. If it fails, the
// usual list is read instead.
@property (nonatomic) BOOL chrono;
@property (nonatomic) BOOL wantsPlain;
@property (nonatomic) NSUInteger pages;
@property (nonatomic) NSUInteger generation;
// Account ids named so far, so that a page repeating another is not counted
// twice, whether the reader adds each page to the last or replaces it.
@property (nonatomic, strong) NSMutableSet<NSString *> *named;
@property (nonatomic, copy) void (^done)(BOOL refused);
@end

static void OhrtLikersPageArrived(OhrtLikersFetch *fetch);

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
                OhrtLikersPageArrived(self);
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
// again. Every read, first page or later, counts.
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
    if (!OhrtLikesCountedFor(mediaId)) OhrtLikesSkip(mediaId);
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

// Asks the reader for its next page, with a limit on how long to wait.
static void OhrtLikersFetchPage(OhrtLikersFetch *fetch) {
    OhrtLikesNoteAsk();
    NSUInteger generation = ++fetch.generation;
    OhrtCallVoid(fetch.source, @"fetchData");
    __weak OhrtLikersFetch *weakFetch = fetch;
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(kOhrtLikersTimeout * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
        if (!weakFetch.done || weakFetch.generation != generation) return;
        OhrtLog(@"likes: no answer about who liked a post, skipping it");
        [weakFetch end:NO];
    });
}

static BOOL OhrtLikersStart(NSString *mediaId, BOOL chrono) {
    Class reader = NSClassFromString(@"IGUserListNetworkDataSource");
    SEL make = NSSelectorFromString(@"initWithUserSession:fetchPath:endpointLoggingIdentifier:");
    SEL setDelegate = NSSelectorFromString(@"setDelegate:");
    id session = OhrtCurrentSession();
    if (!reader || ![reader instancesRespondToSelector:make] || ![reader instancesRespondToSelector:setDelegate] || !session) return NO;
    OhrtLikersFetch *fetch = [OhrtLikersFetch new];
    fetch.mediaId = mediaId;
    fetch.chrono = chrono;
    fetch.named = [NSMutableSet set];
    NSString *path = [NSString stringWithFormat:chrono ? @"/media/%@/likers_chrono/" : @"/media/%@/likers/", mediaId];
    fetch.source = ((OhrtLikersInit)objc_msgSend)([reader alloc], make, session, path, @"media.likers");
    if (!fetch.source) return NO;
    ((void (*)(id, SEL, id))objc_msgSend)(fetch.source, setDelegate, fetch);
    gOhrtFetching = fetch;
    __weak OhrtLikersFetch *weakFetch = fetch;
    fetch.done = ^(BOOL refused) {
        if (gOhrtFetching == weakFetch) gOhrtFetching = nil;
        NSTimeInterval retryAt = 0;
        if (weakFetch.wantsPlain && OhrtLikesMayAsk(&retryAt) && OhrtLikersStart(mediaId, NO)) return;
        if (!OhrtLikesCountedFor(mediaId)) OhrtLikesSkip(mediaId);
        OhrtLikesAnnounce(mediaId);
        if (refused) {
            gOhrtPausedUntil = [NSDate date].timeIntervalSince1970 + kOhrtLikersPause;
            OhrtLikesSaveLimits();
            NSArray<NSString *> *waiting = gOhrtWanted.array;
            [gOhrtWanted removeAllObjects];
            for (NSString *other in waiting) OhrtLikesAnnounce(other);
            OhrtLog(@"likes: Instagram refused, no more likers read for %.0f minutes", kOhrtLikersPause / 60);
            return;
        }
        OhrtLikesPump();
    };
    OhrtLikersFetchPage(fetch);
    return YES;
}

static void OhrtLikersPageArrived(OhrtLikersFetch *fetch) {
    fetch.pages++;
    id source = fetch.source;
    id results = OhrtCallValue(source, @"allResults");
    if ([results isKindOfClass:[NSArray class]]) {
        for (id user in (NSArray *)results) {
            id pk = OhrtCallValue(user, @"pk");
            if ([pk isKindOfClass:[NSNumber class]]) pk = [pk stringValue];
            if ([pk isKindOfClass:[NSString class]]) [fetch.named addObject:pk];
        }
    }
    long long listed = [OhrtCallValue(source, @"numberOfResults") longLongValue];
    long long named = MAX((long long)fetch.named.count, listed);
    long long total = [OhrtCallValue(source, @"totalUsersCount") longLongValue];
    Ivar ivar = class_getInstanceVariable([source class], "_anonymousUsersCount");
    id unnamed = ivar ? object_getIvar(source, ivar) : nil;
    long long anonymous = [unnamed isKindOfClass:[NSNumber class]] ? MAX([unnamed longLongValue], 0) : 0;
    id cursor = OhrtCallValue(source, @"maxID");
    BOOL hasCursor = ([cursor isKindOfClass:[NSString class]] && [cursor length]) || [cursor isKindOfClass:[NSNumber class]];
    BOOL more = [OhrtCallValue(source, @"moreAvailable") boolValue];
    // A total above the stand-in's ceiling, or one the names do not pass,
    // is the real count. Otherwise the names are the count, and a full list
    // of them only a floor.
    BOOL real = total > 3 || total >= named + anonymous;
    long long count = real ? MAX(total, named + anonymous) : named + anonymous;
    BOOL full = !real && named >= kOhrtLikersFloor;
    BOOL another = full && more && hasCursor && fetch.pages < kOhrtLikersPages;

    static NSUInteger told;
    if (told < 12) {
        told++;
        OhrtLog(@"likes: %@ page %lu, %lld named so far, %lld unnamed, a total of %lld given, %@ cursor, %@ more", fetch.chrono ? @"newest likers" : @"likers",
                (unsigned long)fetch.pages, named, anonymous, total, hasCursor ? @"a" : @"no", more ? @"says" : @"no");
    }

    if (count > 0) {
        OhrtLikesKeep(fetch.mediaId, count, full);
        OhrtLikesAnnounce(fetch.mediaId);
    }

    if (another) {
        NSTimeInterval retryAt = 0;
        if (OhrtLikesMayAsk(&retryAt)) {
            OhrtLikersFetchPage(fetch);
            return;
        }
        if (retryAt > 0) {
            NSUInteger generation = ++fetch.generation;
            __weak OhrtLikersFetch *weakFetch = fetch;
            dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(MAX(0.05, retryAt - [NSDate date].timeIntervalSince1970) * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
                if (!weakFetch.done || weakFetch.generation != generation) return;
                OhrtTry(@"likes", ^{
                    NSTimeInterval later = 0;
                    if (OhrtLikesMayAsk(&later)) OhrtLikersFetchPage(weakFetch);
                    else [weakFetch end:NO];
                });
            });
            return;
        }
    }
    [fetch end:NO];
}

static void OhrtLikesPump(void) {
    if (gOhrtFetching || !gOhrtWanted.count) return;
    if ([UIApplication sharedApplication].applicationState != UIApplicationStateActive) return;
    NSTimeInterval retryAt = 0;
    if (!OhrtLikesMayAsk(&retryAt)) {
        if (retryAt > 0) OhrtLikesPumpAt(retryAt);
        return;
    }
    // Newest wanted first: the post on screen now.
    NSString *mediaId = gOhrtWanted.lastObject;
    if (OhrtLikesCountedFor(mediaId)) {
        OhrtLikesDrop(mediaId);
        OhrtLikesPump();
        return;
    }
    [gOhrtWanted removeObject:mediaId];
    if (!OhrtLikersStart(mediaId, YES)) OhrtLikesDrop(mediaId);
}

void OhrtLikesWant(NSString *mediaId) {
    if (!mediaId || !OhrtFeature(kOhrtLikesKey) || OhrtSafeLaunch() || OhrtLikesCountedFor(mediaId)) return;
    OhrtLikesLoadLimits();
    if (gOhrtPausedUntil > [NSDate date].timeIntervalSince1970) return;
    if ([gOhrtFetching.mediaId isEqualToString:mediaId]) return;
    if (!gOhrtWanted) gOhrtWanted = [NSMutableOrderedSet orderedSet];
    if ([gOhrtSkipped containsObject:mediaId]) {
        [gOhrtSkipped removeObject:mediaId];
        OhrtLikesAnnounce(mediaId);
    }
    // On screen again: to the front.
    [gOhrtWanted removeObject:mediaId];
    [gOhrtWanted addObject:mediaId];
    // Only the latest few: posts scrolled well past are not read.
    while (gOhrtWanted.count > kOhrtWantedKept) OhrtLikesDrop(gOhrtWanted.firstObject);
    OhrtLikesPump();
}

// "Liked by", opened by hand.
static void OhrtLikesTitle(IGFollowListViewController *list) {
    Ivar ivar = class_getInstanceVariable([list class], "_networkDataSource");
    id source = ivar ? object_getIvar(list, ivar) : nil;
    id media = OhrtCallValue(source, @"media");
    if (!media || ![OhrtCallValue(media, @"likeAndViewCountsDisabled") boolValue]) return;
    if (![OhrtCallValue(source, @"numberOfResults") longLongValue]) return;
    long long count = 0;
    BOOL plus = NO;
    OhrtLikesFromList(source, @"opened who liked a hidden post", &count, &plus);
    NSString *mediaId = OhrtMediaId(media);
    if (mediaId && count > 0) {
        OhrtLikesKeep(mediaId, count, plus);
        OhrtLikesAnnounce(mediaId);
    }
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
