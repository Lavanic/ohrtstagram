// The like count of a post whose owner hid it.
//
// Instagram does not send that count: a post with hidden likes comes with
// a stand-in, mostly 3, that is the same for everyone and goes back to it
// after you like the post. What it does still give is who liked it. So the
// count is taken from that list: its total when the server gives one
// larger than what it lists, otherwise how many it lists, with a "+" when
// there are more pages than were read.
//
// The list is asked for as a hidden post comes by in the feed, through the
// same reader and the same request ("/media/<id>/likers/") as Instagram's
// own "Liked by" screen. Those are list reads, which Instagram meters, so
// it is one at a time, some seconds apart, a limited number an hour, only
// while the app is on screen, and it stops for a while after any failure.
// Each post is counted once and kept. Opening "Liked by" yourself counts
// it too, and puts the count at the top of that screen.
#import <objc/message.h>
#import <objc/runtime.h>

#import "Ohrt.h"
#import "OhrtLogic.h"

NSString *const kOhrtLikesKey = @"ohrt_hidden_likes";
NSString *const kOhrtLikesCountedNotification = @"OhrtLikesCounted";

static NSString *const kOhrtCountedKey = @"ohrt_counted_likes";
static const NSUInteger kOhrtCountedKept = 500;
static const NSTimeInterval kOhrtLikersGap = 4;
static const NSUInteger kOhrtLikersPerHour = 40;
static const NSTimeInterval kOhrtLikersPause = 30 * 60;
static const NSTimeInterval kOhrtLikersTimeout = 20;

typedef id (*OhrtLikersInit)(__attribute__((ns_consumed)) id, SEL, id, id, id) __attribute__((ns_returns_retained));

@interface IGFollowListViewController : UIViewController
@end

NSString *OhrtMediaId(id media) {
    id value = OhrtCallValue(media, @"mediaID") ?: OhrtCallValue(media, @"mediaId");
    if ([value isKindOfClass:[NSNumber class]]) value = [value stringValue];
    return [value isKindOfClass:[NSString class]] && [value length] ? value : nil;
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
    char grouped[32];
    OhrtGroupDigits(count, grouped, sizeof(grouped));
    return [NSString stringWithFormat:@"%s%@ %@", grouped, more ? @"+" : @"", count == 1 && !more ? @"like" : @"likes"];
}

NSString *OhrtLikesCountedFor(NSString *mediaId) {
    if (!mediaId) return nil;
    NSArray<NSNumber *> *counted;
    @synchronized(OhrtCountedLock()) {
        counted = gOhrtCounted[mediaId];
    }
    return counted ? OhrtLikesText(counted[0].longLongValue, counted[1].boolValue) : nil;
}

NSString *OhrtLikesCounted(id media) {
    return OhrtLikesCountedFor(OhrtMediaId(media));
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
    [[NSNotificationCenter defaultCenter] postNotificationName:kOhrtLikesCountedNotification object:mediaId];
}

static void OhrtLikesReport(NSString *how, long long listed, long long total, BOOL more, long long standIn) {
    static NSUInteger told;
    if (told >= 10) return;
    told++;
    OhrtLog(@"likes: %@, %lld listed, a total of %lld given, %@ more to load, the post itself says %lld", how, listed, total, more ? @"with" : @"no", standIn);
}

// Reading one post's likers.

@interface OhrtLikersFetch : NSObject
@property (nonatomic, copy) NSString *mediaId;
@property (nonatomic) long long standIn;
@property (nonatomic, strong) id source;
@property (nonatomic, copy) void (^done)(BOOL worked);
@end

@implementation OhrtLikersFetch

- (void)end:(BOOL)worked {
    void (^done)(BOOL) = self.done;
    self.done = nil;
    if (done) done(worked);
}

- (void)dataSourceDidStartLoading:(id)source {
}

- (void)dataSourceDidFinishLoading:(id)source {
    dispatch_async(dispatch_get_main_queue(), ^{
        if (!self.done) return;
        OhrtTry(@"likes", ^{
            long long listed = [OhrtCallValue(self.source, @"numberOfResults") longLongValue];
            long long total = [OhrtCallValue(self.source, @"totalUsersCount") longLongValue];
            BOOL more = [OhrtCallValue(self.source, @"moreAvailable") boolValue];
            OhrtLikesReport(@"read who liked a hidden post", listed, total, more, self.standIn);
            long long count = MAX(listed, total);
            if (count > 0) OhrtLikesKeep(self.mediaId, count, more && listed >= total);
        });
        [self end:YES];
    });
}

- (void)dataSourceDidFailLoad:(id)source {
    dispatch_async(dispatch_get_main_queue(), ^{
        if (!self.done) return;
        OhrtLog(@"likes: reading who liked a post failed");
        [self end:NO];
    });
}

// The reader may tell its delegate more than these three.
- (NSMethodSignature *)methodSignatureForSelector:(SEL)selector {
    return [super methodSignatureForSelector:selector] ?: [NSMethodSignature signatureWithObjCTypes:"v@:"];
}

- (void)forwardInvocation:(NSInvocation *)invocation {
}

@end

// The queue. Main thread only.

static NSMutableOrderedSet<NSString *> *gOhrtWanted;
static NSMutableDictionary<NSString *, NSNumber *> *gOhrtStandIns;
static NSMutableArray<NSDate *> *gOhrtAsked;
static OhrtLikersFetch *gOhrtFetching;
static NSDate *gOhrtNextAsk;
static NSDate *gOhrtPausedUntil;

static void OhrtLikesPump(void);

static void OhrtLikesPumpLater(NSTimeInterval seconds) {
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(seconds * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
        OhrtTry(@"likes", ^{
            OhrtLikesPump();
        });
    });
}

static void OhrtLikesPump(void) {
    if (gOhrtFetching || !gOhrtWanted.count) return;
    if ([UIApplication sharedApplication].applicationState != UIApplicationStateActive) return;
    NSDate *now = [NSDate date];
    if (gOhrtPausedUntil && [gOhrtPausedUntil compare:now] == NSOrderedDescending) return;
    if (gOhrtNextAsk && [gOhrtNextAsk compare:now] == NSOrderedDescending) {
        OhrtLikesPumpLater([gOhrtNextAsk timeIntervalSinceDate:now] + 0.1);
        return;
    }
    if (!gOhrtAsked) gOhrtAsked = [NSMutableArray array];
    while (gOhrtAsked.count && [now timeIntervalSinceDate:gOhrtAsked.firstObject] > 3600) [gOhrtAsked removeObjectAtIndex:0];
    if (gOhrtAsked.count >= kOhrtLikersPerHour) {
        static BOOL said;
        if (!said) OhrtLog(@"likes: %lu hidden posts read this hour, waiting before the next", (unsigned long)kOhrtLikersPerHour);
        said = YES;
        OhrtLikesPumpLater(3600 - [now timeIntervalSinceDate:gOhrtAsked.firstObject] + 1);
        return;
    }

    // Newest wanted first: the post on screen now.
    NSString *mediaId = gOhrtWanted.lastObject;
    [gOhrtWanted removeObject:mediaId];
    if (OhrtLikesCountedFor(mediaId)) {
        OhrtLikesPump();
        return;
    }
    Class reader = NSClassFromString(@"IGUserListNetworkDataSource");
    SEL make = NSSelectorFromString(@"initWithUserSession:fetchPath:endpointLoggingIdentifier:");
    id session = OhrtCurrentSession();
    if (!reader || ![reader instancesRespondToSelector:make] || !session) return;

    OhrtLikersFetch *fetch = [OhrtLikersFetch new];
    fetch.mediaId = mediaId;
    fetch.standIn = [gOhrtStandIns[mediaId] longLongValue];
    fetch.source = ((OhrtLikersInit)objc_msgSend)([reader alloc], make, session, [NSString stringWithFormat:@"/media/%@/likers/", mediaId], @"media.likers");
    SEL setDelegate = NSSelectorFromString(@"setDelegate:");
    if (!fetch.source || ![fetch.source respondsToSelector:setDelegate]) return;
    ((void (*)(id, SEL, id))objc_msgSend)(fetch.source, setDelegate, fetch);
    gOhrtFetching = fetch;
    [gOhrtAsked addObject:now];
    gOhrtNextAsk = [now dateByAddingTimeInterval:kOhrtLikersGap + arc4random_uniform(3000) / 1000.0];
    __weak OhrtLikersFetch *weakFetch = fetch;
    fetch.done = ^(BOOL worked) {
        if (gOhrtFetching == weakFetch) gOhrtFetching = nil;
        if (!worked) {
            gOhrtPausedUntil = [NSDate dateWithTimeIntervalSinceNow:kOhrtLikersPause];
            [gOhrtWanted removeAllObjects];
            OhrtLog(@"likes: stopped reading likers for %.0f minutes", kOhrtLikersPause / 60);
            [[NSNotificationCenter defaultCenter] postNotificationName:kOhrtLikesCountedNotification object:mediaId];
            return;
        }
        OhrtLikesPump();
    };
    OhrtCallVoid(fetch.source, @"fetchData");
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(kOhrtLikersTimeout * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
        if (weakFetch.done) {
            OhrtLog(@"likes: no answer about who liked a post");
            [weakFetch end:NO];
        }
    });
}

BOOL OhrtLikesPending(NSString *mediaId) {
    if (!mediaId) return NO;
    return [gOhrtWanted containsObject:mediaId] || [gOhrtFetching.mediaId isEqualToString:mediaId];
}

void OhrtLikesWant(id media) {
    if (!OhrtFeature(kOhrtLikesKey) || OhrtSafeLaunch()) return;
    NSString *mediaId = OhrtMediaId(media);
    if (!mediaId || OhrtLikesCountedFor(mediaId)) return;
    NSNumber *standIn = OhrtCallValue(media, @"likeCount");
    dispatch_async(dispatch_get_main_queue(), ^{
        OhrtTry(@"likes", ^{
            if (!gOhrtWanted) gOhrtWanted = [NSMutableOrderedSet orderedSet];
            if (!gOhrtStandIns) gOhrtStandIns = [NSMutableDictionary dictionary];
            if (gOhrtPausedUntil && [gOhrtPausedUntil timeIntervalSinceNow] > 0) return;
            if ([gOhrtWanted containsObject:mediaId] || [gOhrtFetching.mediaId isEqualToString:mediaId]) return;
            [gOhrtWanted addObject:mediaId];
            if ([standIn isKindOfClass:[NSNumber class]]) gOhrtStandIns[mediaId] = standIn;
            // Only the latest few: posts scrolled well past are not read.
            while (gOhrtWanted.count > 12) [gOhrtWanted removeObjectAtIndex:0];
            OhrtLikesPump();
        });
    });
}

// "Liked by", opened by hand.
static void OhrtLikesTitle(IGFollowListViewController *list) {
    Ivar ivar = class_getInstanceVariable([list class], "_networkDataSource");
    id source = ivar ? object_getIvar(list, ivar) : nil;
    id media = OhrtCallValue(source, @"media");
    static BOOL described;
    if (!described && source) {
        described = YES;
        OhrtLog(@"likes: a list screen %@ its post", media ? @"knows" : @"does not know");
    }
    if (!media || ![OhrtCallValue(media, @"likeAndViewCountsDisabled") boolValue]) return;
    long long listed = [OhrtCallValue(source, @"numberOfResults") longLongValue];
    long long total = [OhrtCallValue(source, @"totalUsersCount") longLongValue];
    BOOL more = [OhrtCallValue(source, @"moreAvailable") boolValue];
    if (listed <= 0 && total <= 0) return;
    OhrtLikesReport(@"opened who liked a hidden post", listed, total, more, [OhrtCallValue(media, @"likeCount") longLongValue]);
    long long count = MAX(listed, total);
    BOOL plus = more && listed >= total;
    NSString *mediaId = OhrtMediaId(media);
    if (mediaId) OhrtLikesKeep(mediaId, count, plus);
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
            OhrtLikesPumpLater(2);
        }];
    });
}
