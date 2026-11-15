// Following feed: home shows only the accounts you follow, newest first.
//
// Instagram already has this feed, as the "Following" lane next to "For
// you". Each session keeps a view model for both, and this makes the home
// tab use the following one. The approach is the one InstaSane
// (github.com/n3d1117/InstaSane) and Sparkle take, cut down to the methods
// Instagram 418.2.0 has.
#import "../../src/InstagramHeaders.h"
#import "Ohrt.h"

// Instagram's number for "Following" among the feeds in the picker.
static const NSInteger kOhrtPickerFollowing = 5;

%group OhrtFollowing

%hook IGUserSession
- (id)selectedMainFeedViewModel {
    return OhrtCall(self, @"_followingMainFeedViewModel") ?: %orig;
}
%end

// Demangled name: IGDSAShared.IGDSAGatingManager
%hook _TtC11IGDSAShared18IGDSAGatingManager
// The lane Instagram remembers as the user's choice. 1 is Following.
- (NSInteger)feedStickyContentLaneSelection {
    return 1;
}
%end

%hook IGHomeFeedPickerMenuController
- (id)initWithUserSession:(id)session menuItems:(NSArray *)items homeFeedViewModel:(id)viewModel analyticsModule:(id)module navigationController:(id)navigation isForYouContentLaneEnabled:(BOOL)forYou {
    if ([items isKindOfClass:[NSArray class]]) {
        NSMutableArray *reordered = [items mutableCopy];
        [reordered removeObject:@(kOhrtPickerFollowing)];
        [reordered insertObject:@(kOhrtPickerFollowing) atIndex:0];
        items = reordered;
    }
    return %orig(session, items, viewModel, module, navigation, forYou);
}
%end

%hook IGHomeFeedHeaderView
- (void)setTitle:(id)title animated:(BOOL)animated {
    if ([title isKindOfClass:[NSString class]] && [title isEqualToString:@"For you"]) title = @"Following";
    %orig(title, animated);
}
%end

%end

%ctor {
    // Nothing is hooked unless the feed is on when the app starts.
    if (OhrtFollowingFeedEnabled()) %init(OhrtFollowing);
}
