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
    ("profile facts", "-[IGProfileHeaderView listAdapter:sectionControllerForObject:]",
     ["ivar _dataSource", "[... sectionControllerForProfileHeaderObject:listAdapter:]"]),
    ("keeping count", "-[IGMedia performLike:userInfo:navState:analyticsModule:requestSourceParams:userSession:sponsoredSupportConfiguration:completion:]",
     ["[... isLike]", '@"_unlike"']),
    ("keeping count", "-[IGStoryViewerViewController fullscreenSectionController:didMarkItemAsSeen:]",
     ["[... mediaID]", "[... addSeenDateForStoryItem:reelPK:]"]),
    ("keeping count", "-[IGStoryLikesInteractionControllingImpl _sendStoryLikeWithLikeButton:]",
     ["[... _isLikeableStory]", "[... isSelected]", "[... setSelected:]", "[... storyItem]", "class IGPendingStoryLike"]),
    ("keeping count", "-[IGRankingPrefetchPredictService initWithUserSession:]",
     ["[... friendStatusChangedAnnouncer]", "[... addListener:]"]),
    ("keeping count", "-[IGRankingPrefetchPredictService friendStatusChangedForUser:withUserAction:]",
     ["class IGRankingNewFollowingEvent"]),
    ("keeping count", "-[IGSignalsUserActionsTracker commentPosted:media:]", []),
    ("message counts", "-[IGDirectRealtimeIrisDeltaApplicator _logAddItemMutationForThreadId:inCachedThread:message:sequenceId:]",
     ["[... publishedMessageSet]", "[... metadata]", "[... serverId]", "[... senderPk]"]),
    ("message counts", "-[IGDirectPublishedThread initWithCoder:]",
     ["@selector(metadata)", "@selector(publishedMessageSet)"]),
    ("message counts", "-[IGDirectPublishedThread displayName]",
     ["[... users]"]),
    ("hidden like counts", "-[IGFollowListViewController dataSourceDidFinishLoading:]",
     ["[... _updateTitle]", "ivar _networkDataSource"]),
    ("facts on a post", "-[IGFeedSectionControllerOld numberOfItems]",
     ["ivar _itemViewModel", "[... rowItems]", "[... count]"]),
    ("facts on a post", "-[IGFeedSectionControllerOld rowForCellAtIndex:]",
     ["ivar _itemViewModel", "[... rowItems]", "[... objectAtIndex:]"]),
    ("facts on a post", "-[IGFeedSectionControllerOld cellForItemAtIndex:]",
     ["[... rowForCellAtIndex:]", "[... type]"]),
    ("facts on a post", "-[IGFeedSectionControllerOld analyticsItemTypeAtIndex:]",
     ["[... rowItems]", "[... objectAtIndexedSubscript:]"]),
    ("facts on a post", "-[IGFeedItemTimelineViewModelImpl indexForCellType:textType:]",
     ["[... indexOfObjectPassingTest:]"]),
    ("facts on a post", "-[IGFeedItemTimelineViewModelImpl indexForFeedItemRow:]",
     ["[... indexOfObject:]"]),
    ("facts on a post", "-[IGFeedItemTimelineViewModelImpl textRowIndexes]",
     ["[... objectAtIndex:]", "[... type]"]),
    ("facts on a post", "-[IGFeedItemTextCell layoutSubviews]",
     ["ivar _leftPadding"]),
    ("profile facts", "-[IGBaseUser followerCount]", ['@"follower_count"']),
    ("close friends", "-[IGBaseMedia audience]", ['@"audience"']),
    ("hidden like counts", "-[IGBaseMedia likeAndViewCountsDisabled]", ['@"like_and_view_counts_disabled"']),
    ("why a post is in the feed", "-[IGBaseMedia inventorySource]", ['@"inventory_source"', "[... stringForPandoKey:cppKey:]"]),
    ("why a post is in the feed", "-[IGBaseMedia mainFeedRequestReason]", ['@"main_feed_request_reason"', "[... stringForPandoKey:cppKey:]"]),
    ("why a post is in the feed", "-[IGBaseMedia rankingWeight]", ['@"ranking_weight"', "[... floatForPandoKey:cppKey:]"]),
    ("why a post is in the feed", "-[IGBaseMedia rankedAt]", ['@"ranked_at"', "[... longForPandoKey:cppKey:]"]),
    ("why a post is in the feed", "-[IGBaseMedia feedRankingSourceDebugLabel]",
     ['@"feed_ranking_source_debug_label"', "[... stringForPandoKey:cppKey:]"]),
    ("scores and flags", "-[IGBaseUser closenessScore]", ['@"closeness_score"', "[... floatForPandoKey:cppKey:]"]),
    ("scores and flags", "-[IGBaseUser coeffWeight]", ['@"coeff_weight"', "[... floatForPandoKey:cppKey:]"]),
    ("scores and flags", "-[IGUser bffScore]", ["[... closenessScore]"]),
    ("scores and flags", "-[IGBaseUser isPossibleScammer]", ['@"is_possible_scammer"', "[... booleanForPandoKey:cppKey:]"]),
    ("scores and flags", "-[IGBaseUser isPossibleBadActor]",
     ['@"is_possible_bad_actor"', '"IGAPIProactiveWarningsEventInfo"', "[... valueForPandoKey:cppKey:typeName:]"]),
    ("scores and flags", "-[IGBaseUser accountWarning]",
     ['@"account_warning"', '"IGAPIProactiveWarningHarmInfo"', "[... valueForPandoKey:cppKey:typeName:]"]),
    ("scores and flags", "-[IGBaseUser profilePicGenaiToolInfo]",
     ['@"profile_pic_genai_tool_info"', '"IGAPIGenAIToolInfoDict"', "[... valueListForPandoKey:cppKey:typeName:]"]),
    ("scores and flags", "-[IGBaseUser reelMediaSeenTimestamp]", ['@"reel_media_seen_timestamp"', "[... longForPandoKey:cppKey:]"]),
    ("scores and flags", "-[IGBaseUser ukTeenOsaConnectionInfo]",
     ['@"uk_teen_osa_connection_info"', '"IGAPIUKTeenOSAConnectionInfo"']),
    ("scores and flags", "-[IGBaseUser homeCountry]", ['@"home_country"', "[... stringForPandoKey:cppKey:]"]),
    ("no gap for suggested accounts", "-[IGProfileHeaderView objectsForListAdapter:]",
     ["ivar _dataSource", "[... objectsForProfileHeader]"]),
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
