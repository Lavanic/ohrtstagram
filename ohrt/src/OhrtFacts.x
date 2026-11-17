// Facts on a profile: a few small lines above the Follow and Message
// buttons, of what the app holds about the account and does not show.
//
//   id 1234567890, creator, follows since 03.05.19, followed since 03.02.19,
//   you: 214 likes (10.30.26), 12 comments, 88 stories watched since 11.15.26,
//   340 dms since 01.10.20, story 3h ago
//
// There are two sources, and nothing is asked of Instagram for either. The
// first is what the app already holds when a profile opens: the id, the
// kind of account, whether it follows you, its latest story, where it sits
// in the rankings Instagram keeps on the phone, and any flag Instagram sent
// on it. The
// second is your own history with the account, which Instagram's app does
// not hold: when each follow began, and how much you have liked, commented,
// watched and written. Every count is of what you did, never of what they did. It
// comes from your Instagram export (OhrtExport.m) up to the day that was
// made, and from our own notes of what you have done in this app since
// (OhrtActivity.x). Stories watched come from our notes alone: the export
// lists only some of the last month's, so a count from it would be far too
// low. A count that does not go back to the start says since when.
//
// A profile's header is a list of parts, each with a controller of its own
// that says how tall it is and makes its cell. The facts are one more part,
// put in just before the buttons, with a controller of ours. Instagram's
// own parts are not touched.
#import <objc/message.h>
#import <objc/runtime.h>

#import "Ohrt.h"
#import "OhrtLogic.h"

NSString *const kOhrtFactsKey = @"ohrt_facts";

// The red of the calico jack, #ff0349, lightened to read on a dark page.
// On a light page it is the red itself.
static const uint32_t kOhrtFactsOnDark = 0xff8aa6;
static const uint32_t kOhrtFactsOnLight = 0xff0349;
static const CGFloat kOhrtFactsAbove = 2;
static const CGFloat kOhrtFactsBelow = 8;
// How far in from the screen's edges, when the bio's own distance cannot be
// had.
static const CGFloat kOhrtFactsSide = 16;
static const NSTimeInterval kOhrtStoryLife = 24 * 60 * 60;

static char kOhrtModelKey;

@interface IGProfileHeaderView : UIView
@end

static UIFont *OhrtFactsFont(void) {
    return [UIFont systemFontOfSize:11];
}

static UIColor *OhrtFactsColor(void) {
    return [UIColor colorWithDynamicProvider:^UIColor *(UITraitCollection *traits) {
        return OhrtColor(traits.userInterfaceStyle == UIUserInterfaceStyleDark ? kOhrtFactsOnDark : kOhrtFactsOnLight);
    }];
}

UIFont *OhrtFactsLineFont(void) {
    return OhrtFactsFont();
}

UIColor *OhrtFactsLineColor(void) {
    return OhrtFactsColor();
}

static CGFloat OhrtFactsTextHeight(NSString *text, CGFloat width) {
    if (!text.length || !(width >= 40)) return 0;
    CGRect box = [text boundingRectWithSize:CGSizeMake(width, CGFLOAT_MAX)
                                    options:NSStringDrawingUsesLineFragmentOrigin | NSStringDrawingUsesFontLeading
                                 attributes:@{NSFontAttributeName : OhrtFactsFont()}
                                    context:nil];
    return ceil(box.size.height);
}

static id OhrtIvar(id object, const char *name) {
    Ivar ivar = object ? class_getInstanceVariable([object class], name) : NULL;
    return ivar ? object_getIvar(object, ivar) : nil;
}

static NSString *OhrtText(id value) {
    if ([value isKindOfClass:[NSString class]]) return value;
    if ([value isKindOfClass:[NSNumber class]]) return [value stringValue];
    return nil;
}

// A date, however it was kept: as a date, or as seconds since 1970.
static NSDate *OhrtDate(id value) {
    if ([value isKindOfClass:[NSDate class]]) return value;
    double seconds = [value isKindOfClass:[NSNumber class]] || [value isKindOfClass:[NSString class]] ? [value doubleValue] : 0;
    return seconds > 0 ? [NSDate dateWithTimeIntervalSince1970:seconds] : nil;
}

static NSString *OhrtDay(NSDate *date) {
    static NSDateFormatter *formatter;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        formatter = [NSDateFormatter new];
        formatter.locale = [NSLocale localeWithLocaleIdentifier:@"en_US_POSIX"];
        formatter.dateFormat = @"MM.dd.yy";
    });
    return [formatter stringFromDate:date];
}

static NSString *OhrtStamp(id seconds) {
    return OhrtDay([NSDate dateWithTimeIntervalSince1970:[seconds doubleValue]]);
}

static NSString *OhrtMyAccount(void) {
    return OhrtText(OhrtCall(OhrtCall(OhrtCurrentSession(), @"user"), @"pk"));
}

// How often you did one kind of thing to an account, and when last: what
// the export says, and what has been noted here since the export was made.
static NSInteger OhrtCountOf(NSString *kind, NSDictionary *past, NSString *pk, NSTimeInterval *last) {
    NSInteger count = 0;
    *last = 0;
    id tally = past[kind];
    if ([tally isKindOfClass:[NSArray class]] && [tally count] >= 3) {
        count = [tally[0] integerValue];
        *last = [tally[2] doubleValue];
    }
    NSArray<NSNumber *> *noted = OhrtActivityTimes(pk, kind);
    if (noted.count) {
        size_t length = noted.count;
        double *times = malloc(length * sizeof(double));
        if (times) {
            for (size_t index = 0; index < length; index++) times[index] = noted[index].doubleValue;
            double latest = 0;
            count += (NSInteger)OhrtCountAfter(times, length, OhrtExportDate(), &latest);
            if (latest > *last) *last = latest;
            free(times);
        }
    }
    return count;
}

// "214 likes (10.30.26)", the day being the last one. The first of these
// on a line is given its "you:" by the caller.
static void OhrtAddDone(NSMutableArray<NSString *> *done, NSString *kind, NSDictionary *past, NSString *pk, NSString *one, NSString *many, BOOL withLast) {
    NSTimeInterval last = 0;
    NSInteger count = OhrtCountOf(kind, past, pk, &last);
    if (count < 1) return;
    NSString *text = [NSString stringWithFormat:@"%ld %@", (long)count, count == 1 ? one : many];
    if (withLast && last > 0) text = [text stringByAppendingFormat:@" (%@)", OhrtStamp(@(last))];
    [done addObject:text];
}

// Your history with an account that is not your own: what the app says
// stands now, with the days and counts the export and our own notes give.
static void OhrtAddHistory(NSMutableArray<NSString *> *facts, id user, NSString *pk) {
    NSDictionary *past = OhrtExportPerson(OhrtText(OhrtCall(user, @"username")));
    BOOL followsYou = OhrtCallBool(user, @"followsCurrentUser");
    BOOL followed = OhrtCallBool(user, @"followedByCurrentUser");

    if (followsYou) [facts addObject:past[@"follows_you"] ? [@"follows since " stringByAppendingString:OhrtStamp(past[@"follows_you"])] : @"follows you"];
    else if (past[@"follows_you"]) [facts addObject:[NSString stringWithFormat:@"followed you from %@ but not now", OhrtStamp(past[@"follows_you"])]];

    // A follow noted here is the newer one: it happened after the export.
    NSNumber *since = OhrtActivityFollowed(pk) ?: past[@"followed"];
    if (followed) {
        if (since) [facts addObject:[@"followed since " stringByAppendingString:OhrtStamp(since)]];
    } else if (past[@"unfollowed"]) {
        [facts addObject:[@"unfollowed " stringByAppendingString:OhrtStamp(past[@"unfollowed"])]];
    } else if (past[@"requested"]) {
        [facts addObject:[@"requested " stringByAppendingString:OhrtStamp(past[@"requested"])]];
    }

    if (past[@"close_friend"]) [facts addObject:[@"close friend since " stringByAppendingString:OhrtStamp(past[@"close_friend"])]];
    // A story for their close friends was shown to you, so you are on the
    // list.
    NSNumber *close = OhrtActivityCloseFriends(pk);
    if (close) [facts addObject:[@"you're on their close friends, seen " stringByAppendingString:OhrtStamp(close)]];
    if (past[@"blocked"]) [facts addObject:[@"blocked " stringByAppendingString:OhrtStamp(past[@"blocked"])]];
    if (past[@"restricted"]) [facts addObject:@"restricted"];
    if (past[@"story_hidden"]) [facts addObject:@"your story is hidden from them"];

    // With an export these go back to the start. Without one they are only
    // what has been noted here, and the line says since when.
    BOOL whole = OhrtExportDate() > 0;
    NSString *began = OhrtActivityBegan() > 0 ? OhrtStamp(@(OhrtActivityBegan())) : nil;
    NSMutableArray<NSString *> *done = [NSMutableArray array];
    OhrtAddDone(done, @"likes", past, pk, @"like", @"likes", YES);
    OhrtAddDone(done, @"comments", past, pk, @"comment", @"comments", NO);
    OhrtAddDone(done, @"story_likes", past, pk, @"story like", @"story likes", NO);
    OhrtAddDone(done, @"saved", past, pk, @"save", @"saves", NO);
    NSUInteger watched = OhrtActivityTimes(pk, @"stories_seen").count;
    if (watched) {
        NSString *text = [NSString stringWithFormat:@"%lu %@ watched", (unsigned long)watched, watched == 1 ? @"story" : @"stories"];
        [done addObject:whole && began ? [text stringByAppendingFormat:@" since %@", began] : text];
    }
    if (done.count) {
        done[0] = whole || !began ? [@"you: " stringByAppendingString:done[0]] : [NSString stringWithFormat:@"you since %@: %@", began, done[0]];
        [facts addObjectsFromArray:done];
        // An export made before this app first ran leaves days in neither.
        if (whole && OhrtActivityBegan() > OhrtExportDate() + 86400) {
            [facts addObject:[NSString stringWithFormat:@"not counted %@ to %@", OhrtStamp(@(OhrtExportDate())), began]];
        }
    }

    // The export has the conversation from its first message. One it does
    // not have, or cannot tell from another by its name, is counted from
    // where our own count starts.
    NSTimeInterval counted = 0;
    NSInteger noted = OhrtActivityMessages(pk, &counted);
    // The name alone could be someone else's. The export's conversation is
    // used only for an account the export knows or one messaged since.
    NSDictionary *thread = past || noted > 0 ? OhrtExportThread(OhrtText(OhrtCall(user, @"fullName"))) : nil;
    NSInteger messages = [thread[@"messages"] integerValue] + noted;
    if (messages > 0) {
        [facts addObject:[NSString stringWithFormat:@"%ld %@ since %@", (long)messages, messages == 1 ? @"dm" : @"dms", OhrtStamp(thread[@"first"] ?: @(counted))]];
    }
}

// "1st", "2nd", "12th".
static NSString *OhrtOrdinal(NSUInteger number) {
    NSUInteger tens = number % 100, ones = number % 10;
    NSString *suffix = (tens >= 11 && tens <= 13) ? @"th" : ones == 1 ? @"st" : ones == 2 ? @"nd" : ones == 3 ? @"rd" : @"th";
    return [NSString stringWithFormat:@"%lu%@", (unsigned long)number, suffix];
}

// The account's key in Instagram's own lists: its id, as text or a number.
static id OhrtScoreIn(NSDictionary *scores, NSString *pk) {
    if (![scores isKindOfClass:[NSDictionary class]] || !pk.length) return nil;
    return scores[pk] ?: scores[@(pk.longLongValue)];
}

// A list of scores as Instagram keeps one: how many there are and what they
// run from and to.
typedef struct {
    NSUInteger total;
    double low, high;
} OhrtScoreRange;

static OhrtScoreRange OhrtRangeOf(NSDictionary *scores) {
    OhrtScoreRange range = {0, 0, 0};
    for (id value in scores.allValues) {
        if (![value isKindOfClass:[NSNumber class]]) continue;
        double score = [value doubleValue];
        if (!range.total || score < range.low) range.low = score;
        if (!range.total || score > range.high) range.high = score;
        range.total++;
    }
    return range;
}

// "3rd of 41 (91/100)": the place of `score` in its list from the highest,
// and the score, out of a hundred when the whole list lies between 0 and 1
// and as it is otherwise.
static NSString *OhrtRankText(double score, NSDictionary *scores, BOOL scoreFirst) {
    OhrtScoreRange range = OhrtRangeOf(scores);
    // A score of exactly 0 means listed, not scored. A place is counted
    // among the accounts that were scored.
    NSUInteger above = 0, scored = 0;
    for (id value in scores.allValues) {
        if (![value isKindOfClass:[NSNumber class]]) continue;
        if ([value doubleValue] > score) above++;
        if ([value doubleValue] > 0) scored++;
    }
    NSString *shown = range.total && range.low >= 0 && range.high <= 1 ? [NSString stringWithFormat:@"%.0f/100", score * 100] : [NSString stringWithFormat:@"%.2f", score];
    if (!scored) return shown;
    NSString *place = [NSString stringWithFormat:@"%@ of %@", OhrtOrdinal(above + 1), OhrtGrouped((long long)scored)];
    return scoreFirst ? [NSString stringWithFormat:@"%@ (%@)", shown, place] : [NSString stringWithFormat:@"%@ (%@)", place, shown];
}

static NSString *OhrtRangeText(NSString *name, NSDictionary *scores) {
    OhrtScoreRange range = OhrtRangeOf(scores);
    return range.total ? [NSString stringWithFormat:@"%@ (%lu, %.4g to %.4g)", name, (unsigned long)range.total, range.low, range.high] : [NSString stringWithFormat:@"%@ (0)", name];
}

static NSDictionary *OhrtDictionaryCopy(id value) {
    return [value isKindOfClass:[NSDictionary class]] ? [value copy] : nil;
}

// Instagram's live rankings of who you are likeliest to message or share
// with: what its "new message" list, its search for someone to message and
// its share sheets are sorted by. Each is a list of scores worked out on
// Meta's servers, refreshed by the app and kept on the phone; a few people
// the app has just talked to or seen active are boosted on the phone. The
// share sheet's lists come first: they rank the most people, with a wide
// spread. The "new message" list is left out: its scores sit too close
// together for its order to say much. The first list that has the account
// is shown, under what it is for.
static const struct {
    long long view;
    __unsafe_unretained NSString *label;
} kOhrtLiveViews[] = {
    {1, @"share_rank"},
    {2, @"share_rank"},
    {6, @"share_rank"},
    {4, @"dm_search_rank"},
};

static BOOL OhrtAddLiveRanking(NSMutableArray<NSString *> *facts, NSMutableArray<NSString *> *fields, NSString *pk) {
    // The service swaps in a new set of rankings when it refreshes them, on
    // a thread of its own, so each part is copied before it is gone through.
    id data = OhrtIvar(OhrtCall(OhrtCurrentSession(), @"rankingService"), "_rankings");
    NSDictionary *views = OhrtDictionaryCopy(OhrtCallValue(data, @"rankingTypesToScores"));
    NSDictionary *entities = OhrtDictionaryCopy(OhrtCallValue(data, @"entityIdsToEntities"));
    if (!views || !entities) return NO;
    static BOOL described;
    if (!described) {
        described = YES;
        NSMutableArray<NSString *> *seen = [NSMutableArray array];
        for (id view in views) [seen addObject:OhrtRangeText([NSString stringWithFormat:@"view %@", view], OhrtDictionaryCopy(OhrtCallValue(views[view], @"entityIdsToScores")))];
        OhrtLog(@"facts: Instagram's live rankings on the phone are %@, for %lu people and threads", seen.count ? [seen componentsJoinedByString:@", "] : @"none", (unsigned long)entities.count);
    }
    // The account's entries: itself as a person, and a conversation with
    // only it in. A group is never the account's, whoever is left in it.
    NSMutableArray *keys = [NSMutableArray array];
    for (id entityId in entities) {
        id entity = entities[entityId];
        NSString *found = OhrtText(OhrtCallValue(OhrtIvar(entity, "_user"), @"pk"));
        if (!found) {
            id recipient = OhrtIvar(entity, "_recipient");
            NSArray *users = OhrtCallValue(recipient, @"users");
            if ([users isKindOfClass:[NSArray class]] && users.count == 1 && ![OhrtCallValue(recipient, @"isGroupThread") boolValue]) found = OhrtText(OhrtCallValue(users.firstObject, @"pk"));
        }
        if ([found isEqualToString:pk]) {
            [keys addObject:entityId];
            OhrtProbeRecipient(entity);
        }
    }
    if (!keys.count) return NO;
    for (size_t index = 0; index < sizeof(kOhrtLiveViews) / sizeof(kOhrtLiveViews[0]); index++) {
        NSDictionary *scores = OhrtDictionaryCopy(OhrtCallValue(views[@(kOhrtLiveViews[index].view)], @"entityIdsToScores"));
        NSNumber *best = nil;
        for (id key in keys) {
            id score = scores[key];
            if ([score isKindOfClass:[NSNumber class]] && (!best || [score doubleValue] > best.doubleValue)) best = score;
        }
        if (!best) continue;
        [fields addObject:[NSString stringWithFormat:@"live_view_%lld", kOhrtLiveViews[index].view]];
        // Only the place: these scores have no fixed scale (up to 1,900
        // were seen), so the number itself says nothing.
        NSUInteger above = 0, total = 0;
        for (id value in scores.allValues) {
            if (![value isKindOfClass:[NSNumber class]]) continue;
            total++;
            if ([value doubleValue] > best.doubleValue) above++;
        }
        [facts addObject:[NSString stringWithFormat:@"%@ %@ of %@", kOhrtLiveViews[index].label, OhrtOrdinal(above + 1), OhrtGrouped((long long)total)]];
        return YES;
    }
    return NO;
}

// How the stored search list and the stored close friends list compare,
// worked out again when either is fetched anew.
static BOOL OhrtStoredListsAgree(NSDictionary *search, NSDictionary *besties) {
    static __weak NSDictionary *lastSearch, *lastBesties;
    static BOOL agree, said;
    if (search == lastSearch && besties == lastBesties) return agree;
    lastSearch = search;
    lastBesties = besties;
    NSUInteger both = 0, equal = 0;
    double widest = 0;
    for (id key in search) {
        id one = search[key], other = besties[key];
        if (![one isKindOfClass:[NSNumber class]] || ![other isKindOfClass:[NSNumber class]]) continue;
        both++;
        double apart = fabs([one doubleValue] - [other doubleValue]);
        if (apart <= 1e-9) equal++;
        if (apart > widest) widest = apart;
    }
    agree = both > 0 && equal * 100 >= both * 95;
    if (!said) {
        said = YES;
        OhrtLog(@"facts: %lu accounts are in both the stored search and close friends lists, %lu with equal scores, %lu that differ, the widest by %.4g", (unsigned long)both, (unsigned long)equal,
                (unsigned long)(both - equal), widest);
    }
    return agree;
}

// Instagram also keeps on the phone slower lists of scores per account,
// fetched now and then: one for suggesting your close friends list, one for
// searching people to message. The close friends one is always shown. The
// search one is handed back to go further along the line, and only when no
// live ranking has the account and the two lists do not say the same thing.
static NSString *OhrtAddRankings(NSMutableArray<NSString *> *facts, NSMutableArray<NSString *> *fields, NSString *pk, BOOL haveLive) {
    id service = OhrtCall(OhrtCurrentSession(), @"userBootstrapService");
    id surfaces = OhrtCallValue(OhrtIvar(service, "_bootstrap"), @"surfaces");
    if ([surfaces isKindOfClass:[NSSet class]]) surfaces = [surfaces allObjects];
    if (![surfaces isKindOfClass:[NSArray class]]) return nil;
    NSMutableDictionary<NSString *, NSDictionary *> *byName = [NSMutableDictionary dictionary];
    for (id surface in (NSArray *)surfaces) {
        NSString *name = OhrtText(OhrtCallValue(surface, @"name"));
        NSDictionary *scores = OhrtDictionaryCopy(OhrtIvar(surface, "_scores"));
        if (name && scores) byName[name] = scores;
    }
    static BOOL described;
    if (!described) {
        described = YES;
        NSMutableArray<NSString *> *seen = [NSMutableArray array];
        for (NSString *name in byName) [seen addObject:OhrtRangeText(name, byName[name])];
        OhrtLog(@"facts: Instagram's stored rankings on the phone are %@", seen.count ? [seen componentsJoinedByString:@", "] : @"none");
    }
    NSDictionary *search = byName[@"coefficient_rank_recipient_user_suggestion"];
    NSDictionary *besties = byName[@"coefficient_besties_list_ranking"];
    BOOL agree = search && besties && OhrtStoredListsAgree(search, besties);
    id bestiesScore = OhrtScoreIn(besties, pk);
    if ([bestiesScore isKindOfClass:[NSNumber class]] && [bestiesScore doubleValue] > 0) {
        [fields addObject:@"coefficient_besties_list_ranking"];
        [facts addObject:[@"bestie_coefficient " stringByAppendingString:OhrtRankText([bestiesScore doubleValue], besties, YES)]];
    }
    id searchScore = OhrtScoreIn(search, pk);
    if (haveLive || agree || ![searchScore isKindOfClass:[NSNumber class]] || [searchScore doubleValue] <= 0) return nil;
    [fields addObject:@"coefficient_rank_recipient_user_suggestion"];
    return [@"dm_search_coefficient " stringByAppendingString:OhrtRankText([searchScore doubleValue], search, YES)];
}

// The account's story in your tray now, if it has one: how likely Instagram
// thinks you are to tap it, which is one of the scores it ranks the tray
// with, and whether it is for close friends, which means you are on their
// list.
static void OhrtAddTray(NSMutableArray<NSString *> *facts, NSMutableArray<NSString *> *fields, NSString *pk) {
    id map = OhrtCall(OhrtCurrentSession(), @"storyMap");
    SEL stored = NSSelectorFromString(@"storedStoryReelWithPK:");
    if (![map respondsToSelector:stored]) return;
    id reel = ((id (*)(id, SEL, id))objc_msgSend)(map, stored, pk);
    if (!reel) return;
    [fields addObject:@"tray_reel"];
    id ranker = OhrtCallValue(reel, @"rankerScores");
    id tap = OhrtCallValue(ranker, @"ptap");
    // The first stories seen all came with the same 0.2115, a default
    // rather than anything about the person, so a tap chance is shown only
    // once stories have come with different ones.
    static NSMutableSet<NSNumber *> *taps;
    if (!taps) taps = [NSMutableSet set];
    if ([tap isKindOfClass:[NSNumber class]] && taps.count < 64) [taps addObject:@(llround([tap doubleValue] * 10000))];
    if ([tap isKindOfClass:[NSNumber class]] && [tap doubleValue] >= 0 && [tap doubleValue] <= 1 && taps.count > 1) {
        [fields addObject:@"ptap"];
        [facts addObject:[NSString stringWithFormat:@"story_tap_chance %.0f%%", [tap doubleValue] * 100]];
    }
    if ([OhrtCallValue(reel, @"hasBestiesMedia") boolValue] && !OhrtActivityCloseFriends(pk)) [facts addObject:@"you're on their close friends (green ring now)"];
    // What "vm" measures is not known, so it is logged for the first few
    // and not shown.
    static NSUInteger told;
    if (!ranker || told >= 6) return;
    told++;
    id vm = OhrtCallValue(ranker, @"vm");
    OhrtLog(@"facts: a story in the tray came with ptap %@, vm %@", [tap isKindOfClass:[NSNumber class]] ? [NSString stringWithFormat:@"%.4g", [tap doubleValue]] : @"none",
            [vm isKindOfClass:[NSNumber class]] ? [NSString stringWithFormat:@"%.4g", [vm doubleValue]] : @"none");
}

// A value Instagram's servers name things by, as words on one line.
static NSString *OhrtFactsWords(id value) {
    if ([value isKindOfClass:[NSNumber class]]) return [value stringValue];
    if (![value isKindOfClass:[NSString class]]) return nil;
    NSString *text = [[[value lowercaseString] componentsSeparatedByCharactersInSet:[NSCharacterSet characterSetWithCharactersInString:@"_,\n\r"]] componentsJoinedByString:@" "];
    text = [text stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceCharacterSet]];
    if (text.length > 40) text = [text substringToIndex:40];
    return text.length ? text : nil;
}

// Which of these came with the first few profiles, by field name only.
static void OhrtFactsSayFields(NSString *pk, NSArray<NSString *> *fields) {
    static NSMutableSet<NSString *> *told;
    if (!told) told = [NSMutableSet set];
    if (told.count >= 8 || [told containsObject:pk]) return;
    [told addObject:pk];
    OhrtLog(@"facts: a profile came with %@", fields.count ? [fields componentsJoinedByString:@" "] : @"none of the ranking and flag fields");
}

// What Instagram itself holds about an account that is not your own and
// does not show: where it ranks the account among the people you are
// likeliest to message, from the rankings it keeps on the phone, and what
// it has flagged on the account when it says so.
static void OhrtAddScores(NSMutableArray<NSString *> *facts, id user, NSString *pk) {
    NSMutableArray<NSString *> *fields = [NSMutableArray array];
    // Instagram's own lists are read on their own account: should one of
    // them change under the reading, the rest of the line still comes.
    OhrtTry(@"rankings", ^{
        BOOL live = OhrtAddLiveRanking(facts, fields, pk);
        NSString *search = OhrtAddRankings(facts, fields, pk, live);
        OhrtAddTray(facts, fields, pk);
        if (search) [facts addObject:search];
    });

    id warning = OhrtCallValue(user, @"accountWarning");
    if (warning) {
        [fields addObject:@"account_warning"];
        NSString *kind = OhrtFactsWords(OhrtCallValue(warning, @"harmType"));
        [facts addObject:kind ? [@"account warning " stringByAppendingString:kind] : @"account warning"];
    }

    id tools = OhrtCallValue(user, @"profilePicGenaiToolInfo");
    if ([tools isKindOfClass:[NSArray class]] && [tools count]) {
        [fields addObject:@"profile_pic_genai_tool_info"];
        // The tool's name only: the entry also holds what was typed to make
        // the picture.
        id tool = [tools firstObject];
        NSString *name = OhrtFactsWords(OhrtCallValue(tool, @"displayName")) ?: OhrtFactsWords(OhrtCallValue(tool, @"toolType"));
        [facts addObject:name ? [NSString stringWithFormat:@"ai-made picture (%@)", name] : @"ai-made picture"];
    }
    OhrtFactsSayFields(pk, fields);
}

static NSString *OhrtFactsText(id user) {
    OhrtProbeSession();
    NSString *pk = OhrtText(OhrtCall(user, @"pk"));
    if (!pk.length) return nil;
    OhrtProbeUser(user, [pk isEqualToString:OhrtMyAccount()]);
    NSMutableArray<NSString *> *facts = [NSMutableArray arrayWithObject:[@"id " stringByAppendingString:pk]];

    NSString *type = OhrtCallBool(user, @"isBusinessAccountType") ? @"business"
        : OhrtCallBool(user, @"isMediaCreatorAccountType") ? @"creator"
        : OhrtCallBool(user, @"isPersonalAccountType") ? @"personal" : nil;
    if (type) {
        NSString *category = OhrtText(OhrtCall(user, @"category"));
        NSString *city = OhrtText(OhrtCall(user, @"computedCityName"));
        if (category.length && ![type isEqualToString:@"personal"]) type = [NSString stringWithFormat:@"%@ (%@)", type, category];
        if (city.length) type = [NSString stringWithFormat:@"%@ in %@", type, city];
        [facts addObject:type];
    }

    // Instagram sends the day an account was made with some profiles and
    // not with others. It is shown when it came.
    NSDate *joined = OhrtDate(OhrtCall(user, @"dateJoined"));
    if (joined) [facts addObject:[@"joined " stringByAppendingString:OhrtDay(joined)]];
    if ([OhrtCallValue(user, @"isNewToInstagram") boolValue]) [facts addObject:@"new to instagram"];

    // Instagram rounds a count from ten thousand up ("12.3K"). The whole
    // number came with the profile.
    NSMutableArray<NSString *> *exact = [NSMutableArray array];
    for (NSArray<NSString *> *count in @[ @[ @"followerCount", @"followers" ], @[ @"followingCount", @"following" ], @[ @"mediaCount", @"posts" ] ]) {
        id value = OhrtCallValue(user, count[0]);
        if ([value isKindOfClass:[NSNumber class]] && [value longLongValue] >= 10000) [exact addObject:[NSString stringWithFormat:@"%@ %@", OhrtGrouped([value longLongValue]), count[1]]];
    }
    if (exact.count) [facts addObject:[@"exactly " stringByAppendingString:[exact componentsJoinedByString:@", "]]];

    [facts addObjectsFromArray:OhrtLookedChanges(user, pk)];

    NSString *account = OhrtMyAccount();
    BOOL other = account.length && ![account isEqualToString:pk];
    if (other) {
        OhrtAddHistory(facts, user, pk);
        OhrtAddScores(facts, user, pk);
    }

    NSDate *story = OhrtDate(OhrtCall(user, @"latestReelMediaDate"));
    NSTimeInterval age = story ? -story.timeIntervalSinceNow : -1;
    if (age >= 0 && age < kOhrtStoryLife) {
        char ago[24];
        OhrtAgoText(age, ago, sizeof(ago));
        [facts addObject:[@"story " stringByAppendingString:@(ago)]];
    }
    return [facts componentsJoinedByString:@", "];
}

// The part of the header that is ours, as the header's list holds it. The
// list tells its parts apart by these two methods.
@interface OhrtFactsModel : NSObject
@property (nonatomic, copy) NSString *text;
@end

@implementation OhrtFactsModel

- (id)diffIdentifier {
    return @"ohrt.facts";
}

- (BOOL)isEqualToDiffableObject:(id)object {
    return [object isKindOfClass:[OhrtFactsModel class]] && [self.text isEqualToString:((OhrtFactsModel *)object).text];
}

@end

@interface OhrtFactsCell : UICollectionViewCell
@property (nonatomic, strong) UILabel *label;
@property (nonatomic) CGFloat side;
@end

@implementation OhrtFactsCell

- (instancetype)initWithFrame:(CGRect)frame {
    if ((self = [super initWithFrame:frame])) {
        _side = kOhrtFactsSide;
        _label = [UILabel new];
        _label.font = OhrtFactsFont();
        _label.textColor = OhrtFactsColor();
        _label.numberOfLines = 0;
        _label.lineBreakMode = NSLineBreakByWordWrapping;
        [self.contentView addSubview:_label];
    }
    return self;
}

- (void)layoutSubviews {
    [super layoutSubviews];
    CGRect bounds = self.contentView.bounds;
    self.label.frame = CGRectMake(self.side, kOhrtFactsAbove, MAX(0, bounds.size.width - 2 * self.side), MAX(0, bounds.size.height - kOhrtFactsAbove - kOhrtFactsBelow));
}

@end

// The controller for our part. Instagram's list controllers are a class in
// its own framework, so ours is made from that class as the app runs, and
// given the four things a controller is asked: how many cells, how big,
// which cell, and what it now shows.

// The distance the bio keeps from the screen's edges, which ours matches.
static CGFloat OhrtFactsSideIn(id list) {
    SEL objects = NSSelectorFromString(@"objects"), controllerFor = NSSelectorFromString(@"sectionControllerForObject:"), inset = NSSelectorFromString(@"inset");
    Class bio = NSClassFromString(@"IGProfileBioSectionControllerModel");
    if (!bio || ![list respondsToSelector:objects] || ![list respondsToSelector:controllerFor]) return kOhrtFactsSide;
    for (id object in ((NSArray * (*)(id, SEL))objc_msgSend)(list, objects)) {
        if (![object isKindOfClass:bio]) continue;
        id controller = ((id (*)(id, SEL, id))objc_msgSend)(list, controllerFor, object);
        if (![controller respondsToSelector:inset]) break;
        UIEdgeInsets insets = ((UIEdgeInsets (*)(id, SEL))objc_msgSend)(controller, inset);
        return insets.left >= 4 && insets.left <= 40 ? insets.left : kOhrtFactsSide;
    }
    return kOhrtFactsSide;
}

static CGFloat OhrtFactsWidth(id list) {
    SEL size = NSSelectorFromString(@"containerSize");
    CGFloat width = [list respondsToSelector:size] ? ((CGSize (*)(id, SEL))objc_msgSend)(list, size).width : 0;
    return width >= 100 ? width : [UIScreen mainScreen].bounds.size.width;
}

static NSInteger OhrtFactsNumberOfItems(id self, SEL _cmd) {
    return 1;
}

static CGSize OhrtFactsSizeForItem(id self, SEL _cmd, NSInteger index) {
    OhrtFactsModel *model = objc_getAssociatedObject(self, &kOhrtModelKey);
    id list = OhrtCall(self, @"collectionContext");
    CGFloat width = OhrtFactsWidth(list);
    CGFloat height = OhrtFactsTextHeight(model.text, width - 2 * OhrtFactsSideIn(list));
    return CGSizeMake(width, height > 0 ? kOhrtFactsAbove + height + kOhrtFactsBelow : 0.01);
}

static id OhrtFactsCellForItem(id self, SEL _cmd, NSInteger index) {
    OhrtFactsModel *model = objc_getAssociatedObject(self, &kOhrtModelKey);
    id list = OhrtCall(self, @"collectionContext");
    SEL dequeue = NSSelectorFromString(@"dequeueReusableCellOfClass:forSectionController:atIndex:");
    OhrtFactsCell *cell = ((id (*)(id, SEL, Class, id, NSInteger))objc_msgSend)(list, dequeue, [OhrtFactsCell class], self, index);
    if ([cell isKindOfClass:[OhrtFactsCell class]]) {
        cell.side = OhrtFactsSideIn(list);
        cell.label.text = model.text;
        [cell setNeedsLayout];
    }
    return cell;
}

static void OhrtFactsDidUpdate(id self, SEL _cmd, id object) {
    objc_setAssociatedObject(self, &kOhrtModelKey, [object isKindOfClass:[OhrtFactsModel class]] ? object : nil, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
}

// The header may ask its controllers things only Instagram's own know how
// to answer. Ours takes any such message and does nothing.
static NSMethodSignature *OhrtFactsSignature(id self, SEL _cmd, SEL selector) {
    struct objc_super parent = {self, class_getSuperclass(object_getClass(self))};
    NSMethodSignature *known = ((NSMethodSignature * (*)(struct objc_super *, SEL, SEL))objc_msgSendSuper)(&parent, _cmd, selector);
    return known ?: [NSMethodSignature signatureWithObjCTypes:"v@:"];
}

static void OhrtFactsForward(id self, SEL _cmd, NSInvocation *invocation) {
}

static Class OhrtFactsControllerClass(void) {
    static Class made;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        Class parent = NSClassFromString(@"IGListSectionController");
        SEL dequeue = NSSelectorFromString(@"dequeueReusableCellOfClass:forSectionController:atIndex:");
        if (!parent || ![NSClassFromString(@"IGListAdapter") instancesRespondToSelector:dequeue]) return;
        Class controller = objc_allocateClassPair(parent, "OhrtFactsSectionController", 0);
        if (!controller) return;
        class_addMethod(controller, NSSelectorFromString(@"numberOfItems"), (IMP)OhrtFactsNumberOfItems, "q@:");
        class_addMethod(controller, NSSelectorFromString(@"sizeForItemAtIndex:"), (IMP)OhrtFactsSizeForItem, "{CGSize=dd}@:q");
        class_addMethod(controller, NSSelectorFromString(@"cellForItemAtIndex:"), (IMP)OhrtFactsCellForItem, "@@:q");
        class_addMethod(controller, NSSelectorFromString(@"didUpdateToObject:"), (IMP)OhrtFactsDidUpdate, "v@:@");
        class_addMethod(controller, @selector(methodSignatureForSelector:), (IMP)OhrtFactsSignature, "@@::");
        class_addMethod(controller, @selector(forwardInvocation:), (IMP)OhrtFactsForward, "v@:@");
        objc_registerClassPair(controller);
        made = controller;
    });
    return made;
}

// Whose profile a header is showing.
static id OhrtFactsUser(UIView *header) {
    Class userClass = NSClassFromString(@"IGUser");
    if (!userClass) return nil;
    id found = nil;
    NSString *via = @"nothing";
    id source = OhrtCall(OhrtIvar(header, "_dataSource"), @"user");
    if ([source isKindOfClass:userClass]) {
        found = source;
        via = @"its data source";
    }
    for (UIResponder *responder = header.nextResponder; responder && !found; responder = responder.nextResponder) {
        if (![responder isKindOfClass:[UIViewController class]]) continue;
        id user = OhrtCall(responder, @"user");
        if ([user isKindOfClass:userClass]) {
            found = user;
            via = NSStringFromClass([responder class]);
        }
    }
    static BOOL described;
    if (!described && (found || header.window)) {
        described = YES;
        OhrtLog(@"facts: the header's account comes from %@", via);
    }
    return found;
}

%group OhrtFacts

%hook IGProfileHeaderView
- (id)objectsForListAdapter:(id)adapter {
    NSArray *objects = %orig;
    if (![objects isKindOfClass:[NSArray class]] || !OhrtFactsControllerClass()) return objects;
    __block NSArray *with = objects;
    OhrtTry(@"facts", ^{
        id user = OhrtFactsUser(self);
        NSString *text = OhrtFactsText(user);
        if (!text.length) return;
        OhrtFactsModel *model = [OhrtFactsModel new];
        model.text = text;
        // Above the buttons, which is under "Followed by" when the profile
        // has that. On your own profile Instagram puts a block of its own
        // above the buttons a moment after the rest, and anything already
        // sitting there is pushed down as it arrives. So ours goes above
        // that block's place too, and stays where it first appears. A
        // header with neither gets it at the end.
        Class buttons = NSClassFromString(@"IGProfileActionBarViewModel");
        Class late = NSClassFromString(@"IGBloksHyperdashViewModel");
        NSUInteger at = objects.count;
        for (NSUInteger index = 0; index < objects.count; index++) {
            id object = objects[index];
            if ((buttons && [object isKindOfClass:buttons]) || (late && [object isKindOfClass:late])) {
                at = index;
                break;
            }
        }
        NSMutableArray *changed = [objects mutableCopy];
        [changed insertObject:model atIndex:at];
        with = changed;
        static BOOL said;
        if (!said) {
            said = YES;
            OhrtLog(@"facts: %lu facts go in at place %lu of %lu in the header", (unsigned long)[text componentsSeparatedByString:@", "].count, (unsigned long)at,
                    (unsigned long)objects.count);
        }
        OhrtActivityListen();
    });
    return with;
}
- (id)listAdapter:(id)adapter sectionControllerForObject:(id)object {
    if ([object isKindOfClass:[OhrtFactsModel class]]) {
        Class controller = OhrtFactsControllerClass();
        if (controller) return [controller new];
    }
    return %orig;
}
%end

%end

// Your own story's numbers, at the top of its list of viewers: how many of
// those who saw it watched it again, how many shared it on, how many saw it
// on Facebook, and which viewers do not follow you. Who rewatched is not
// in the app's data, only how many. They come with the story; Instagram reads them for
// its story overview, which not every account is shown.
static NSString *OhrtStoryStatsText(id media) {
    long long viewers = [OhrtCallValue(media, @"totalViewerCount") longLongValue];
    id rewatched = OhrtCallValue(media, @"totalRewatcherCount");
    id reshares = OhrtCallValue(media, @"reshareCount");
    id facebook = OhrtCallValue(media, @"fbViewerCount");
    static NSUInteger told;
    if (told < 4) {
        told++;
        OhrtLog(@"story stats: a story of yours came with %@%@%@%@", viewers > 0 ? @"total_viewer_count " : @"", rewatched ? @"total_rewatcher_count " : @"",
                reshares ? @"reshare_count " : @"", facebook ? @"fb_viewer_count" : @"");
    }
    NSMutableArray<NSString *> *facts = [NSMutableArray array];
    if ([rewatched isKindOfClass:[NSNumber class]] && [rewatched longLongValue] > 0) {
        long long again = [rewatched longLongValue];
        [facts addObject:viewers > 0 ? [NSString stringWithFormat:@"%@ of %@ viewers rewatched", OhrtGrouped(again), OhrtGrouped(viewers)]
                                     : [NSString stringWithFormat:@"%@ rewatched", OhrtGrouped(again)]];
    }
    if ([reshares isKindOfClass:[NSNumber class]] && [reshares longLongValue] > 0) {
        [facts addObject:[NSString stringWithFormat:@"%@ %@", OhrtGrouped([reshares longLongValue]), [reshares longLongValue] == 1 ? @"reshare" : @"reshares"]];
    }
    if ([facebook isKindOfClass:[NSNumber class]] && [facebook longLongValue] > 0) {
        [facts addObject:[NSString stringWithFormat:@"%@ from facebook", OhrtGrouped([facebook longLongValue])]];
    }
    return facts.count ? [facts componentsJoinedByString:@", "] : nil;
}

// The account a row of the viewer list is about, if it is one.
static id OhrtViewerAccount(id object) {
    Class userClass = NSClassFromString(@"IGUser");
    if (!userClass) return nil;
    if ([object isKindOfClass:userClass]) return object;
    id user = OhrtCallValue(object, @"user");
    return [user isKindOfClass:userClass] ? user : nil;
}

// Whether a viewer follows you: what Instagram says, or failing that what
// your export said when it was made.
static BOOL OhrtViewerFollows(id user) {
    if (OhrtCallBool(user, @"followsCurrentUser")) return YES;
    NSString *username = OhrtText(OhrtCallValue(user, @"username"));
    return username && OhrtExportPerson(username)[@"follows_you"] != nil;
}

// Viewers who do not follow you go to the top of the list, in the order
// Instagram had them, and are named in the line above it. Rows that are not
// viewers keep their places.
static NSArray *OhrtViewersStrangersFirst(NSArray *objects, NSString **named) {
    NSMutableArray<NSNumber *> *slots = [NSMutableArray array];
    NSMutableArray *strangers = [NSMutableArray array], *others = [NSMutableArray array];
    NSMutableArray<NSString *> *names = [NSMutableArray array];
    NSUInteger saysFollows = 0, exportSays = 0, known = 0;
    for (NSUInteger index = 0; index < objects.count; index++) {
        id user = OhrtViewerAccount(objects[index]);
        if (!user) continue;
        [slots addObject:@(index)];
        if (OhrtCallBool(user, @"followsCurrentUser")) saysFollows++;
        if (OhrtCallValue(user, @"friendshipStatus")) known++;
        NSString *username = OhrtText(OhrtCallValue(user, @"username"));
        if (username && OhrtExportPerson(username)[@"follows_you"]) exportSays++;
        if (OhrtViewerFollows(user)) {
            [others addObject:objects[index]];
        } else {
            [strangers addObject:objects[index]];
            if (username) [names addObject:[@"@" stringByAppendingString:username]];
        }
    }
    static NSUInteger told;
    if (told < 3) {
        told++;
        NSMutableSet<NSString *> *kinds = [NSMutableSet set];
        for (id object in objects) [kinds addObject:NSStringFromClass([object class])];
        OhrtLog(@"story stats: a viewer list of %lu rows (%@), %lu viewers, %lu say they follow you, %lu come with a friendship status, the export has %lu as followers", (unsigned long)objects.count,
                [kinds.allObjects componentsJoinedByString:@" "], (unsigned long)slots.count, (unsigned long)saysFollows, (unsigned long)known, (unsigned long)exportSays);
    }
    // A list that says nothing about who follows you would name everyone.
    if (!saysFollows && !known && !exportSays) return objects;
    if (!strangers.count) return objects;
    NSMutableArray *changed = [objects mutableCopy];
    NSArray *ordered = [strangers arrayByAddingObjectsFromArray:others];
    for (NSUInteger index = 0; index < slots.count; index++) changed[slots[index].unsignedIntegerValue] = ordered[index];
    NSUInteger shown = MIN(names.count, (NSUInteger)10);
    NSString *list = [[names subarrayWithRange:NSMakeRange(0, shown)] componentsJoinedByString:@", "];
    if (names.count > shown) list = [list stringByAppendingFormat:@" and %lu more", (unsigned long)(names.count - shown)];
    *named = [NSString stringWithFormat:@"%lu %@ follow you%@%@", (unsigned long)strangers.count, strangers.count == 1 ? @"doesn't" : @"don't", list.length ? @": " : @"", list];
    return changed;
}

%group OhrtStoryStats

%hook IGStoryViewersListViewController
- (id)objectsForListAdapter:(id)adapter {
    NSArray *objects = %orig;
    if (![objects isKindOfClass:[NSArray class]]) return objects;
    __block NSArray *with = objects;
    OhrtTry(@"story stats", ^{
        id item = OhrtIvar(self, "_item");
        NSString *named = nil;
        NSArray *ordered = OhrtViewersStrangersFirst(objects, &named);
        NSString *stats = OhrtStoryStatsText(OhrtCall(item, @"media") ?: item);
        NSString *text = stats && named ? [NSString stringWithFormat:@"%@, %@", stats, named] : stats ?: named;
        if (!text.length) {
            with = ordered;
            return;
        }
        OhrtFactsModel *model = [OhrtFactsModel new];
        model.text = text;
        NSMutableArray *changed = [ordered mutableCopy];
        [changed insertObject:model atIndex:0];
        with = changed;
    });
    return with;
}
- (id)listAdapter:(id)adapter sectionControllerForObject:(id)object {
    if ([object isKindOfClass:[OhrtFactsModel class]]) {
        Class controller = OhrtFactsControllerClass();
        if (controller) return [controller new];
    }
    return %orig;
}
%end

%end

void OhrtInstallFacts(void) {
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        if (!OhrtFeatureReady(kOhrtFactsKey, @"facts")) return;
        if (!OhrtFactsControllerClass()) {
            OhrtLog(@"facts: left off, this Instagram's lists aren't the kind ours is made from");
            return;
        }
        %init(OhrtFacts);
        OhrtLog(@"facts: profiles get their lines");
        if (OhrtAvailable(@"storystats")) %init(OhrtStoryStats);
    });
}
