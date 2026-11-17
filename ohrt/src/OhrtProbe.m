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
    NSMutableArray<NSString *> *parts = [NSMutableArray array];
    for (id key in dictionary) {
        if (parts.count >= 40) break;
        [parts addObject:[NSString stringWithFormat:@"%@ %@", OhrtProbeShow([key description]), OhrtProbeShow(dictionary[key])]];
    }
    OhrtLog(@"probe: %@ has %lu: %@", what, (unsigned long)[dictionary count], [parts componentsJoinedByString:@", "]);
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
    });
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
                    void (^answer)(void *, void *, double, double) = ^(void *first, void *second, double one, double two) {
                        OhrtLog(@"probe: the next-open predictor answered: values %p %p, numbers %.6g %.6g", first, second, one, two);
                    };
                    ((void (*)(id, SEL, id, id))objc_msgSend)(casper, estimate, answer, dispatch_get_main_queue());
                    OhrtLog(@"probe: the next-open predictor was asked");
                }
            });
        });
    });
}
