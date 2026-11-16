#!/usr/bin/env python3
"""Checks what our features assume about how Instagram behaves.

  facts_test.py            (uses the version in ohrt/instagram-version)

hookaudit.py checks that the classes and methods we hook exist. This checks
the next thing down: that those methods still do what our code was written
around, read out of the machine code with ohrt/tools/calls.py. Each fact
names the feature that rests on it, so on a newer Instagram a failure here
says which feature to look at before trusting it.

Needs the IPA in packages/ and its index (classdump.py build).
"""
import os
import sqlite3
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, os.path.join(HERE, "..", "tools"))
import calls  # noqa: E402
from classdump import db_path, pinned_version  # noqa: E402

# (feature, method, what its code must mention)
FACTS = [
    ("following feed", "-[IGUserSession selectedMainFeedViewModel]",
     ["[... mainFeedViewModel]", "[... _followingMainFeedViewModel]", "[... feedStickyContentLaneSelection]"]),
    ("following feed", "-[IGMainFeedNetworkSource updatePaginationSource:nextMaxID:]",
     ["[... setPaginationSource:]", "[... setNextMaxID:]"]),
    ("following feed",
     "-[IGMainFeedNetworkSource initWithPosts:nextMaxID:initialPaginationSource:fetchPath:fetcher:responseParser:"
     "mainFeedNetworkSourceSessionDeps:sessionId:analyticsModule:timeSinceLastHeadLoadFetchKeySuffix:useNewUIGraph:]",
     ["[... updatePaginationSource:nextMaxID:]"]),
    ("following feed", "-[IGMainFeedViewModel updatePaginationSource:nextMaxID:]",
     ["[... updatePaginationSource:nextMaxID:]"]),
    ("DM mode", "-[IGTabBarController _tabBarHasDirectInbox]",
     ["ivar _tabBarSurfaces", "[... directInbox]", "[... containsObject:]"]),
    ("DM mode", "-[IGTabBarController _directInboxButtonPressed]",
     ["[... directInbox]", "[... _setSelectedTabBarSurface:isTabBarAction:animated:navigationAction:skipMainFeedFetch:]"]),
    ("DM mode", "-[IGTabBarController viewWillAppear:]",
     ["[... forceInitializeViewControllersIfNeeded]"]),
    ("hiding tabs (upstream)", "-[IGMainAppSurfaceIntent tabStringFromSurfaceIntent]",
     ['@"FEED"', '@"CLIPS"', '@"SEARCH"', '@"DIRECT"']),
    ("caught up wall", "-[IGMainFeedListAdapterDataSource objectsForListAdapter:]",
     ["[... viewModel]", "[... viewablePosts]", "class IGEndOfFeedDemarcatorModel"]),
    ("caught up wall", "-[IGMainFeedViewController _fetchNextPage]",
     ["[... fetchMoreItemsWithPrefetchType:]"]),
    ("caught up wall", "-[IGListAdapter objects]",
     ["[... sectionMap]", "[... objects]"]),
    ("caught up wall", "-[IGMainFeedViewModel paginationSource]",
     ["[... paginationSource]"]),
    ("wordmark", "-[IGHomeFeedHeaderView setTitle:animated:]",
     ["ivar _logoButton", "[... setImage:forState:]", "[... ig_templateImage]"]),
    ("wordmark", "-[IGHomeFeedHeaderView layoutSubviews]",
     ["ivar _logoButton", "[... _titleMidX]", "[... ig_setFrameUsingPosition:anchorPoint:]"]),
    ("profile facts", "-[IGProfileBioSectionController sizeForItemAtIndex:]",
     ["[... insetContainerSize]", "[... userFragment]", "ivar _model"]),
    ("profile facts", "-[IGProfileBioSectionController cellForItemAtIndex:]",
     ["class IGProfileBioCell", "ivar _bioCell"]),
    ("profile facts", "-[IGProfileBioCell layoutSubviews]",
     ["ivar _bioView"]),
    ("follow back", "-[IGTaggingViewController viewDidLoad]",
     ['@"/friendships/%@/followers/"', "[... initWithUserSession:fetchPath:endpointLoggingIdentifier:]"]),
    ("follow back", "-[IGUserListNetworkDataSource initWithUserSession:fetchPath:endpointLoggingIdentifier:]",
     ['@"users"', "[... initWithUserSession:requestConfig:]"]),
    ("follow back", "-[IGFollowListViewController _maybePaginateList]",
     ["[... fetchData]"]),
    ("follow back", "-[IGUserListNetworkDataSource allResults]",
     ["[... filteredResults]"]),
    ("unfollow", "-[IGFollowController _performUnfollow]",
     ["[... userActions]", "[... user]"]),
    ("unfollow", "-[IGFollowController _createFollowButtonIfNeeded]",
     ["class IGFollowButton", "[... initWithViewConfiguration:]"]),
    ("opening a profile", "-[IGAppDelegate application:openURL:options:]",
     ["[... application:openURL:options:]"]),
]


def main():
    path = db_path()
    if not os.path.exists(path):
        print(f"facts: skipped, no index for Instagram {pinned_version()} (classdump.py build <ipa>)")
        return 0
    db = sqlite3.connect(path)
    images = {}
    failures = 0
    for feature, method, wanted in FACTS:
        kind, rest = method[0], method[2:-1]
        cls, selector = rest.split(" ", 1)
        row = db.execute("""select m.code, m.image from methods m join classes c on c.name = m.class
                            where (c.name = ? or c.alias = ?) and m.kind = ? and m.sel = ? limit 1""",
                         (cls, cls, kind, selector)).fetchone()
        if not row:
            failures += 1
            print(f"FAIL {feature}: {method} is not in Instagram {pinned_version()}")
            continue
        start, image = row
        if image not in images:
            images[image] = calls.load(image)
        lines, _ = calls.trace(images[image], db, image, start)
        text = "\n".join(line for _, line in lines)
        missing = [item for item in wanted if item not in text]
        if missing:
            failures += 1
            print(f"FAIL {feature}: {method} no longer mentions {', '.join(missing)}")
    if failures:
        print(f"facts: {failures} of {len(FACTS)} no longer hold on Instagram {pinned_version()}")
        return 1
    print(f"facts: all {len(FACTS)} hold on Instagram {pinned_version()}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
