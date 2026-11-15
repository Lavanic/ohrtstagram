// Caught up wall: the home feed ends where you had caught up to last time.
//
// It only acts on the following feed, which is in time order: everything
// from the first post older than the mark is left out, the feed stops
// loading more, and a line at the end says so. Reaching that line moves the
// mark up to the newest post above it. The new mark applies from the next
// visit, so the posts you are looking at do not vanish under you.
#import <objc/message.h>
#import <objc/runtime.h>
#import <substrate.h>

#import "../../src/InstagramHeaders.h"
#import "Ohrt.h"
#import "OhrtLogic.h"

// Seconds since 1970 of the newest post that was above the wall when it was
// last reached.
static NSString *const kOhrtCaughtUpKey = @"ohrt_wall_caught_up";

// With no mark yet, the last two days count as new.
static const NSTimeInterval kOhrtFirstWindow = 2 * 24 * 60 * 60;
// Coming back after this long away is a new visit.
static const NSTimeInterval kOhrtNewVisitAfter = 10 * 60;
static const CGFloat kOhrtWallHeight = 132;

// Posts no newer than this are old, for this visit.
static NSTimeInterval gCutoff;
static NSTimeInterval gWentAway;
static __weak id gAdapter;

static char kOhrtWalledKey;
static char kOhrtWallViewKey;
static char kOhrtExtraHeightKey;

static NSTimeInterval OhrtSavedMark(void) {
    NSTimeInterval saved = [[NSUserDefaults standardUserDefaults] doubleForKey:kOhrtCaughtUpKey];
    return OhrtWallMark(saved, [NSDate date].timeIntervalSince1970, kOhrtFirstWindow);
}

#pragma mark - Room for the wall at the end of the list

// The list's layout decides how tall its content is. To put the wall after
// the last post, the layout of this one list reports its content as taller
// by the wall's height. Other lists that share the layout's class go through
// the same replacement and get their own answer back unchanged.
static BOOL OhrtHookContentSize(UICollectionViewLayout *layout) {
    static NSMutableSet<NSString *> *hooked;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        hooked = [NSMutableSet set];
    });
    Class cls = object_getClass(layout);
    NSString *name = NSStringFromClass(cls);
    if ([hooked containsObject:name]) return YES;

    SEL selector = @selector(collectionViewContentSize);
    if (!class_getInstanceMethod(cls, selector)) return NO;
    IMP *original = calloc(1, sizeof(IMP));
    IMP replacement = imp_implementationWithBlock(^CGSize(UICollectionViewLayout *receiver) {
        CGSize size = *original ? ((CGSize (*)(id, SEL))(*original))(receiver, selector) : CGSizeZero;
        NSNumber *extra = objc_getAssociatedObject(receiver, &kOhrtExtraHeightKey);
        if (extra) size.height += extra.doubleValue;
        return size;
    });
    MSHookMessageEx(cls, selector, replacement, original);
    if (!*original) return NO;
    [hooked addObject:name];
    return YES;
}

static void OhrtSetExtraHeight(UICollectionView *list, CGFloat height) {
    UICollectionViewLayout *layout = list.collectionViewLayout;
    if (!layout) return;
    NSNumber *current = objc_getAssociatedObject(layout, &kOhrtExtraHeightKey);
    if (height > 0) {
        if (current || !OhrtHookContentSize(layout)) return;
        objc_setAssociatedObject(layout, &kOhrtExtraHeightKey, @(height), OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    } else {
        if (!current) return;
        objc_setAssociatedObject(layout, &kOhrtExtraHeightKey, nil, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    }
    [layout invalidateLayout];
}

#pragma mark - The wall

@interface OhrtWallView : UIView
@property (nonatomic, weak) UICollectionView *list;
// The newest post above the wall.
@property (nonatomic) NSTimeInterval newest;
@property (nonatomic) BOOL observing;
@end

@implementation OhrtWallView

- (instancetype)initWithFrame:(CGRect)frame {
    self = [super initWithFrame:frame];
    if (!self) return nil;
    self.userInteractionEnabled = NO;

    UIView *line = [UIView new];
    line.backgroundColor = [UIColor separatorColor];
    line.translatesAutoresizingMaskIntoConstraints = NO;

    UILabel *title = [UILabel new];
    title.text = @"You're all caught up";
    title.font = [UIFont systemFontOfSize:17 weight:UIFontWeightSemibold];
    title.textColor = [UIColor labelColor];
    title.textAlignment = NSTextAlignmentCenter;

    UILabel *detail = [UILabel new];
    detail.text = @"That's everything new from the people you follow.";
    detail.font = [UIFont systemFontOfSize:13];
    detail.textColor = [UIColor secondaryLabelColor];
    detail.textAlignment = NSTextAlignmentCenter;
    detail.numberOfLines = 0;

    UIStackView *stack = [[UIStackView alloc] initWithArrangedSubviews:@[ title, detail ]];
    stack.axis = UILayoutConstraintAxisVertical;
    stack.spacing = 6;
    stack.translatesAutoresizingMaskIntoConstraints = NO;

    [self addSubview:line];
    [self addSubview:stack];
    [NSLayoutConstraint activateConstraints:@[
        [line.topAnchor constraintEqualToAnchor:self.topAnchor],
        [line.leadingAnchor constraintEqualToAnchor:self.leadingAnchor],
        [line.trailingAnchor constraintEqualToAnchor:self.trailingAnchor],
        [line.heightAnchor constraintEqualToConstant:1.0 / UIScreen.mainScreen.scale],
        [stack.centerYAnchor constraintEqualToAnchor:self.centerYAnchor],
        [stack.leadingAnchor constraintEqualToAnchor:self.leadingAnchor constant:32],
        [stack.trailingAnchor constraintEqualToAnchor:self.trailingAnchor constant:-32],
    ]];
    return self;
}

- (void)attachTo:(UICollectionView *)list {
    self.list = list;
    OhrtSetExtraHeight(list, kOhrtWallHeight);
    [list addSubview:self];
    [list addObserver:self forKeyPath:@"contentSize" options:0 context:&kOhrtWallViewKey];
    [list addObserver:self forKeyPath:@"contentOffset" options:0 context:&kOhrtWallViewKey];
    self.observing = YES;
    [self place];
}

- (void)detach {
    UICollectionView *list = self.list;
    if (self.observing && list) {
        [list removeObserver:self forKeyPath:@"contentSize" context:&kOhrtWallViewKey];
        [list removeObserver:self forKeyPath:@"contentOffset" context:&kOhrtWallViewKey];
    }
    self.observing = NO;
    if (list) OhrtSetExtraHeight(list, 0);
    [self removeFromSuperview];
}

- (void)observeValueForKeyPath:(NSString *)keyPath ofObject:(id)object change:(NSDictionary *)change context:(void *)context {
    if (context != &kOhrtWallViewKey) {
        [super observeValueForKeyPath:keyPath ofObject:object change:change context:context];
        return;
    }
    [self place];
}

- (void)place {
    UICollectionView *list = self.list;
    if (!list) return;
    CGFloat height = list.contentSize.height;
    // The last stretch of the content is ours when the layout made room.
    // When it could not, the wall sits just past the end, where a pull
    // shows it.
    BOOL roomMade = objc_getAssociatedObject(list.collectionViewLayout, &kOhrtExtraHeightKey) != nil;
    CGRect frame = CGRectMake(0, roomMade ? MAX(height - kOhrtWallHeight, 0) : height, list.bounds.size.width, kOhrtWallHeight);
    if (!CGRectEqualToRect(self.frame, frame)) self.frame = frame;

    if (self.newest <= 0 || !self.window) return;
    if ([UIApplication sharedApplication].applicationState != UIApplicationStateActive) return;
    CGFloat visibleBottom = list.contentOffset.y + list.bounds.size.height - list.adjustedContentInset.bottom;
    if (visibleBottom < CGRectGetMidY(frame)) return;
    NSUserDefaults *defaults = [NSUserDefaults standardUserDefaults];
    if (self.newest > [defaults doubleForKey:kOhrtCaughtUpKey]) [defaults setDouble:self.newest forKey:kOhrtCaughtUpKey];
}

@end

static void OhrtShowWall(id adapter, BOOL show, NSTimeInterval newest) {
    UICollectionView *list = OhrtCall(adapter, @"collectionView");
    if (![list isKindOfClass:[UICollectionView class]]) return;
    OhrtWallView *wall = objc_getAssociatedObject(list, &kOhrtWallViewKey);
    if (!show) {
        if (!wall) return;
        [wall detach];
        objc_setAssociatedObject(list, &kOhrtWallViewKey, nil, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        return;
    }
    if (!wall) {
        wall = [[OhrtWallView alloc] initWithFrame:CGRectZero];
        objc_setAssociatedObject(list, &kOhrtWallViewKey, wall, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        wall.newest = newest;
        [wall attachTo:list];
        return;
    }
    wall.newest = newest;
    [wall place];
}

#pragma mark - The feed

static id OhrtFeedViewModel(id dataSource) {
    Ivar ivar = class_getInstanceVariable(object_getClass(dataSource), "_feedContext");
    id context = ivar ? object_getIvar(dataSource, ivar) : nil;
    return OhrtCall(context, @"viewModel");
}

// True for the following feed's view model and no other. The wall depends
// on time order, and "For you" is not in it.
static BOOL OhrtIsFollowingFeed(id dataSource, id viewModel) {
    if (!viewModel) return NO;
    if (OhrtCallBool(viewModel, @"isInFollowingTab")) return YES;
    id source = OhrtCall(viewModel, @"paginationSource");
    if ([source isKindOfClass:[NSString class]] && [source isEqualToString:@"following"]) return YES;
    Ivar ivar = class_getInstanceVariable(object_getClass(dataSource), "_feedContext");
    id session = OhrtCall(ivar ? object_getIvar(dataSource, ivar) : nil, @"userSession");
    return OhrtCall(session, @"_followingMainFeedViewModel") == viewModel;
}

// The objects up to the first old post. `newest` is set to the time of the
// newest post kept; `cut` says whether anything was left out. Where to cut
// is decided in OhrtLogic.h; this only tells it what each object is.
static NSArray *OhrtCutAtWall(NSArray *objects, NSTimeInterval *newest, BOOL *cut) {
    Class media = objc_getClass("IGMedia");
    NSUInteger count = objects.count;
    if (!media || !count) return objects;
    // What can be left dangling at the end of a cut: a loading spinner,
    // Instagram's own end marker, a header for the next group.
    static NSArray<Class> *trailers;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        NSMutableArray<Class> *found = [NSMutableArray array];
        for (NSString *name in @[ @"IGSpinnerLabelViewModel", @"IGEndOfFeedDemarcatorModel", @"IGFeedGroupHeaderViewModel" ]) {
            Class cls = NSClassFromString(name);
            if (cls) [found addObject:cls];
        }
        trailers = found;
    });

    OhrtFeedItem *items = calloc(count, sizeof(OhrtFeedItem));
    if (!items) return objects;
    for (NSUInteger index = 0; index < count; index++) {
        id object = objects[index];
        if ([object isKindOfClass:media]) {
            NSDate *date = OhrtCall(object, @"takenAtDate");
            if ([date isKindOfClass:[NSDate class]]) {
                items[index].kind = OhrtFeedPost;
                items[index].taken = date.timeIntervalSince1970;
            }
            continue;
        }
        for (Class cls in trailers) {
            if ([object isKindOfClass:cls]) items[index].kind = OhrtFeedTrailer;
        }
    }
    double newestKept = 0;
    size_t keep = OhrtWallKeep(items, count, gCutoff, &newestKept);
    free(items);
    *newest = newestKept;
    if (keep >= count) return objects;
    *cut = YES;
    return [objects subarrayWithRange:NSMakeRange(0, keep)];
}

%group OhrtWall

%hook IGMainFeedListAdapterDataSource
- (id)objectsForListAdapter:(id)adapter {
    NSArray *objects = %orig;
    if (![objects isKindOfClass:[NSArray class]]) return objects;

    __block NSArray *kept = objects;
    __block BOOL cut = NO;
    __block NSTimeInterval newest = 0;
    id viewModel = OhrtFeedViewModel(self);
    BOOL ran = OhrtTry(@"wall", ^{
        if (!OhrtIsFollowingFeed(self, viewModel)) return;
        kept = OhrtCutAtWall(objects, &newest, &cut);
        gAdapter = adapter;
    });
    if (!ran) {
        // Something about this Instagram is not what the wall expects. The
        // feed goes back to being whole.
        kept = objects;
        cut = NO;
    }
    if (viewModel) objc_setAssociatedObject(viewModel, &kOhrtWalledKey, cut ? @YES : nil, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    static NSUInteger lastKept = NSNotFound, lastCount = NSNotFound;
    if (cut && (kept.count != lastKept || objects.count != lastCount)) {
        lastKept = kept.count;
        lastCount = objects.count;
        OhrtLog(@"wall: showing %lu of %lu feed items", (unsigned long)kept.count, (unsigned long)objects.count);
    }
    objects = kept;

    // The list is in the middle of working out an update here. The wall is
    // put up once that is done.
    __weak id weakAdapter = adapter;
    dispatch_async(dispatch_get_main_queue(), ^{
        id strongAdapter = weakAdapter;
        if (!strongAdapter) return;
        BOOL shown = OhrtTry(@"wall", ^{
            OhrtShowWall(strongAdapter, cut, newest);
        });
        if (shown) return;
        // The wall is off for this run; a line left behind from before
        // would be a lie.
        @try {
            OhrtShowWall(strongAdapter, NO, 0);
        } @catch (NSException *exception) {
        }
    });
    return objects;
}
%end

// Past the wall there is nothing to load.
%hook IGMainFeedViewModel
- (BOOL)fetchMoreItemsWithPrefetchType:(NSInteger)type {
    if (objc_getAssociatedObject(self, &kOhrtWalledKey)) return NO;
    return %orig;
}
- (BOOL)fetchMoreItemsWithPrefetchType:(NSInteger)type fetchReason:(NSInteger)reason extraParams:(id)params {
    if (objc_getAssociatedObject(self, &kOhrtWalledKey)) return NO;
    return %orig;
}
%end

%end

%ctor {
    // Nothing is hooked unless the wall is on when the app starts.
    if (!OhrtFeatureReady(kOhrtWallKey, @"wall")) return;
    gCutoff = OhrtSavedMark();
    %init(OhrtWall);

    NSNotificationCenter *center = [NSNotificationCenter defaultCenter];
    [center addObserverForName:UIApplicationDidEnterBackgroundNotification object:nil queue:[NSOperationQueue mainQueue] usingBlock:^(NSNotification *note) {
        gWentAway = [NSDate date].timeIntervalSince1970;
    }];
    [center addObserverForName:UIApplicationWillEnterForegroundNotification object:nil queue:[NSOperationQueue mainQueue] usingBlock:^(NSNotification *note) {
        if (gWentAway <= 0 || [NSDate date].timeIntervalSince1970 - gWentAway < kOhrtNewVisitAfter) return;
        NSTimeInterval mark = OhrtSavedMark();
        if (mark <= gCutoff) return;
        gCutoff = mark;
        id adapter = gAdapter;
        SEL update = NSSelectorFromString(@"performUpdatesAnimated:completion:");
        if ([adapter respondsToSelector:update]) ((void (*)(id, SEL, BOOL, id))objc_msgSend)(adapter, update, NO, nil);
    }];
}
