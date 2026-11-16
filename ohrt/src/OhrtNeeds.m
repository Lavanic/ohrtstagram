// What each of our features needs from Instagram, checked on the phone.
//
// The build checks the hooks against one Instagram version
// (ohrt/tools/hookaudit.py, which reads this table too). This is the same
// check made against the Instagram that is actually running: a feature
// whose classes or methods are not all there is left off and says so in
// settings, instead of being half installed.
#import <objc/runtime.h>

#import "Ohrt.h"

typedef struct {
    const char *feature;
    const char *cls;
    const char *selector;
    BOOL onClass;
} OhrtNeed;

#define OHRT_NEED(feature, cls, selector) {feature, cls, selector, NO}
#define OHRT_NEED_CLASS(feature, cls, selector) {feature, cls, selector, YES}

static const OhrtNeed kOhrtNeeds[] = {
    OHRT_NEED("start", "IGInstagramAppDelegate", "application:willFinishLaunchingWithOptions:"),
    OHRT_NEED("start", "IGInstagramAppDelegate", "application:didFinishLaunchingWithOptions:"),

    OHRT_NEED("following", "IGUserSession", "selectedMainFeedViewModel"),
    OHRT_NEED("following", "IGUserSession", "_followingMainFeedViewModel"),
    OHRT_NEED("following", "IGMainFeedNetworkSource", "updatePaginationSource:nextMaxID:"),

    OHRT_NEED("wall", "IGUserSession", "selectedMainFeedViewModel"),
    OHRT_NEED("wall", "IGUserSession", "_followingMainFeedViewModel"),
    OHRT_NEED("wall", "IGMainFeedNetworkSource", "updatePaginationSource:nextMaxID:"),
    OHRT_NEED("wall", "IGMainFeedListAdapterDataSource", "objectsForListAdapter:"),
    OHRT_NEED("wall", "IGMainFeedContext", "viewModel"),
    OHRT_NEED("wall", "IGMainFeedViewModel", "fetchMoreItemsWithPrefetchType:"),
    OHRT_NEED("wall", "IGMainFeedViewModel", "fetchMoreItemsWithPrefetchType:fetchReason:extraParams:"),
    OHRT_NEED("wall", "IGMedia", "takenAtDate"),
    OHRT_NEED("wall", "IGListAdapter", "collectionView"),
    OHRT_NEED("wall", "IGListAdapter", "objects"),

    OHRT_NEED("wordmark", "IGHomeFeedHeaderView", "setTitle:animated:"),
    OHRT_NEED("wordmark", "IGHomeFeedHeaderView", "layoutSubviews"),

    OHRT_NEED("facts", "IGProfileHeaderView", "objectsForListAdapter:"),
    OHRT_NEED("facts", "IGProfileHeaderView", "listAdapter:sectionControllerForObject:"),
    OHRT_NEED("facts", "IGListSectionController", "sizeForItemAtIndex:"),
    OHRT_NEED("facts", "IGListSectionController", "collectionContext"),
    OHRT_NEED("facts", "IGListAdapter", "dequeueReusableCellOfClass:forSectionController:atIndex:"),
    OHRT_NEED("facts", "IGUser", "followsCurrentUser"),
    OHRT_NEED("facts", "IGUser", "followedByCurrentUser"),

    OHRT_NEED("activity", "IGMedia", "performLike:userInfo:navState:analyticsModule:requestSourceParams:userSession:sponsoredSupportConfiguration:completion:"),
    OHRT_NEED("activity", "IGStoryViewerViewController", "fullscreenSectionController:didMarkItemAsSeen:"),
    OHRT_NEED("activity", "IGStoryLikesInteractionControllingImpl", "_sendStoryLikeWithLikeButton:"),
    OHRT_NEED("activity", "IGUserSession", "friendStatusChangedAnnouncer"),
    OHRT_NEED("activity", "IGUserSession", "commentPostedAnnouncer"),
    OHRT_NEED("activity", "IGUserSession", "saveStatusAnnouncer"),

    OHRT_NEED("suggested", "IGProfileHeaderView", "objectsForListAdapter:"),

    OHRT_NEED("dm", "IGTabBarController", "viewWillAppear:"),
    OHRT_NEED("dm", "IGTabBarController", "_tabBarHasDirectInbox"),
    OHRT_NEED("dm", "IGTabBarController", "_directInboxButtonPressed"),

    OHRT_NEED("followback", "IGTabBarController", "userSession"),
    OHRT_NEED("followback", "IGUserSession", "user"),
    OHRT_NEED("followback", "IGUser", "pk"),
    OHRT_NEED("followback", "IGUser", "username"),
    OHRT_NEED("followback", "IGUserListNetworkDataSource", "initWithUserSession:fetchPath:endpointLoggingIdentifier:"),
    OHRT_NEED("followback", "IGUserListNetworkDataSource", "setDelegate:"),
    OHRT_NEED("followback", "IGUserListNetworkDataSource", "fetchData"),
    OHRT_NEED("followback", "IGUserListNetworkDataSource", "moreAvailable"),
    OHRT_NEED("followback", "IGUserListNetworkDataSource", "allResults"),

    OHRT_NEED_CLASS("unfollow", "IGFollowButtonViewConfiguration", "defaultButtonConfiguration"),
    OHRT_NEED("unfollow", "IGFollowController", "initWithViewConfiguration:"),
    OHRT_NEED("unfollow", "IGFollowController", "setUserSession:"),
    OHRT_NEED("unfollow", "IGFollowController", "setUser:"),
    OHRT_NEED("unfollow", "IGFollowController", "_performUnfollow"),
    OHRT_NEED("unfollow", "IGUser", "followStatus"),
};

static const size_t kOhrtNeedCount = sizeof(kOhrtNeeds) / sizeof(kOhrtNeeds[0]);

// Read off the classes' own method lists. Asking the class
// (respondsToSelector:) or the runtime's lookup (class_getInstanceMethod)
// would, for a method that is missing, run the class's code to give it a
// chance to supply one, and this is called while the app is starting.
static BOOL OhrtHasMethod(Class cls, SEL selector) {
    for (Class current = cls; current; current = class_getSuperclass(current)) {
        unsigned int count = 0;
        Method *methods = class_copyMethodList(current, &count);
        BOOL found = NO;
        for (unsigned int index = 0; index < count && !found; index++) found = method_getName(methods[index]) == selector;
        free(methods);
        if (found) return YES;
    }
    return NO;
}

static BOOL OhrtNeedMet(const OhrtNeed *need) {
    Class cls = objc_getClass(need->cls);
    if (!cls) return NO;
    return OhrtHasMethod(need->onClass ? object_getClass(cls) : cls, sel_registerName(need->selector));
}

NSString *OhrtMissing(NSString *feature) {
    NSMutableArray<NSString *> *missing = [NSMutableArray array];
    for (size_t index = 0; index < kOhrtNeedCount; index++) {
        const OhrtNeed *need = &kOhrtNeeds[index];
        if (strcmp(need->feature, feature.UTF8String) != 0 || OhrtNeedMet(need)) continue;
        [missing addObject:[NSString stringWithFormat:@"%c[%s %s]", need->onClass ? '+' : '-', need->cls, need->selector]];
    }
    return missing.count ? [missing componentsJoinedByString:@", "] : nil;
}

BOOL OhrtAvailable(NSString *feature) {
    return OhrtMissing(feature) == nil;
}

// On when its switch is, this start is not in safe mode, and Instagram has
// what it needs.
BOOL OhrtFeatureReady(NSString *key, NSString *feature) {
    if (!OhrtFeature(key)) return NO;
    NSString *missing = OhrtMissing(feature);
    if (!missing) return YES;
    OhrtLog(@"%@ is switched on but left off: this Instagram lacks %@", feature, missing);
    return NO;
}

NSString *OhrtSelfCheck(void) {
    NSMutableString *report = [NSMutableString string];
    NSString *instagram = [[NSBundle mainBundle] objectForInfoDictionaryKey:@"CFBundleShortVersionString"];
    [report appendFormat:@"ohrtstagram %@ (%@) on Insta\u2060gram %@, iOS %@\n", OHRT_VERSION, OHRT_BUILD, instagram, [UIDevice currentDevice].systemVersion];
    [report appendFormat:@"safe mode this start: %@\n", OhrtSafeLaunch() ? @"yes" : @"no"];
    for (NSString *feature in @[ @"start", @"wordmark", @"facts", @"activity", @"following", @"wall", @"dm", @"followback", @"unfollow" ]) {
        NSString *missing = OhrtMissing(feature);
        [report appendFormat:@"%@: %@\n", feature, missing ? [@"missing " stringByAppendingString:missing] : @"ok"];
    }
    return report;
}
