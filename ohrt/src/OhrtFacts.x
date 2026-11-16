// Facts on a profile: a line between the picture and the bio, small and
// red, of what the app holds about the account and does not show.
//
//   id 1234567890, creator, joined 2019-03-02, follows you, followed since 2026-11-16, story 3h ago
//
// Everything on the line is already in the app when the profile opens:
// nothing is asked of Instagram for it. The one thing that is not
// Instagram's is "followed since". Instagram does not say when a follow
// happened, so that is our own note, made when a follow button is pressed
// in this app, and it only knows the follows made here.
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
    if (account.length && ![account isEqualToString:pk]) {
        if (OhrtCallBool(user, @"followsCurrentUser")) [facts addObject:@"follows you"];
        NSNumber *since = OhrtCallBool(user, @"followedByCurrentUser") ? OhrtFollowDates(account)[pk] : nil;
        if (since) [facts addObject:[@"followed since " stringByAppendingString:OhrtDay([NSDate dateWithTimeIntervalSince1970:since.doubleValue])]];
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
