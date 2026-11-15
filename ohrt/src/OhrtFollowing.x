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
// That method is the first hook. The two questions it asks are answered by a
// Swift class, and Swift code that asks them does not go through anything a
// hook can reach, so switching the lanes on from here would only switch them
// on for half the app. The remembered lane is still set to 1, which is all
// it takes for someone who has the lanes for real.
//
// The second hook is one level down. What a feed asks the server for is its
// "pagination source": a name such as "following", "favorites" or
// "friend_lane" for the feeds that have one. The ranked feed is believed to
// have none: that is how its requests look from outside, but it was not
// read out of this binary, and the log line below is there to settle it on
// a phone. A feed's network source sets the name through one method, from
// its init on, so naming "following" there for a feed without one makes the
// ranked feed the following one even if the home tab was handed the main
// view model after all. Feeds that do have a name are left as they are.
//
// InstaSane (github.com/n3d1117/InstaSane) found the lane number and the
// second hook, Sparkle the first.
#import "../../src/InstagramHeaders.h"
#import "Ohrt.h"

%group OhrtFollowing

%hook IGUserSession
- (id)selectedMainFeedViewModel {
    id following = OhrtCall(self, @"_followingMainFeedViewModel");
    static BOOL said;
    if (!said) {
        said = YES;
        OhrtLog(@"following feed: %@", following ? @"home uses the following lane" : @"no following lane on this session, home is unchanged");
    }
    return following ?: %orig;
}
%end

%hook IGMainFeedNetworkSource
- (void)updatePaginationSource:(id)source nextMaxID:(id)nextMaxID {
    BOOL named = [source isKindOfClass:[NSString class]] && [(NSString *)source length] > 0;
    // Each kind of feed is logged once, so a look at the log on a phone
    // shows what this Instagram really calls them.
    static NSMutableSet<NSString *> *seen;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        seen = [NSMutableSet set];
    });
    NSString *name = named ? source : @"(none)";
    @synchronized(seen) {
        if (![seen containsObject:name]) {
            [seen addObject:name];
            OhrtLog(@"following feed: a feed with source %@%@", name, named ? @"" : @", now following");
        }
    }
    if (named) {
        %orig;
        return;
    }
    %orig(@"following", nextMaxID);
}
%end

// Demangled name: IGDSAShared.IGDSAGatingManager
%hook _TtC11IGDSAShared18IGDSAGatingManager
- (NSInteger)feedStickyContentLaneSelection {
    return 1;
}
%end

%end

// Nothing is hooked unless the feed is on when the app starts.
void OhrtInstallFollowing(void) {
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        if (!OhrtFollowingFeedEnabled() || OhrtSafeLaunch()) return;
        NSString *missing = OhrtMissing(@"following");
        if (missing) {
            OhrtLog(@"following feed is switched on but left off: this Instagram lacks %@", missing);
            return;
        }
        %init(OhrtFollowing);
    });
}
