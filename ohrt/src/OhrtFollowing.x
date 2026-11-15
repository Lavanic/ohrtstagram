// Following feed: home shows only the accounts you follow, newest first.
//
// Instagram already has this feed. Where the law makes it offer a feed that
// is not ranked for you, the home tab has two lanes, "For you" and
// "Following", and remembers which one you chose. Every session keeps a
// view model for each, and one method picks between them (read out of
// 418.2.0 with ohrt/tools/calls.py):
//
//   -[IGUserSession selectedMainFeedViewModel]
//       if the lanes are enabled and the remembered lane is 1,
//           the following one; otherwise the main one.
//
// That method is the hook. The two questions it asks are answered by a Swift
// class, and Swift code that asks them does not go through anything a hook
// can reach, so switching the lanes on from here would only switch them on
// for half the app. The remembered lane is still set to 1, which is all it
// takes for someone who has the lanes for real.
//
// InstaSane (github.com/n3d1117/InstaSane) found the lane number, and
// Sparkle the method.
#import "../../src/InstagramHeaders.h"
#import "Ohrt.h"

%group OhrtFollowing

%hook IGUserSession
- (id)selectedMainFeedViewModel {
    return OhrtCall(self, @"_followingMainFeedViewModel") ?: %orig;
}
%end

// Demangled name: IGDSAShared.IGDSAGatingManager
%hook _TtC11IGDSAShared18IGDSAGatingManager
- (NSInteger)feedStickyContentLaneSelection {
    return 1;
}
%end

%end

%ctor {
    // Nothing is hooked unless the feed is on when the app starts.
    if (OhrtFollowingFeedEnabled() && !OhrtSafeLaunch() && OhrtAvailable(@"following")) %init(OhrtFollowing);
}
