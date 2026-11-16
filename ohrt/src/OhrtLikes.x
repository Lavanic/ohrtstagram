// The like count of a post whose owner hid it.
//
// Instagram does not send that count: a post with hidden likes comes with
// a stand-in, the real count up to 3 and then 3, the same for everyone. What
// it does still give is who liked it, and that list is whole: 104 and 105
// people for posts that said 3. So the count is taken from the list: how
// many it lists plus any it says it left unnamed, or the total it gives if
// that is larger, with a "+" when there were more pages than were read.
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

static NSString *const kOhrtCountedKey = @"ohrt_counted_likes";
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
        NSDictionary *kept = [[NSUserDefaults standardUserDefaults] dictionaryForKey:kOhrtCountedKey];
        for (NSString *mediaId in kept) {
            NSArray *entry = kept[mediaId];
            if ([mediaId isKindOfClass:[NSString class]] && [entry isKindOfClass:[NSArray class]] && entry.count == 3) gOhrtCounted[mediaId] = entry;
        }
    });
    return lock;
}

static NSString *OhrtLikesText(long long count, BOOL more) {
    return [NSString stringWithFormat:@"%@%@ %@", OhrtGrouped(count), more ? @"+" : @"", count == 1 && !more ? @"like" : @"likes"];
}

NSString *OhrtLikesCountedFor(NSString *mediaId) {
    if (!mediaId) return nil;
    NSArray<NSNumber *> *counted;
    @synchronized(OhrtCountedLock()) {
        counted = gOhrtCounted[mediaId];
    }
    return counted ? OhrtLikesText(counted[0].longLongValue, counted[1].boolValue) : nil;
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
    *plus = more && listed + anonymous >= total;
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
@property (nonatomic, copy) void (^done)(BOOL refused);
@end

@implementation OhrtLikersFetch

- (void)end:(BOOL)refused {
    void (^done)(BOOL) = self.done;
    self.done = nil;
    if (done) done(refused);
}

- (void)dataSourceDidFinishLoading:(id)source {
    dispatch_async(dispatch_get_main_queue(), ^{
        if (!self.done) return;
        OhrtTry(@"likes", ^{
            long long count = 0;
            BOOL plus = NO;
            OhrtLikesFromList(self.source, @"read who liked a hidden post", &count, &plus);
            if (count > 0) OhrtLikesKeep(self.mediaId, count, plus);
        });
        [self end:NO];
    });
}

- (void)dataSourceDidFailLoad:(id)source {
    dispatch_async(dispatch_get_main_queue(), ^{
        if (!self.done) return;
        BOOL connection = OhrtIsConnectionError(OhrtCallValue(self.source, @"fetchError"));
        OhrtLog(@"likes: reading who liked a post failed, %@", connection ? @"the connection" : @"refused");
        [self end:!connection];
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

static void OhrtLikesDrop(NSString *mediaId) {
    [gOhrtWanted removeObject:mediaId];
    OhrtLikesAnnounce(mediaId);
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

static void OhrtLikesPump(void) {
    if (gOhrtFetching || !gOhrtWanted.count) return;
    if ([UIApplication sharedApplication].applicationState != UIApplicationStateActive) return;
    OhrtLikesLoadLimits();
    NSTimeInterval now = [NSDate date].timeIntervalSince1970;
    if (gOhrtPausedUntil > now) return;
    if (gOhrtNextAsk > now) {
        OhrtLikesPumpAt(gOhrtNextAsk);
        return;
    }
    while (gOhrtAsked.count && now - gOhrtAsked.firstObject.doubleValue >= 86400) [gOhrtAsked removeObjectAtIndex:0];
    NSUInteger lastHour = 0;
    for (NSNumber *when in gOhrtAsked) lastHour += now - when.doubleValue < 3600;
    if (gOhrtAsked.count >= kOhrtLikersPerDay || lastHour >= kOhrtLikersPerHour) {
        static BOOL said;
        if (!said) OhrtLog(@"likes: the %@ cap on reading likers is reached, waiting", gOhrtAsked.count >= kOhrtLikersPerDay ? @"daily" : @"hourly");
        said = YES;
        OhrtLikesPumpAt(now + 300);
        return;
    }

    Class reader = NSClassFromString(@"IGUserListNetworkDataSource");
    SEL make = NSSelectorFromString(@"initWithUserSession:fetchPath:endpointLoggingIdentifier:");
    SEL setDelegate = NSSelectorFromString(@"setDelegate:");
    id session = OhrtCurrentSession();
    if (!reader || ![reader instancesRespondToSelector:make] || ![reader instancesRespondToSelector:setDelegate] || !session) return;

    // Newest wanted first: the post on screen now.
    NSString *mediaId = gOhrtWanted.lastObject;
    if (OhrtLikesCountedFor(mediaId)) {
        OhrtLikesDrop(mediaId);
        OhrtLikesPump();
        return;
    }
    OhrtLikersFetch *fetch = [OhrtLikersFetch new];
    fetch.mediaId = mediaId;
    fetch.source = ((OhrtLikersInit)objc_msgSend)([reader alloc], make, session, [NSString stringWithFormat:@"/media/%@/likers/", mediaId], @"media.likers");
    if (!fetch.source) {
        OhrtLikesDrop(mediaId);
        return;
    }
    [gOhrtWanted removeObject:mediaId];
    ((void (*)(id, SEL, id))objc_msgSend)(fetch.source, setDelegate, fetch);
    gOhrtFetching = fetch;
    [gOhrtAsked addObject:@(now)];
    OhrtLikesSaveLimits();
    gOhrtNextAsk = now + kOhrtLikersGap + arc4random_uniform(1000) / 1000.0;
    __weak OhrtLikersFetch *weakFetch = fetch;
    fetch.done = ^(BOOL refused) {
        if (gOhrtFetching == weakFetch) gOhrtFetching = nil;
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
    OhrtCallVoid(fetch.source, @"fetchData");
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(kOhrtLikersTimeout * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
        if (!weakFetch.done) return;
        OhrtLog(@"likes: no answer about who liked a post, skipping it");
        [weakFetch end:NO];
    });
}

BOOL OhrtLikesPending(NSString *mediaId) {
    if (!mediaId) return NO;
    return [gOhrtWanted containsObject:mediaId] || [gOhrtFetching.mediaId isEqualToString:mediaId];
}

void OhrtLikesWant(NSString *mediaId) {
    if (!mediaId || !OhrtFeature(kOhrtLikesKey) || OhrtSafeLaunch() || OhrtLikesCountedFor(mediaId)) return;
    OhrtLikesLoadLimits();
    if (gOhrtPausedUntil > [NSDate date].timeIntervalSince1970) return;
    if ([gOhrtFetching.mediaId isEqualToString:mediaId]) return;
    if (!gOhrtWanted) gOhrtWanted = [NSMutableOrderedSet orderedSet];
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
