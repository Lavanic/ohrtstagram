// The like count of a post whose owner hid it.
//
// Instagram does not send that count: a post with hidden likes comes with
// a stand-in, mostly 3, that is the same for everyone and goes back to it
// after you like the post. What it does still send is who liked it, when
// you open that list. So the count is taken there: the list's total when
// the server gives one larger than what is listed, otherwise how many are
// listed, with a "+" while there are more to load. It shows at the top of
// the list, and the post's facts line has it from then on.
//
// Nothing extra is asked of Instagram. The list is the one it loads when
// you tap "Liked by".
#import <objc/runtime.h>

#import "Ohrt.h"
#import "OhrtLogic.h"

NSString *const kOhrtLikesKey = @"ohrt_hidden_likes";

@interface IGFollowListViewController : UIViewController
@end

// Counted so far, by post id, as {count, more}. Read by the facts line on
// whichever thread makes a post's rows.
static NSMutableDictionary<NSString *, NSArray<NSNumber *> *> *gOhrtCounted;

static NSObject *OhrtCountedLock(void) {
    static NSObject *lock;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        lock = [NSObject new];
        gOhrtCounted = [NSMutableDictionary dictionary];
    });
    return lock;
}

static NSString *OhrtLikesMediaId(id media) {
    id value = OhrtCallValue(media, @"mediaID") ?: OhrtCallValue(media, @"mediaId");
    if ([value isKindOfClass:[NSNumber class]]) value = [value stringValue];
    return [value isKindOfClass:[NSString class]] && [value length] ? value : nil;
}

static NSString *OhrtLikesText(long long count, BOOL more) {
    char grouped[32];
    OhrtGroupDigits(count, grouped, sizeof(grouped));
    return [NSString stringWithFormat:@"%s%@ %@", grouped, more ? @"+" : @"", count == 1 && !more ? @"like" : @"likes"];
}

NSString *OhrtLikesCounted(id media) {
    NSString *mediaId = OhrtLikesMediaId(media);
    if (!mediaId) return nil;
    NSArray<NSNumber *> *counted;
    @synchronized(OhrtCountedLock()) {
        counted = gOhrtCounted[mediaId];
    }
    return counted ? OhrtLikesText(counted[0].longLongValue, counted[1].boolValue) : nil;
}

static void OhrtLikesTitle(IGFollowListViewController *list) {
    Ivar ivar = class_getInstanceVariable([list class], "_networkDataSource");
    id source = ivar ? object_getIvar(list, ivar) : nil;
    id media = OhrtCallValue(source, @"media");
    if (!media || ![OhrtCallValue(media, @"likeAndViewCountsDisabled") boolValue]) return;
    long long listed = [OhrtCallValue(source, @"numberOfResults") longLongValue];
    long long total = [OhrtCallValue(source, @"totalUsersCount") longLongValue];
    BOOL more = [OhrtCallValue(source, @"moreAvailable") boolValue];
    if (listed <= 0 && total <= 0) return;
    long long count = MAX(listed, total);
    BOOL plus = more && listed >= total;

    static NSUInteger told;
    if (told < 6) {
        told++;
        OhrtLog(@"likes: who liked a hidden post, %lld listed, a total of %lld given, %@ more to load, and the post itself says %lld", listed, total, more ? @"with" : @"no",
                [OhrtCallValue(media, @"likeCount") longLongValue]);
    }

    NSString *mediaId = OhrtLikesMediaId(media);
    if (mediaId) {
        @synchronized(OhrtCountedLock()) {
            gOhrtCounted[mediaId] = @[ @(count), @(plus) ];
        }
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
    });
}
