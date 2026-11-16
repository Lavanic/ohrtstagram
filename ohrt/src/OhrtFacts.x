// Facts on a profile: a line between the picture and the bio, small and
// red, of what the app holds about the account and does not show.
//
//   id 1234567890, creator, follows you since 2019-03-05, followed since 2019-03-02,
//   214 likes (last 2026-10-30), 12 comments, 340 messages since 2020-01-10, story 3h ago
//
// It has two sources, and nothing is asked of Instagram for either. The
// first is what the app already holds when a profile opens: the id, the
// kind of account, whether it follows you, its latest story. The second is
// your own history with the account, which Instagram's app does not hold:
// when each follow happened, how much you have liked, commented, watched
// and written. That comes from your Instagram export (OhrtExport.m), and
// for follows made in this app from our own note of the day.
//
// The line is put at the top of the cell that holds the bio: the cell is
// made taller by as much as the line needs at the cell's width, wrapped,
// and the bio is moved down by that much and keeps the height it asked for.
#import <objc/runtime.h>

#import "Ohrt.h"
#import "OhrtLogic.h"

NSString *const kOhrtFactsKey = @"ohrt_facts";

// The red of the calico jack, faded: that colour was wanted, but less
// harsh. Fading it lets what is behind it through, on a dark page or a
// light one.
static const uint32_t kOhrtFactsColour = 0xff0349;
static const CGFloat kOhrtFactsFade = 0.6;
// Between the line and the bio.
static const CGFloat kOhrtFactsGap = 4;
// A bio section with no bio in it is not inset from the screen's edges, so
// the line keeps its own distance there.
static const CGFloat kOhrtFactsSide = 16;
static const NSTimeInterval kOhrtStoryLife = 24 * 60 * 60;

static char kOhrtLineKey;
static char kOhrtLabelKey;

@interface IGProfileBioSectionController : NSObject
@end

@interface IGProfileBioCell : UICollectionViewCell
@end

@interface IGFollowController : NSObject
@end

static UIFont *OhrtFactsFont(void) {
    return [UIFont systemFontOfSize:11];
}

// How tall the line is, gap included, wrapped to `width`.
static CGFloat OhrtFactsHeight(NSString *line, CGFloat width) {
    if (!line.length || !(width >= 40)) return 0;
    CGRect box = [line boundingRectWithSize:CGSizeMake(width, CGFLOAT_MAX)
                                    options:NSStringDrawingUsesLineFragmentOrigin | NSStringDrawingUsesFontLeading
                                 attributes:@{NSFontAttributeName : OhrtFactsFont()}
                                    context:nil];
    return ceil(box.size.height) + kOhrtFactsGap;
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

static NSString *OhrtMyAccount(void) {
    return OhrtText(OhrtCall(OhrtCall(OhrtCurrentSession(), @"user"), @"pk"));
}

// When each account was followed from this app, by account id, for the
// account that is signed in. Kept in a file of the app's own.
static NSString *OhrtFollowDatesPath(NSString *account) {
    NSString *support = NSSearchPathForDirectoriesInDomains(NSApplicationSupportDirectory, NSUserDomainMask, YES).firstObject;
    return [[support stringByAppendingPathComponent:@"ohrt"] stringByAppendingPathComponent:[NSString stringWithFormat:@"followed-%@.plist", account]];
}

static NSMutableDictionary<NSString *, NSNumber *> *OhrtFollowDates(NSString *account) {
    static NSMutableDictionary<NSString *, NSMutableDictionary *> *loaded;
    if (!account.length) return nil;
    if (!loaded) loaded = [NSMutableDictionary dictionary];
    NSMutableDictionary *dates = loaded[account];
    if (!dates) {
        dates = [NSMutableDictionary dictionaryWithContentsOfFile:OhrtFollowDatesPath(account)] ?: [NSMutableDictionary dictionary];
        loaded[account] = dates;
    }
    return dates;
}

static void OhrtNoteFollow(NSString *account, NSString *pk, BOOL following) {
    NSMutableDictionary<NSString *, NSNumber *> *dates = OhrtFollowDates(account);
    if (!dates || !pk.length) return;
    if (following == (dates[pk] != nil)) return;
    dates[pk] = following ? @([NSDate date].timeIntervalSince1970) : nil;
    NSString *path = OhrtFollowDatesPath(account);
    [[NSFileManager defaultManager] createDirectoryAtPath:path.stringByDeletingLastPathComponent withIntermediateDirectories:YES attributes:nil error:nil];
    [dates writeToFile:path atomically:YES];
    OhrtLog(@"facts: %@, %lu on record", following ? @"a follow noted" : @"a follow taken off the record", (unsigned long)dates.count);
}

static NSString *OhrtStamp(id seconds) {
    return OhrtDay([NSDate dateWithTimeIntervalSince1970:[seconds doubleValue]]);
}

// "214 likes (last 2026-10-30)" from a count with its first and last day.
static void OhrtAddTally(NSMutableArray<NSString *> *facts, id tally, NSString *one, NSString *many, BOOL withLast) {
    if (![tally isKindOfClass:[NSArray class]] || [tally count] < 3) return;
    NSInteger count = [tally[0] integerValue];
    if (count < 1) return;
    NSString *text = [NSString stringWithFormat:@"%ld %@", (long)count, count == 1 ? one : many];
    if (withLast && [tally[2] doubleValue] > 0) text = [text stringByAppendingFormat:@" (last %@)", OhrtStamp(tally[2])];
    [facts addObject:text];
}

// Your history with an account that is not your own: what the app says
// stands now, with the days and counts the export and our own notes give.
static void OhrtAddHistory(NSMutableArray<NSString *> *facts, id user, NSString *account, NSString *pk) {
    NSDictionary *past = OhrtExportPerson(OhrtText(OhrtCall(user, @"username")));
    BOOL followsYou = OhrtCallBool(user, @"followsCurrentUser");
    BOOL followed = OhrtCallBool(user, @"followedByCurrentUser");

    if (followsYou) [facts addObject:past[@"follows_you"] ? [@"follows you since " stringByAppendingString:OhrtStamp(past[@"follows_you"])] : @"follows you"];
    else if (past[@"follows_you"]) [facts addObject:[NSString stringWithFormat:@"followed you from %@ but not now", OhrtStamp(past[@"follows_you"])]];

    // The earlier of the export's day and the one noted here.
    NSNumber *noted = OhrtFollowDates(account)[pk];
    NSNumber *exported = past[@"followed"];
    NSNumber *since = noted && exported ? (noted.doubleValue < exported.doubleValue ? noted : exported) : (noted ?: exported);
    if (followed) {
        if (since) [facts addObject:[@"followed since " stringByAppendingString:OhrtStamp(since)]];
    } else if (past[@"unfollowed"]) {
        [facts addObject:[@"unfollowed " stringByAppendingString:OhrtStamp(past[@"unfollowed"])]];
    } else if (past[@"requested"]) {
        [facts addObject:[@"requested " stringByAppendingString:OhrtStamp(past[@"requested"])]];
    }

    if (past[@"close_friend"]) [facts addObject:[@"close friend since " stringByAppendingString:OhrtStamp(past[@"close_friend"])]];
    if (past[@"blocked"]) [facts addObject:[@"blocked " stringByAppendingString:OhrtStamp(past[@"blocked"])]];
    if (past[@"restricted"]) [facts addObject:@"restricted"];
    if (past[@"story_hidden"]) [facts addObject:@"your story is hidden from them"];

    OhrtAddTally(facts, past[@"likes"], @"like", @"likes", YES);
    OhrtAddTally(facts, past[@"comments"], @"comment", @"comments", NO);
    OhrtAddTally(facts, past[@"story_likes"], @"story like", @"story likes", NO);
    OhrtAddTally(facts, past[@"stories_seen"], @"story seen", @"stories seen", NO);
    OhrtAddTally(facts, past[@"saved"], @"saved", @"saved", NO);

    NSDictionary *thread = OhrtExportThread(OhrtText(OhrtCall(user, @"fullName")));
    NSInteger messages = [thread[@"messages"] integerValue];
    if (messages > 0) [facts addObject:[NSString stringWithFormat:@"%ld %@ since %@", (long)messages, messages == 1 ? @"message" : @"messages", OhrtStamp(thread[@"first"])]];
}

static NSString *OhrtFactsLine(id user) {
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

    NSDate *joined = OhrtDate(OhrtCall(user, @"dateJoined"));
    if (joined) [facts addObject:[@"joined " stringByAppendingString:OhrtDay(joined)]];

    NSString *account = OhrtMyAccount();
    if (account.length && ![account isEqualToString:pk]) OhrtAddHistory(facts, user, account, pk);

    NSDate *story = OhrtDate(OhrtCall(user, @"latestReelMediaDate"));
    NSTimeInterval age = story ? -story.timeIntervalSinceNow : -1;
    if (age >= 0 && age < kOhrtStoryLife) {
        char ago[24];
        OhrtAgoText(age, ago, sizeof(ago));
        [facts addObject:[@"story " stringByAppendingString:@(ago)]];
    }
    return [facts componentsJoinedByString:@", "];
}

// Whose profile a bio section belongs to.
static id OhrtFactsUser(id controller) {
    Class userClass = NSClassFromString(@"IGUser");
    id fragment = OhrtCall(OhrtIvar(controller, "_model"), @"userFragment");
    id viaScreen = OhrtCall(OhrtCall(controller, @"viewController"), @"user");
    static BOOL described;
    if (!described) {
        described = YES;
        OhrtLog(@"facts: the bio's account is a %@, the screen's a %@", fragment ? NSStringFromClass([fragment class]) : @"nothing",
                viaScreen ? NSStringFromClass([viaScreen class]) : @"nothing");
    }
    if (userClass && [fragment isKindOfClass:userClass]) return fragment;
    if (userClass && [viaScreen isKindOfClass:userClass]) return viaScreen;
    return fragment ?: viaScreen;
}

static void OhrtFactsShow(id controller, UICollectionViewCell *cell) {
    if (![cell isKindOfClass:[UICollectionViewCell class]]) return;
    NSString *line = objc_getAssociatedObject(controller, &kOhrtLineKey);
    UILabel *label = objc_getAssociatedObject(cell, &kOhrtLabelKey);
    if (!label && line) {
        label = [UILabel new];
        label.font = OhrtFactsFont();
        label.textColor = [OhrtColor(kOhrtFactsColour) colorWithAlphaComponent:kOhrtFactsFade];
        label.numberOfLines = 0;
        label.lineBreakMode = NSLineBreakByWordWrapping;
        [cell.contentView addSubview:label];
        objc_setAssociatedObject(cell, &kOhrtLabelKey, label, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    }
    label.text = line;
    label.hidden = line == nil;
    [cell setNeedsLayout];
}

// Works out the line for a bio section's account and puts it on the
// section's cell if it has one.
static void OhrtFactsRefresh(id controller) {
    NSString *line = OhrtFactsLine(OhrtFactsUser(controller));
    objc_setAssociatedObject(controller, &kOhrtLineKey, line, OBJC_ASSOCIATION_COPY_NONATOMIC);
    static BOOL said;
    if (!said && line) {
        said = YES;
        OhrtLog(@"facts: a line of %lu facts is shown", (unsigned long)[line componentsSeparatedByString:@", "].count);
    }
    id cell = OhrtIvar(controller, "_bioCell");
    if (cell) OhrtFactsShow(controller, cell);
}

%group OhrtFacts

%hook IGProfileBioSectionController
- (void)didUpdateToObject:(id)object {
    %orig;
    OhrtTry(@"facts", ^{
        OhrtFactsRefresh(self);
    });
}
- (CGSize)sizeForItemAtIndex:(NSInteger)index {
    CGSize size = %orig;
    NSString *line = objc_getAssociatedObject(self, &kOhrtLineKey);
    // Only while the line is really being drawn: a cell made taller for a
    // line that never comes would leave a gap.
    if (!line || !OhrtTry(@"facts", ^{})) return size;
    // With no bio the section is not inset, and the line insets itself.
    CGFloat width = size.height < 1 ? size.width - 2 * kOhrtFactsSide : size.width;
    size.height += OhrtFactsHeight(line, width);
    return size;
}
- (id)cellForItemAtIndex:(NSInteger)index {
    id cell = %orig;
    OhrtTry(@"facts", ^{
        OhrtFactsShow(self, cell);
    });
    return cell;
}
%end

%hook IGProfileBioCell
- (void)layoutSubviews {
    %orig;
    UILabel *label = objc_getAssociatedObject(self, &kOhrtLabelKey);
    if (!label || label.hidden) return;
    CGRect bounds = self.contentView.bounds;
    CGFloat side = self.frame.origin.x < 8 ? kOhrtFactsSide : 0;
    CGFloat width = MAX(0, bounds.size.width - 2 * side);
    CGFloat height = MIN(OhrtFactsHeight(label.text, width), bounds.size.height);
    UIView *bio = OhrtIvar(self, "_bioView");
    if ([bio isKindOfClass:[UIView class]]) {
        // Instagram has just given the bio the whole cell. It gets the
        // part under the line, which is the height it asked for.
        CGRect frame = bounds;
        frame.origin.y = height;
        frame.size.height = bounds.size.height - height;
        bio.frame = frame;
    }
    label.frame = CGRectMake(side, 0, width, MAX(0, height - kOhrtFactsGap));
}
%end

%hook IGFollowController
- (void)_didPressFollowButton {
    id user = OhrtCall(self, @"user");
    BOOL before = OhrtCallBool(user, @"followedByCurrentUser");
    %orig;
    if (!user) return;
    // The button answers at once and Instagram a moment later. What stands
    // after that moment is what happened.
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(4 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
        OhrtTry(@"facts", ^{
            BOOL after = OhrtCallBool(user, @"followedByCurrentUser");
            if (after != before) OhrtNoteFollow(OhrtMyAccount(), OhrtText(OhrtCall(user, @"pk")), after);
        });
    });
}
%end

%end

void OhrtInstallFacts(void) {
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        if (!OhrtFeatureReady(kOhrtFactsKey, @"facts")) return;
        %init(OhrtFacts);
        OhrtLog(@"facts: profiles get their line");
    });
}
