// Facts on a post: a line of small red text under a post's buttons, above
// who liked it and the caption, of what the app holds about the post and
// does not show.
//
//   posted 2026-11-14 18:02, made 2026-11-12 09:15 (2d before posting),
//   caption edited, 1080x1350, 98,765 plays, tagged place at 40.71280,
//   -74.00600, ai sees: 2 people, beach and text
//
// Only what Instagram does not show already, read off the post as the feed
// received it, so a fact the server did not send is left out. The one
// exception is a hidden like count, which the server does not send at all:
// that is counted from who liked the post, read when the row comes on
// screen (OhrtLikes.x).
//
// A post in the feed is one list section whose rows (header, picture,
// buttons, likes, caption, comments) come from an array its view model
// makes once, as it is made. Ours is one more row in that array, put in
// just after the buttons, with a type of its own. Every lookup of a row,
// Instagram's own included, goes through that array, so all of them agree
// on where each row is. Asked for our row's cell or size, the section
// gets ours. Everything else that looks at a row by its type passes over
// a type it does not know.
#import <objc/message.h>
#import <objc/runtime.h>

#import "Ohrt.h"
#import "OhrtLogic.h"

NSString *const kOhrtPostFactsKey = @"ohrt_post_facts";

// Instagram's numbers for the row of buttons under a post and for a row
// that holds no text (read out of -[IGFeedSectionControllerOld ufiCellIndex]).
static const int kOhrtButtonsRow = 84;
static const long long kOhrtNoText = 24;
// Ours. Instagram's own run from 0 to 88, and its code checks the range
// before it looks a type up.
static const int kOhrtPostFactsRow = 20296;

static const CGFloat kOhrtPostAbove = 0;
static const CGFloat kOhrtPostBelow = 6;
// How far in from the screen's edges, until the caption's own distance is
// known.
static const CGFloat kOhrtPostSide = 12;
static NSString *const kOhrtPostSideKey = @"ohrt_post_side";

@interface IGFeedItemTimelineViewModelImpl : NSObject
@end

@interface IGFeedSectionControllerOld : NSObject
@end

@interface IGFeedItemTextCell : UICollectionViewCell
@end

static NSNumber *OhrtPostNumber(id value) {
    return [value isKindOfClass:[NSNumber class]] ? value : nil;
}

static NSString *OhrtPostString(id value) {
    return [value isKindOfClass:[NSString class]] && [value length] ? value : nil;
}

static NSString *OhrtPostMinute(NSDate *date) {
    static NSDateFormatter *formatter;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        formatter = [NSDateFormatter new];
        formatter.locale = [NSLocale localeWithLocaleIdentifier:@"en_US_POSIX"];
        formatter.dateFormat = @"yyyy-MM-dd HH:mm";
    });
    @synchronized(formatter) {
        return [formatter stringFromDate:date];
    }
}

// "45m", "3h", "2d".
static NSString *OhrtPostSpan(NSTimeInterval seconds) {
    if (seconds < 3600) return [NSString stringWithFormat:@"%ldm", (long)(seconds / 60)];
    if (seconds < 86400) return [NSString stringWithFormat:@"%ldh", (long)(seconds / 3600)];
    return [NSString stringWithFormat:@"%ldd", (long)(seconds / 86400)];
}

// The phone's own clock when the post was put together, which the server
// keeps in seconds, milliseconds or microseconds depending on the app that
// sent it.
static NSDate *OhrtPostMade(NSNumber *stamp) {
    double value = stamp.doubleValue;
    while (value > 1e11) value /= 1000.0;
    if (value < 1262304000 || value > [NSDate date].timeIntervalSince1970 + 86400) return nil;
    return [NSDate dateWithTimeIntervalSince1970:value];
}

// What Instagram wrote describing the picture, for screen readers. Its own
// begin "Photo by <name> on <date>. May be an image of ...", and only the
// part after "of" says anything. Text the owner wrote is kept as it is.
static NSString *OhrtPostSees(NSString *caption) {
    if (!caption.length) return nil;
    NSString *text = caption;
    NSRange may = [text rangeOfString:@"May be "];
    if (may.location != NSNotFound) {
        text = [text substringFromIndex:NSMaxRange(may)];
        NSRange of = [text rangeOfString:@" of "];
        if (of.location != NSNotFound && of.location < 24) text = [text substringFromIndex:NSMaxRange(of)];
    } else if ([text hasPrefix:@"Photo by "] || [text hasPrefix:@"Photo shared by "] || [text hasPrefix:@"Video by "]) {
        return nil;
    } else {
        text = [@"alt text " stringByAppendingString:text];
    }
    text = [[text componentsSeparatedByCharactersInSet:[NSCharacterSet newlineCharacterSet]] componentsJoinedByString:@" "];
    text = [text stringByTrimmingCharactersInSet:[NSCharacterSet characterSetWithCharactersInString:@" ."]];
    if (text.length > 160) text = [[text substringToIndex:159] stringByAppendingString:@"\u2026"];
    return text.length ? text : nil;
}

static void OhrtPostSayFields(NSArray<NSString *> *fields) {
    static NSUInteger told;
    static NSObject *lock;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        lock = [NSObject new];
    });
    @synchronized(lock) {
        if (told >= 8) return;
        told++;
    }
    OhrtLog(@"post facts: a post came with %@", fields.count ? [fields componentsJoinedByString:@" "] : @"none of the fields");
}

static NSString *OhrtPostText(id media) {
    NSMutableArray<NSString *> *facts = [NSMutableArray array];
    NSMutableArray<NSString *> *fields = [NSMutableArray array];

    id taken = OhrtCallValue(media, @"takenAtDate");
    NSDate *posted = [taken isKindOfClass:[NSDate class]] ? taken : nil;
    NSNumber *takenAt = OhrtPostNumber(OhrtCallValue(media, @"takenAt"));
    if (!posted && takenAt.doubleValue > 0) posted = [NSDate dateWithTimeIntervalSince1970:takenAt.doubleValue];
    if (posted) [facts addObject:[@"posted " stringByAppendingString:OhrtPostMinute(posted)]];

    NSNumber *stamp = OhrtPostNumber(OhrtCallValue(media, @"deviceTimestamp"));
    if (stamp) [fields addObject:@"device_timestamp"];
    NSDate *made = OhrtPostMade(stamp);
    if (made && posted && [posted timeIntervalSinceDate:made] >= 10 * 60) {
        [facts addObject:[NSString stringWithFormat:@"made %@ (%@ before posting)", OhrtPostMinute(made), OhrtPostSpan([posted timeIntervalSinceDate:made])]];
    }

    if ([OhrtPostNumber(OhrtCallValue(media, @"captionIsEdited")) boolValue]) [facts addObject:@"caption edited"];

    id detection = OhrtCallValue(media, @"genAiDetectionMethod");
    if (detection) {
        [fields addObject:@"gen_ai_detection_method"];
        // How Instagram knows the post was made with AI, which is what puts
        // its "AI info" label on it: the owner said so, the file carried an
        // AI tool's marks, or Meta's own detection.
        NSString *method = OhrtPostString(OhrtCallValue(detection, @"detectionMethod"));
        if (method.length && ![method.uppercaseString isEqualToString:@"NONE"]) {
            [facts addObject:[@"ai label, found by " stringByAppendingString:[method.lowercaseString stringByReplacingOccurrencesOfString:@"_" withString:@" "]]];
        }
    }

    NSNumber *width = OhrtPostNumber(OhrtCallValue(media, @"originalWidth")), *height = OhrtPostNumber(OhrtCallValue(media, @"originalHeight"));
    if (width.integerValue > 0 && height.integerValue > 0) [facts addObject:[NSString stringWithFormat:@"%ldx%ld", (long)width.integerValue, (long)height.integerValue]];

    if ([OhrtPostNumber(OhrtCallValue(media, @"hasSharedToFb")) integerValue] > 0) [facts addObject:@"also on facebook"];

    NSArray<NSArray *> *counts = @[
        @[ @"igPlayCount", @"play", @"plays" ],
        @[ @"viewCount", @"view", @"views" ],
        @[ @"saveCount", @"save", @"saves" ],
        @[ @"fbLikeCount", @"facebook like", @"facebook likes" ],
        @[ @"fbPlayCount", @"facebook play", @"facebook plays" ],
    ];
    for (NSArray *count in counts) {
        NSNumber *value = OhrtPostNumber(OhrtCallValue(media, count[0]));
        if (!value) continue;
        [fields addObject:count[0]];
        if (value.longLongValue <= 0) continue;
        [facts addObject:[NSString stringWithFormat:@"%@ %@", OhrtGrouped(value.longLongValue), value.longLongValue == 1 ? count[1] : count[2]]];
    }
    if (!OhrtPostNumber(OhrtCallValue(media, @"igPlayCount"))) {
        NSNumber *plays = OhrtPostNumber(OhrtCallValue(media, @"playCount"));
        if (plays.longLongValue > 0) [facts addObject:[NSString stringWithFormat:@"%@ %@", OhrtGrouped(plays.longLongValue), plays.longLongValue == 1 ? @"play" : @"plays"]];
    }

    NSNumber *lat = OhrtPostNumber(OhrtCallValue(media, @"lat")), *lng = OhrtPostNumber(OhrtCallValue(media, @"lng"));
    if (lat && lng && (lat.doubleValue != 0 || lng.doubleValue != 0)) {
        [fields addObject:@"lat_lng"];
        // The place the post is tagged with, not where the picture was taken:
        // Instagram strips that from the file.
        [facts addObject:[NSString stringWithFormat:@"tagged place at %.5f, %.5f", lat.doubleValue, lng.doubleValue]];
    }

    NSString *caption = OhrtPostString(OhrtCallValue(media, @"accessibilityCaption"));
    if (caption) [fields addObject:@"accessibility_caption"];
    NSString *sees = OhrtPostSees(caption);
    if (sees) [facts addObject:[sees hasPrefix:@"alt text "] ? sees : [@"ai sees: " stringByAppendingString:sees]];

    OhrtPostSayFields(fields);
    return facts.count ? [facts componentsJoinedByString:@", "] : nil;
}

// The side distance of the caption under a post, which ours matches. Read
// off Instagram's caption cell the first time one is laid out, and kept.
static CGFloat gOhrtPostSide;

static CGFloat OhrtPostSide(void) {
    if (gOhrtPostSide > 0) return gOhrtPostSide;
    double kept = [[NSUserDefaults standardUserDefaults] doubleForKey:kOhrtPostSideKey];
    gOhrtPostSide = kept >= 4 && kept <= 40 ? kept : kOhrtPostSide;
    return gOhrtPostSide;
}

// What our row shows: the facts made with it, after a hidden like count
// once it has been counted from who liked the post (OhrtLikes.x), which
// can happen while the row is on screen.
static char kOhrtRowMediaKey;
static char kOhrtRowHiddenKey;

static NSString *OhrtPostLikesFact(long long count, BOOL more) {
    return [NSString stringWithFormat:@"%@%@ %@ (hidden)", more ? @"at least " : @"", OhrtGrouped(count), count == 1 && !more ? @"like" : @"likes"];
}

static NSString *OhrtPostJoined(NSString *likes, NSString *base) {
    if (!likes) return base;
    return base.length ? [NSString stringWithFormat:@"%@, %@", likes, base] : likes;
}

static NSString *OhrtPostShown(id row) {
    NSString *base = OhrtPostString(OhrtCall(row, @"value"));
    if (![objc_getAssociatedObject(row, &kOhrtRowHiddenKey) boolValue]) return base;
    NSString *mediaId = objc_getAssociatedObject(row, &kOhrtRowMediaKey);
    long long count = 0;
    BOOL more = NO;
    if (OhrtLikesCountedNumber(mediaId, &count, &more)) return OhrtPostJoined(OhrtPostLikesFact(count, more), base);
    return OhrtPostJoined(OhrtLikesPending(mediaId) ? @"counting hidden likes\u2026" : nil, base);
}

static CGFloat OhrtPostTextHeight(NSString *text, CGFloat width) {
    if (!text.length || !(width >= 40)) return 0;
    static NSCache<NSString *, NSNumber *> *heights;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        heights = [NSCache new];
        heights.countLimit = 400;
    });
    NSString *key = [NSString stringWithFormat:@"%.1f %@", width, text];
    NSNumber *known = [heights objectForKey:key];
    if (known) return known.doubleValue;
    CGRect box = [text boundingRectWithSize:CGSizeMake(width, CGFLOAT_MAX)
                                    options:NSStringDrawingUsesLineFragmentOrigin | NSStringDrawingUsesFontLeading
                                 attributes:@{NSFontAttributeName : OhrtFactsLineFont()}
                                    context:nil];
    CGFloat height = ceil(box.size.height);
    [heights setObject:@(height) forKey:key];
    return height;
}

@interface OhrtPostFactsCell : UICollectionViewCell
@property (nonatomic, strong) UILabel *label;
@property (nonatomic, copy) NSString *mediaId;
@property (nonatomic, strong) id row;
@property (nonatomic, weak) id controller;
// A hidden like count that has just come in runs up to its number.
@property (nonatomic, strong) CADisplayLink *ticker;
@property (nonatomic) CFTimeInterval tickStart;
@property (nonatomic) long long tickTarget;
@property (nonatomic) BOOL tickMore;
@end

static const CFTimeInterval kOhrtTickTime = 0.9;

// Cells on screen, to update when a hidden like count comes in.
static NSHashTable<OhrtPostFactsCell *> *gOhrtPostCells;

@implementation OhrtPostFactsCell

- (instancetype)initWithFrame:(CGRect)frame {
    if ((self = [super initWithFrame:frame])) {
        _label = [UILabel new];
        _label.font = OhrtFactsLineFont();
        _label.textColor = OhrtFactsLineColour();
        _label.numberOfLines = 0;
        _label.lineBreakMode = NSLineBreakByWordWrapping;
        [self.contentView addSubview:_label];
    }
    return self;
}

- (void)tickTo:(long long)count more:(BOOL)more {
    [self stopTicking];
    self.tickTarget = count;
    self.tickMore = more;
    self.tickStart = CACurrentMediaTime();
    self.ticker = [CADisplayLink displayLinkWithTarget:self selector:@selector(tick:)];
    [self.ticker addToRunLoop:[NSRunLoop mainRunLoop] forMode:NSRunLoopCommonModes];
    [self tick:self.ticker];
}

- (void)tick:(CADisplayLink *)link {
    double progress = MIN(1.0, (CACurrentMediaTime() - self.tickStart) / kOhrtTickTime);
    double eased = 1 - pow(1 - progress, 3);
    long long now = progress >= 1 ? self.tickTarget : (long long)llround(self.tickTarget * eased);
    self.label.text = OhrtPostJoined(OhrtPostLikesFact(now, self.tickMore && progress >= 1), OhrtPostString(OhrtCall(self.row, @"value")));
    if (progress >= 1) [self stopTicking];
}

- (void)stopTicking {
    [self.ticker invalidate];
    self.ticker = nil;
}

- (void)prepareForReuse {
    [super prepareForReuse];
    [self stopTicking];
}

- (void)layoutSubviews {
    [super layoutSubviews];
    CGRect bounds = self.contentView.bounds;
    CGFloat side = OhrtPostSide();
    self.label.frame = CGRectMake(side, kOhrtPostAbove, MAX(0, bounds.size.width - 2 * side), MAX(0, bounds.size.height - kOhrtPostAbove - kOhrtPostBelow));
}

@end

// Asked for every row of every post, so kept cheap.
static id OhrtPostRowAt(id controller, NSInteger index) {
    static SEL rowAt, type;
    static Class rowClass;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        rowAt = NSSelectorFromString(@"rowForCellAtIndex:");
        type = NSSelectorFromString(@"type");
        rowClass = NSClassFromString(@"IGFeedItemRow");
    });
    if (![controller respondsToSelector:rowAt]) return nil;
    id row = ((id (*)(id, SEL, NSInteger))objc_msgSend)(controller, rowAt, index);
    if (!rowClass || ![row isKindOfClass:rowClass] || ((int (*)(id, SEL))objc_msgSend)(row, type) != kOhrtPostFactsRow) return nil;
    return row;
}

static CGFloat OhrtPostWidth(id controller) {
    id context = OhrtCall(controller, @"collectionContext");
    SEL inset = NSSelectorFromString(@"insetContainerSize");
    CGFloat width = [context respondsToSelector:inset] ? ((CGSize (*)(id, SEL))objc_msgSend)(context, inset).width : 0;
    return width >= 100 ? width : [UIScreen mainScreen].bounds.size.width;
}

// Puts our row after the buttons in a post's rows, once, as the view model
// is made.
static void OhrtPostAddRow(id model, id media) {
    if (!media || OhrtCallBool(media, @"isSponsored")) return;
    Ivar ivar = class_getInstanceVariable([model class], "_rowItems");
    Class rowClass = NSClassFromString(@"IGFeedItemRow");
    if (!ivar || !rowClass) return;
    NSArray *rows = object_getIvar(model, ivar);
    if (![rows isKindOfClass:[NSArray class]] || !rows.count) return;
    SEL typeSel = NSSelectorFromString(@"type"), textTypeSel = NSSelectorFromString(@"textType");
    NSUInteger buttons = NSNotFound;
    for (NSUInteger index = 0; index < rows.count; index++) {
        id row = rows[index];
        if (![row respondsToSelector:typeSel] || ![row respondsToSelector:textTypeSel]) return;
        int type = ((int (*)(id, SEL))objc_msgSend)(row, typeSel);
        if (type == kOhrtPostFactsRow) return;
        if (type == kOhrtButtonsRow && ((long long (*)(id, SEL))objc_msgSend)(row, textTypeSel) == kOhrtNoText && buttons == NSNotFound) buttons = index;
    }
    if (buttons == NSNotFound) {
        static BOOL said;
        if (!said) OhrtLog(@"post facts: a post had no row of buttons to go under");
        said = YES;
        return;
    }
    NSString *text = OhrtPostText(media);
    BOOL hidden = OhrtFeature(kOhrtLikesKey) && [OhrtPostNumber(OhrtCallValue(media, @"likeAndViewCountsDisabled")) boolValue];
    if (!text.length && !hidden) return;
    SEL make = NSSelectorFromString(@"initWithType:textType:value:");
    if (![rowClass instancesRespondToSelector:make]) return;
    id ours = ((id (*)(id, SEL, int, long long, id))objc_msgSend)([rowClass alloc], make, kOhrtPostFactsRow, kOhrtNoText, text ?: @"");
    if (!ours) return;
    if (hidden) {
        objc_setAssociatedObject(ours, &kOhrtRowHiddenKey, @YES, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        objc_setAssociatedObject(ours, &kOhrtRowMediaKey, OhrtMediaId(media), OBJC_ASSOCIATION_COPY_NONATOMIC);
        OhrtLikesDescribe(media);
    }
    NSMutableArray *with = [rows mutableCopy];
    [with insertObject:ours atIndex:buttons + 1];
    object_setIvarWithStrongDefault(model, ivar, [with copy]);
    static BOOL said;
    if (!said) {
        said = YES;
        OhrtLog(@"post facts: %lu facts go in at row %lu of %lu", (unsigned long)(text.length ? [text componentsSeparatedByString:@", "].count : 0), (unsigned long)(buttons + 1), (unsigned long)rows.count);
    }
}

%group OhrtPostFacts

%hook IGFeedItemTimelineViewModelImpl
- (id)initWithMedia:(id)media configuration:(id)configuration feedConfiguration:(id)feedConfiguration userSession:(id)userSession showAYMFCellBelowHeader:(BOOL)aymf showInlineComposer:(BOOL)composer showRowStyleCTA:(BOOL)rowCTA isDelayedRowCTAVisible:(BOOL)delayedCTA showWYTSurvey:(BOOL)survey isMLEXPreview:(BOOL)preview coauthorRowType:(unsigned long long)coauthor shouldShowAdsFeedbackInterface:(BOOL)adsFeedback shouldShowAdsFeedbackInterfaceRepetition:(BOOL)adsRepetition afiInterestsPickerState:(long long)afiState leadGenInterestPickerCellViewState:(long long)leadGenState shouldShowInjectedFeedUnit:(BOOL)injected shouldShowInlineCommentPreview:(BOOL)commentPreview shouldLogRowTypes:(BOOL)logRows shouldHideHeaderRow:(BOOL)hideHeader shouldShowOnImpressionControl:(BOOL)impressionControl showDelaySkipAdNUX:(BOOL)skipAd isFloatingSocialContextDismissed:(BOOL)socialDismissed shouldExpandCTAVertically:(BOOL)expandCTA showDelaySkipAdPersistentTombstone:(BOOL)tombstone shouldShowHIDEntryPoint:(BOOL)hid shouldShowChainingTopicTray:(BOOL)chaining shouldShowSponsoredLabelInFooter:(BOOL)sponsoredLabel shouldRenderDestinationInfoAttachement:(BOOL)destination commercePageEligibleModules:(id)commerce {
    id model = %orig;
    if (model) {
        OhrtTry(@"post facts", ^{
            OhrtPostAddRow(model, media);
        });
    }
    return model;
}
%end

%hook IGFeedSectionControllerOld
- (CGSize)sizeForItemAtIndex:(NSInteger)index {
    __block id row = nil;
    OhrtTry(@"post facts", ^{
        row = OhrtPostRowAt(self, index);
    });
    if (!row) return %orig;
    CGFloat width = OhrtPostWidth(self);
    CGFloat height = OhrtPostTextHeight(OhrtPostShown(row), width - 2 * OhrtPostSide());
    return CGSizeMake(width, height > 0 ? kOhrtPostAbove + height + kOhrtPostBelow : 0.01);
}

- (id)cellForItemAtIndex:(NSInteger)index {
    __block id row = nil;
    OhrtTry(@"post facts", ^{
        row = OhrtPostRowAt(self, index);
    });
    if (!row) return %orig;
    id context = OhrtCall(self, @"collectionContext");
    SEL dequeue = NSSelectorFromString(@"dequeueReusableCellOfClass:forSectionController:atIndex:");
    if (![context respondsToSelector:dequeue]) return %orig;
    OhrtPostFactsCell *cell = ((id (*)(id, SEL, Class, id, NSInteger))objc_msgSend)(context, dequeue, [OhrtPostFactsCell class], self, index);
    if ([cell isKindOfClass:[OhrtPostFactsCell class]]) {
        cell.mediaId = objc_getAssociatedObject(row, &kOhrtRowMediaKey);
        // The post is on screen: its hidden likes are read now, ahead of
        // any waiting.
        if (cell.mediaId && !OhrtLikesCountedFor(cell.mediaId)) OhrtLikesWant(cell.mediaId);
        cell.label.text = OhrtPostShown(row);
        cell.row = row;
        cell.controller = self;
        if (!gOhrtPostCells) gOhrtPostCells = [NSHashTable weakObjectsHashTable];
        [gOhrtPostCells addObject:cell];
        [cell setNeedsLayout];
    }
    return cell;
}

- (void)didSelectItemAtIndex:(NSInteger)index {
    if (OhrtPostRowAt(self, index)) return;
    %orig;
}

// The kind of row Instagram logs a row as. Ours is logged as the buttons
// above it, so that nothing goes out naming a row it does not know.
- (id)analyticsItemTypeAtIndex:(NSInteger)index {
    if (index > 0 && OhrtPostRowAt(self, index)) return %orig(index - 1);
    return %orig;
}
%end

%hook IGFeedItemTextCell
- (void)layoutSubviews {
    %orig;
    static BOOL kept;
    if (kept) return;
    Ivar ivar = class_getInstanceVariable([self class], "_leftPadding");
    if (!ivar || strcmp(ivar_getTypeEncoding(ivar), "d") != 0) return;
    double padding = *(double *)((uint8_t *)(__bridge void *)self + ivar_getOffset(ivar));
    if (!(padding >= 4 && padding <= 40)) return;
    kept = YES;
    if (fabs(padding - OhrtPostSide()) > 0.1) OhrtLog(@"post facts: the caption sits %.1f in from the side", padding);
    gOhrtPostSide = padding;
    [[NSUserDefaults standardUserDefaults] setDouble:padding forKey:kOhrtPostSideKey];
}
%end

%end

void OhrtInstallPostFacts(void) {
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        if (!OhrtFeatureReady(kOhrtPostFactsKey, @"postfacts")) return;
        %init(OhrtPostFacts);
        // Posted on the main thread by OhrtLikes.x.
        [[NSNotificationCenter defaultCenter] addObserverForName:kOhrtLikesCountedNotification object:nil queue:nil usingBlock:^(NSNotification *note) {
            OhrtTry(@"post facts", ^{
                for (OhrtPostFactsCell *cell in gOhrtPostCells.allObjects) {
                    if (!cell.mediaId || ![cell.mediaId isEqual:note.object]) continue;
                    long long count = 0;
                    BOOL more = NO;
                    if (cell.window && [cell.label.text hasPrefix:@"counting hidden likes"] && OhrtLikesCountedNumber(cell.mediaId, &count, &more)) [cell tickTo:count more:more];
                    else cell.label.text = OhrtPostShown(cell.row);
                    [cell setNeedsLayout];
                    id controller = cell.controller;
                    id context = OhrtCall(controller, @"collectionContext");
                    SEL invalidate = NSSelectorFromString(@"invalidateLayoutForSectionController:completion:");
                    if ([context respondsToSelector:invalidate]) ((void (*)(id, SEL, id, id))objc_msgSend)(context, invalidate, controller, nil);
                }
            });
        }];
    });
}
