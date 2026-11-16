// Facts on a profile: a few small lines above the Follow and Message
// buttons, of what the app holds about the account and does not show.
//
//   id 1234567890, creator, follows you since 2019-03-05, followed since 2019-03-02,
//   you liked 214 posts (last 2026-10-30), commented 12 times, watched 88 stories since 2026-11-15,
//   340 messages between you since 2020-01-10, story 3h ago
//
// There are two sources, and nothing is asked of Instagram for either. The
// first is what the app already holds when a profile opens: the id, the
// kind of account, whether it follows you, its latest story, and the scores
// and flags Instagram keeps on it, each only when the server sent it. The
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

// The red of the calico jack, #ff0349, made light enough to read on a
// dark page: that colour was wanted, less harsh, then lighter. On a light
// page it is the red itself.
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

static UIColor *OhrtFactsColour(void) {
    return [UIColor colorWithDynamicProvider:^UIColor *(UITraitCollection *traits) {
        return OhrtColor(traits.userInterfaceStyle == UIUserInterfaceStyleDark ? kOhrtFactsOnDark : kOhrtFactsOnLight);
    }];
}

UIFont *OhrtFactsLineFont(void) {
    return OhrtFactsFont();
}

UIColor *OhrtFactsLineColour(void) {
    return OhrtFactsColour();
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
        formatter.dateFormat = @"yyyy-MM-dd";
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

// "liked 214 posts (last 2026-10-30)". The first of these on a line is
// given its "you" by the caller.
static void OhrtAddDone(NSMutableArray<NSString *> *done, NSString *kind, NSDictionary *past, NSString *pk, NSString *verb, NSString *one, NSString *many, BOOL withLast) {
    NSTimeInterval last = 0;
    NSInteger count = OhrtCountOf(kind, past, pk, &last);
    if (count < 1) return;
    NSString *text = [NSString stringWithFormat:@"%@ %ld %@", verb, (long)count, count == 1 ? one : many];
    if (withLast && last > 0) text = [text stringByAppendingFormat:@" (last %@)", OhrtStamp(@(last))];
    [done addObject:text];
}

// Your history with an account that is not your own: what the app says
// stands now, with the days and counts the export and our own notes give.
static void OhrtAddHistory(NSMutableArray<NSString *> *facts, id user, NSString *pk) {
    NSDictionary *past = OhrtExportPerson(OhrtText(OhrtCall(user, @"username")));
    BOOL followsYou = OhrtCallBool(user, @"followsCurrentUser");
    BOOL followed = OhrtCallBool(user, @"followedByCurrentUser");

    if (followsYou) [facts addObject:past[@"follows_you"] ? [@"follows you since " stringByAppendingString:OhrtStamp(past[@"follows_you"])] : @"follows you"];
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
    OhrtAddDone(done, @"likes", past, pk, @"liked", @"post", @"posts", YES);
    OhrtAddDone(done, @"comments", past, pk, @"commented", @"time", @"times", NO);
    OhrtAddDone(done, @"story_likes", past, pk, @"liked", @"story", @"stories", NO);
    OhrtAddDone(done, @"saved", past, pk, @"saved", @"post", @"posts", NO);
    NSUInteger watched = OhrtActivityTimes(pk, @"stories_seen").count;
    if (watched) {
        NSString *text = [NSString stringWithFormat:@"watched %lu %@", (unsigned long)watched, watched == 1 ? @"story" : @"stories"];
        [done addObject:whole && began ? [text stringByAppendingFormat:@" since %@", began] : text];
    }
    if (done.count) {
        done[0] = whole || !began ? [@"you " stringByAppendingString:done[0]] : [NSString stringWithFormat:@"since %@ you %@", began, done[0]];
        [facts addObjectsFromArray:done];
    }

    // The export has the conversation from its first message. One it does
    // not have, or cannot tell from another by its name, is counted from
    // where our own count starts.
    NSDictionary *thread = OhrtExportThread(OhrtText(OhrtCall(user, @"fullName")));
    NSTimeInterval counted = 0;
    NSInteger messages = [thread[@"messages"] integerValue] + OhrtActivityMessages(pk, &counted);
    if (messages > 0) {
        [facts addObject:[NSString stringWithFormat:@"%ld %@ between you since %@", (long)messages, messages == 1 ? @"message" : @"messages", OhrtStamp(thread[@"first"] ?: @(counted))]];
    }
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

static BOOL OhrtFactsTrue(id value) {
    return [value isKindOfClass:[NSNumber class]] && [value boolValue];
}

static NSString *OhrtFactsScore(NSString *label, id value) {
    if (![value isKindOfClass:[NSNumber class]] || [value doubleValue] == 0) return nil;
    return [NSString stringWithFormat:fabs([value doubleValue]) >= 0.005 ? @"%@ %.2f" : @"%@ %.2g", label, [value doubleValue]];
}

// Which of these came with the first few profiles, by field name only.
static void OhrtFactsSayFields(NSString *pk, NSArray<NSString *> *fields) {
    static NSMutableSet<NSString *> *told;
    if (!told) told = [NSMutableSet set];
    if (told.count >= 8 || [told containsObject:pk]) return;
    [told addObject:pk];
    OhrtLog(@"facts: a profile came with %@", fields.count ? [fields componentsJoinedByString:@" "] : @"none of the score and flag fields");
}

// What Instagram itself holds about an account that is not your own and
// does not show: how close it reckons you are, what it has flagged, where
// it places the account. Each is shown under the server's own name for it,
// since what goes into a score is not known here.
static void OhrtAddScores(NSMutableArray<NSString *> *facts, id user, NSString *pk) {
    NSMutableArray<NSString *> *fields = [NSMutableArray array];

    // -[IGUser bffScore] is this same number.
    NSString *closeness = OhrtFactsScore(@"closeness", OhrtCallValue(user, @"closenessScore"));
    if (closeness) {
        [fields addObject:@"closeness_score"];
        [facts addObject:closeness];
    }
    NSString *coeff = OhrtFactsScore(@"coeff weight", OhrtCallValue(user, @"coeffWeight"));
    if (coeff) {
        [fields addObject:@"coeff_weight"];
        [facts addObject:coeff];
    }

    id scammer = OhrtCallValue(user, @"isPossibleScammer");
    if (scammer) [fields addObject:@"is_possible_scammer"];
    id actor = OhrtCallValue(user, @"isPossibleBadActor");
    if (actor) [fields addObject:@"is_possible_bad_actor"];
    if (OhrtFactsTrue(scammer) || OhrtFactsTrue(OhrtCallValue(actor, @"isPossibleScammer"))) [facts addObject:@"flagged possible scammer"];
    if (OhrtFactsTrue(OhrtCallValue(actor, @"isPossibleImpersonator"))) [facts addObject:@"flagged possible impersonator"];

    id warning = OhrtCallValue(user, @"accountWarning");
    if (warning) {
        id harm = OhrtCallValue(warning, @"harmType");
        [fields addObject:[NSString stringWithFormat:@"account_warning(harm_type %@)", [harm isKindOfClass:[NSString class]] ? @"text" : [harm isKindOfClass:[NSNumber class]] ? @"number" : @"none"]];
        NSString *kind = OhrtFactsWords(harm);
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

    // Sent about someone asking to follow a supervised account, as far as
    // is known, so it is rare.
    id country = OhrtCallValue(OhrtCallValue(user, @"ukTeenOsaConnectionInfo"), @"requesterBasedInCountry");
    if ([country isKindOfClass:[NSString class]] && [country length] && [country length] <= 60) {
        [fields addObject:@"uk_teen_osa_connection_info"];
        [facts addObject:[@"based in " stringByAppendingString:country]];
    }
    id home = OhrtCallValue(user, @"homeCountry");
    if ([home isKindOfClass:[NSString class]] && [home length] && [home length] <= 60) {
        [fields addObject:@"home_country"];
        [facts addObject:[@"home country " stringByAppendingString:home]];
    }

    if ([OhrtCallValue(user, @"reelMediaSeenTimestamp") isKindOfClass:[NSNumber class]]) [fields addObject:@"reel_media_seen_timestamp"];
    OhrtFactsSayFields(pk, fields);
}

// When you last watched a story of theirs, as Instagram keeps it.
static NSString *OhrtFactsWatched(id user) {
    id stamp = OhrtCallValue(user, @"reelMediaSeenTimestamp");
    double seconds = [stamp isKindOfClass:[NSNumber class]] ? [stamp doubleValue] : 0;
    while (seconds > 1e11) seconds /= 1000.0;
    if (seconds < 1262304000 || seconds > [NSDate date].timeIntervalSince1970 + 86400) return nil;
    return [@"watched their story " stringByAppendingString:OhrtDay([NSDate dateWithTimeIntervalSince1970:seconds])];
}

static NSString *OhrtFactsText(id user) {
    NSString *pk = OhrtText(OhrtCall(user, @"pk"));
    if (!pk.length) return nil;
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
    NSString *watched = other ? OhrtFactsWatched(user) : nil;
    if (watched) [facts addObject:watched];
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
        _label.textColor = OhrtFactsColour();
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

void OhrtInstallFacts(void) {
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        if (!OhrtFeatureReady(kOhrtFactsKey, @"facts")) return;
        if (!OhrtFactsControllerClass()) {
            OhrtLog(@"facts: left off, this Instagram's lists are not the kind ours is made from");
            return;
        }
        %init(OhrtFacts);
        OhrtLog(@"facts: profiles get their lines");
    });
}
