// Fixes to upstream's features, laid over them so that upstream's files
// stay as they are. Ours go in after upstream's hooks, so each of these
// runs first and upstream's runs when it calls on. Where upstream's hook
// does the wrong thing in some case, its switch is read as off for the
// length of that call (OhrtPrefOffBegin) and the right thing is done here.
// The cases and the cures are from Sparkle (efibalogh/sparkle-ig).
#import <objc/runtime.h>

#import "../../src/InstagramHeaders.h"
#import "../../src/Utils.h"
#import "Ohrt.h"

@interface IGSundialFeedDataSource : NSObject
@end

@interface IGRecentSearchStore : NSObject
@end

@interface IGBlendedSearchRecentItemsOrderStore : NSObject
@end

@interface IGDirectRecipientRecentSearchStorage : NSObject
@end

@interface IGSearchEntityRouter : NSObject
@end

static BOOL OhrtNoRecents(void) {
    return [SCIUtils getBoolPref:@"no_recent_searches"];
}

%group OhrtFixes

// Upstream's cap on how many reels can be scrolled through cut every list
// of reels to its first few, so a reel opened from a profile showed the
// profile's first one instead. The cap is for the Reels tab only.
%hook IGSundialFeedDataSource
- (NSArray *)objectsForListAdapter:(id)adapter {
    Ivar ivar = class_getInstanceVariable([self class], "_networkSource");
    id source = ivar ? object_getIvar(self, ivar) : nil;
    SEL tab = NSSelectorFromString(@"isReelsHomeOrTab");
    if (![source respondsToSelector:tab] || OhrtCallBool(source, @"isReelsHomeOrTab")) return %orig;
    void *before = OhrtPrefOffBegin(@"prevent_doom_scrolling");
    @try {
        return %orig;
    } @finally {
        OhrtPrefOffEnd(before);
    }
}
%end

// The same switch stopped every refresh of a reels list. Only the one you
// pull for is meant.
%hook IGSundialFeedViewController
- (void)_refreshReelsWithParamsForNetworkRequest:(NSUInteger)params userDidPullToRefresh:(BOOL)pulled {
    if (pulled) {
        %orig;
        return;
    }
    void *before = OhrtPrefOffBegin(@"prevent_doom_scrolling");
    @try {
        %orig;
    } @finally {
        OhrtPrefOffEnd(before);
    }
}
%end

// Upstream hid the explore grid by not letting its screen set itself up at
// all. It is set up as usual here and then hidden.
%hook IGExploreGridViewController
- (void)viewDidLoad {
    if (![SCIUtils getBoolPref:@"hide_explore_grid"]) {
        %orig;
        return;
    }
    void *before = OhrtPrefOffBegin(@"hide_explore_grid");
    @try {
        %orig;
    } @finally {
        OhrtPrefOffEnd(before);
    }
    ((UIViewController *)self).view.hidden = YES;
}
%end

// "Do not save recent searches": on this Instagram two of upstream's hooks
// no longer attach, so searches were still kept and the ones already kept
// still showed. New ones are not kept, and the kept ones are not listed.
%hook IGSearchEntityRouter
- (id)initWithUserSession:(id)session analyticsModule:(id)module shouldAddToRecents:(BOOL)add mode:(NSUInteger)mode {
    return %orig(session, module, add && !OhrtNoRecents(), mode);
}
%end

%hook IGRecentSearchStore
- (id)recentItems {
    return OhrtNoRecents() ? @[] : %orig;
}
- (id)allItems {
    return OhrtNoRecents() ? @[] : %orig;
}
%end

%hook IGBlendedSearchRecentItemsOrderStore
- (id)recentItems {
    return OhrtNoRecents() ? @[] : %orig;
}
%end

%hook IGDirectRecipientRecentSearchStorage
- (void)_processRecentlySelectedRecipients:(id)recipients {
    if (OhrtNoRecents()) return;
    %orig;
}
- (BOOL)isEmpty {
    return OhrtNoRecents() ? YES : %orig;
}
%end

%end

void OhrtInstallFixes(void) {
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        if (OhrtSafeLaunch()) return;
        %init(OhrtFixes);
    });
}
