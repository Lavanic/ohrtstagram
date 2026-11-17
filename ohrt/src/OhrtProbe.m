// Finds out, on the phone, which of Instagram's hidden numbers are really
// there. Reading its code only says a value could exist; these write to the
// log what arrives and what it looks like, for a handful of each, before
// anything is built to show it. Numbers, flags and Instagram's own terms
// only: never a name, a username or anything someone wrote.
#import <objc/message.h>
#import <objc/runtime.h>

#import "Ohrt.h"

static id OhrtProbeIvar(id object, const char *name) {
    Ivar ivar = object ? class_getInstanceVariable([object class], name) : NULL;
    if (!ivar) return nil;
    const char *type = ivar_getTypeEncoding(ivar);
    return type && type[0] == '@' ? object_getIvar(object, ivar) : nil;
}

// A value as it can go in the log: a number as itself, text only when it is
// short and a single word of Instagram's (no spaces), otherwise its kind.
static NSString *OhrtProbeShow(id value) {
    if (!value || value == [NSNull null]) return @"none";
    if ([value isKindOfClass:[NSNumber class]]) return [NSString stringWithFormat:@"%.6g", [value doubleValue]];
    if ([value isKindOfClass:[NSString class]]) {
        NSString *text = value;
        if (text.length && text.length <= 48 && [text rangeOfCharacterFromSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]].location == NSNotFound) return text;
        return [NSString stringWithFormat:@"text(%lu)", (unsigned long)text.length];
    }
    if ([value isKindOfClass:[NSArray class]]) {
        NSArray *list = value;
        NSMutableArray *some = [NSMutableArray array];
        for (id item in list) {
            if (some.count >= 6) break;
            [some addObject:[item isKindOfClass:[NSNumber class]] || [item isKindOfClass:[NSString class]] ? OhrtProbeShow(item) : NSStringFromClass([item class])];
        }
        return [NSString stringWithFormat:@"[%lu: %@]", (unsigned long)list.count, [some componentsJoinedByString:@" "]];
    }
    if ([value isKindOfClass:[NSDictionary class]]) return [NSString stringWithFormat:@"{%lu}", (unsigned long)[value count]];
    return NSStringFromClass([value class]);
}

static NSString *OhrtProbeFields(id object, NSArray<NSString *> *names) {
    NSMutableArray<NSString *> *found = [NSMutableArray array];
    for (NSString *name in names) {
        id value = OhrtCallValue(object, name);
        if (value) [found addObject:[NSString stringWithFormat:@"%@ %@", name, OhrtProbeShow(value)]];
    }
    return found.count ? [found componentsJoinedByString:@", "] : @"nothing";
}

static BOOL OhrtProbeMay(NSUInteger *counter, NSUInteger most) {
    static NSObject *lock;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        lock = [NSObject new];
    });
    @synchronized(lock) {
        if (*counter >= most) return NO;
        (*counter)++;
        return YES;
    }
}

static void OhrtProbeDictionary(NSString *what, id dictionary) {
    if (![dictionary isKindOfClass:[NSDictionary class]]) {
        OhrtLog(@"probe: %@ is %@", what, dictionary ? NSStringFromClass([dictionary class]) : @"not there");
        return;
    }
    // In lines of twenty, so that none is cut short by the log.
    NSArray *keys = [[dictionary allKeys] sortedArrayUsingComparator:^NSComparisonResult(id one, id other) {
        return [[one description] compare:[other description]];
    }];
    OhrtLog(@"probe: %@ has %lu", what, (unsigned long)keys.count);
    NSMutableArray<NSString *> *parts = [NSMutableArray array];
    for (NSUInteger index = 0; index < keys.count && index < 400; index++) {
        id value = dictionary[keys[index]];
        [parts addObject:[NSString stringWithFormat:@"%@ %@", OhrtProbeShow([keys[index] description]), OhrtProbeShow(value)]];
        if (parts.count == 20 || index + 1 == keys.count) {
            OhrtLog(@"probe: %@: %@", what, [parts componentsJoinedByString:@", "]);
            [parts removeAllObjects];
        }
        if ([value isKindOfClass:[NSDictionary class]] && [value count] > 2) OhrtProbeDictionary([NSString stringWithFormat:@"%@.%@", what, OhrtProbeShow([keys[index] description])], value);
    }
}

void OhrtProbeReel(id reel) {
    static NSUInteger told;
    if (!reel || !OhrtProbeMay(&told, 6)) return;
    OhrtTry(@"probe", ^{
        id ranker = OhrtCallValue(reel, @"rankerScores");
        OhrtLog(@"probe: a story in the tray: ranked %@, seen-ranked %@, scores %@", OhrtProbeShow(OhrtCallValue(reel, @"rankedPosition")), OhrtProbeShow(OhrtCallValue(reel, @"seenRankedPosition")),
                OhrtProbeFields(ranker, @[ @"ptap", @"vm", @"bffScores", @"preply", @"plike", @"pskip", @"pnext", @"preciprocal", @"pcontact", @"pevpvd", @"timeSpent", @"emeimps", @"adjustIntegrityScores",
                                           @"crownVmScoresFinal", @"generalVmScoresFinal", @"generalVmScoreWithoutPtap", @"rankedAtTimestampS" ]));
    });
}

void OhrtProbeMedia(id media) {
    static NSUInteger told;
    if (!media || !OhrtProbeMay(&told, 10)) return;
    OhrtTry(@"probe", ^{
        id bitmap = OhrtCallValue(media, @"brsContentBlocklistBitmapObj");
        id topic = OhrtCallValue(media, @"carreraTopicMetadata");
        OhrtLog(@"probe: a post's reach: %@; blocklist %@; topic %@",
                OhrtProbeFields(media, @[ @"geoGatedCountries", @"isAwaitingDistribution", @"boostUnavailableReason", @"boostUnavailableReasonV2", @"xpostDenyReason", @"threadsXpostDenyReason",
                                          @"commerceIntegrityReviewDecision", @"hasBcViolation", @"deletedReason", @"visibility", @"mediaNotice", @"postImpressionCount", @"contentViewsCount",
                                          @"mediaRepostCount", @"thLikeCount", @"ctvTopic" ]),
                bitmap ? OhrtProbeFields(bitmap, @[ @"encode", @"bitmapString", @"bitmapArray" ]) : @"none", topic ? OhrtProbeFields(topic, @[ @"topic" ]) : @"none");
        id explore = OhrtCallValue(media, @"explore");
        id interest = OhrtCallValue(media, @"interestMetadata");
        OhrtLog(@"probe: a post: %@; explore %@; interest %@", OhrtProbeFields(media, @[ @"brsSeverity", @"mainFeedDeliveryMethods", @"isInFeedRecommendation", @"algorithm", @"recommendationData",
                                                                                         @"dateReceivedFromServer", @"inventorySource", @"mainFeedRequestReason" ]),
                explore ? OhrtProbeFields(explore, @[ @"explanation", @"interest", @"sourceToken" ]) : @"none", interest ? OhrtProbeFields(interest, @[ @"interestText", @"interestType" ]) : @"none");
    });
}

void OhrtProbeThread(id metadata) {
    static NSUInteger told;
    if (!metadata || !OhrtProbeMay(&told, 10)) return;
    OhrtTry(@"probe", ^{
        OhrtLog(@"probe: a conversation: %@", OhrtProbeFields(metadata, @[ @"relevancyScore", @"isTopAccountThread", @"isCloseFriendThread", @"responsivenessCategory", @"isNewFriendBump", @"isSpamRequest" ]));
        // When each side last read, as seconds after the message it read
        // was sent. Whose is whose is not logged.
        id seen = OhrtCallValue(metadata, @"lastSeenMessageIdsForUserIds");
        if (![seen isKindOfClass:[NSDictionary class]]) {
            OhrtLog(@"probe: a conversation's last-seen list is %@", seen ? NSStringFromClass([seen class]) : @"not there");
            return;
        }
        NSMutableArray<NSString *> *gaps = [NSMutableArray array];
        for (id info in [(NSDictionary *)seen allValues]) {
            NSDate *at = OhrtProbeIvar(info, "_seenAtTimestamp"), *sent = OhrtProbeIvar(info, "_sentTimestamp");
            BOOL both = [at isKindOfClass:[NSDate class]] && [sent isKindOfClass:[NSDate class]];
            [gaps addObject:both ? [NSString stringWithFormat:@"%.0fs", [at timeIntervalSinceDate:sent]] : [NSString stringWithFormat:@"seen %@ sent %@", at ? @"set" : @"none", sent ? @"set" : @"none"]];
        }
        OhrtLog(@"probe: a conversation's last-seen list has %lu: %@", (unsigned long)[seen count], [gaps componentsJoinedByString:@", "]);
    });
}

// The fields of an account nothing of ours reads yet: which come filled.
// Numbers and Instagram's own labels are logged; anything that could tell
// who or where someone is only as being set.
void OhrtProbeUser(id user, BOOL mine) {
    static NSUInteger others, own;
    if (!user || !OhrtProbeMay(mine ? &own : &others, mine ? 1 : 8)) return;
    OhrtTry(@"probe", ^{
        NSString *shown = OhrtProbeFields(user, @[
            @"totalClipsCount", @"friendsCount", @"mutualFollowersCount", @"textPostAppJoinerNumber", @"acrCount", @"transparencyLabel", @"authenticityType", @"followFrictionType", @"restrictionType",
            @"isPotentialBusiness", @"isInterestAccount", @"isSecondaryAccountCreation", @"isNewToInstagram30d", @"isVerifiedSearchBoosted", @"isEligibleForSeoIndexing", @"isWhatsappLinked",
            @"isSpotifyAccountLinked", @"hasAnonymousProfilePicture", @"isSupervisionFeaturesEnabled", @"isRegulatedC18", @"isHighRiskSharesheetRecipient", @"isNeedy", @"isAdRater"
        ]);
        NSMutableArray<NSString *> *set = [NSMutableArray array];
        for (NSString *name in @[ @"fbidV2", @"lastSeenTimezone", @"homeCountry", @"viewerPredictedLanguage", @"stateRunMediaCountry", @"growthFrictionInfo", @"linkedFbInfo" ]) {
            if (OhrtCallValue(user, name)) [set addObject:name];
        }
        NSMutableArray<NSString *> *boxed = [NSMutableArray array];
        for (NSString *name in @[ @"coeffWeight", @"paaScore" ]) {
            id value = OhrtCallValue(user, name);
            if ([value respondsToSelector:@selector(doubleValue)]) [boxed addObject:[NSString stringWithFormat:@"%@ %.4g", name, [value doubleValue]]];
            else if (value) [boxed addObject:[NSString stringWithFormat:@"%@ %@", name, NSStringFromClass([value class])]];
        }
        id creator = OhrtCallValue(user, @"creatorInfo");
        OhrtLog(@"probe: %@: %@; set: %@; boxed: %@; creator %@", mine ? @"your own account" : @"an account", shown, set.count ? [set componentsJoinedByString:@" "] : @"none",
                boxed.count ? [boxed componentsJoinedByString:@", "] : @"none", creator ? OhrtProbeFields(creator, @[ @"creatorSegmentation" ]) : @"none");
    });
}

// The times of day Instagram's servers predict you will open the feed and
// stories, which its next-open model takes in. Read as the raw numbers.
static void OhrtProbeBestTimes(id session) {
    typedef struct {
        long long timestamps[12];
        double loadTimestamp;
        char state;
        long long type;
    } OhrtBestTimes;
    id store = OhrtCallValue(session, @"btpTimestampsStore");
    if (!store) {
        OhrtLog(@"probe: no best-times store");
        return;
    }
    for (NSString *name in @[ @"_feedPredictedTimestampsInfo", @"_storiesPredictedTimestampsInfo" ]) {
        Ivar ivar = class_getInstanceVariable([store class], name.UTF8String);
        const char *type = ivar ? ivar_getTypeEncoding(ivar) : NULL;
        // Only if it is laid out as this was written for.
        if (!type || strcmp(type, "{?=\"timestamps\"[12q]\"loadTimestamp\"d\"state\"c\"type\"q}") != 0) {
            OhrtLog(@"probe: best times %@ is laid out as %s", name, type ?: "nothing");
            continue;
        }
        OhrtBestTimes times;
        memcpy(&times, (const char *)(__bridge void *)store + ivar_getOffset(ivar), sizeof(times));
        NSMutableArray<NSString *> *all = [NSMutableArray array];
        for (int index = 0; index < 12; index++) [all addObject:[NSString stringWithFormat:@"%lld", times.timestamps[index]]];
        OhrtLog(@"probe: best times %@: %@; loaded %.0f, state %d, type %lld, now %.0f", name, [all componentsJoinedByString:@" "], times.loadTimestamp, (int)times.state, times.type,
                [NSDate date].timeIntervalSince1970);
    }
}

void OhrtProbeRecipient(id entity) {
    static NSUInteger told;
    if (!entity || !OhrtProbeMay(&told, 6)) return;
    OhrtTry(@"probe", ^{
        id recipient = OhrtProbeIvar(entity, "_recipient");
        id embedding = OhrtCallValue(recipient, @"avgThreadEmbedding");
        OhrtLog(@"probe: a share sheet entry: %@, embedding of %lu, final position %@, default score %@", OhrtProbeFields(recipient, @[ @"numReshares", @"rankScore" ]),
                (unsigned long)([embedding isKindOfClass:[NSArray class]] ? [embedding count] : 0), OhrtProbeShow(OhrtProbeIvar(recipient, "_finalPosition")), OhrtProbeShow(OhrtProbeIvar(recipient, "_defaultRankScore")));
    });
}

// What Instagram keeps about you yourself. Once a run, a few seconds after
// the first profile is opened.
void OhrtProbeSession(void) {
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(4 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
            OhrtTry(@"probe", ^{
                id session = OhrtCurrentSession();
                if (!session) return;

                id defaults = OhrtCall(session, @"sessionUserDefaults");
                SEL objectForKey = @selector(objectForKey:);
                id features = [defaults respondsToSelector:objectForKey] ? ((id (*)(id, SEL, id))objc_msgSend)(defaults, objectForKey, @"personalization_features") : nil;
                if ([features isKindOfClass:[NSData class]]) features = [NSJSONSerialization JSONObjectWithData:features options:0 error:nil];
                OhrtProbeDictionary(@"personalization features", features);

                OhrtProbeDictionary(@"smart features", OhrtCallValue(OhrtCall(session, @"personalizationSmartFeatureStore"), @"getAllValidFeatures"));
                OhrtProbeDictionary(@"the ads cohort", OhrtCallValue(OhrtCall(session, @"adsPersonalizationManager"), @"getCohortPayload"));

                id signals = OhrtCall(session, @"sundialViewerSignalsCoreManager");
                id seen = OhrtCall(session, @"seenStateStore");
                OhrtLog(@"probe: reels signals manager %@, seen state store %@", signals ? NSStringFromClass([signals class]) : @"not there", seen ? NSStringFromClass([seen class]) : @"not there");

                OhrtProbeBestTimes(session);

                id casper = OhrtCall(session, @"casper");
                id example = OhrtProbeIvar(casper, "_latestNextAppStartProbaExample");
                OhrtLog(@"probe: next-open predictor %@, model %@, latest example %@", casper ? NSStringFromClass([casper class]) : @"not there", OhrtProbeShow(OhrtCallValue(casper, @"nextGenPredictorModelIdentifier")),
                        example ? NSStringFromClass([example class]) : @"none");
                // The predictor is asked once per build: what its answer block
                // is handed is not known, so it is taken as raw values, and if
                // asking brings the app down it is not asked again.
                NSString *asked = [@"ohrt_probe_casper_" stringByAppendingString:OHRT_BUILD];
                SEL estimate = NSSelectorFromString(@"estimateMinutesToNextTargetEventAfterBackground:completionQueue:");
                if ([casper respondsToSelector:estimate] && ![[NSUserDefaults standardUserDefaults] boolForKey:asked]) {
                    [[NSUserDefaults standardUserDefaults] setBool:YES forKey:asked];
                    [[NSUserDefaults standardUserDefaults] synchronize];
                    // The first asking gave back what reads as a float of
                    // about 160 in the first number slot and 161 in the first
                    // value slot. Both readings are logged to tell which.
                    void (^answer)(long long, float) = ^(long long whole, float minutes) {
                        OhrtLog(@"probe: the next-open predictor answered: %lld as a whole number, %.2f as a fraction", whole, minutes);
                    };
                    ((void (*)(id, SEL, id, id))objc_msgSend)(casper, estimate, (id)answer, dispatch_get_main_queue());
                    OhrtLog(@"probe: the next-open predictor was asked");
                }
            });
        });
    });
}
