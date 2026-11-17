// "About you": what Instagram keeps on this phone about you and does not
// show. Three things, all read from the app's own memory with nothing asked
// of Instagram:
//  - the profile of how you use the app that comes with the feed and is
//    kept in the session's defaults under "personalization_features": about
//    a hundred numbers and labels, such as a predicted age, a reels cohort,
//    the time spent and the rates at which you like and share;
//  - how many minutes Instagram's on-device model reckons it will be until
//    you next open the app (IGCasper), asked as the screen appears;
//  - the accounts with the highest bestie_coefficient, the score its servers
//    give each account you might want to reach.
// A value Instagram left at -1 is one it did not fill, and is left out.
//
// The screen is drawn as a terminal program would draw it: one size of
// monospaced type on a grid of 56 columns, boxes with their titles in the
// border, and meters made of dots, in the colours of Oliver's btop theme.
// Nothing else in the app is styled this way.
#import <objc/message.h>
#import <objc/runtime.h>

#import "Ohrt.h"

static id OhrtAboutIvar(id object, const char *name) {
    Ivar ivar = object ? class_getInstanceVariable([object class], name) : NULL;
    if (!ivar) return nil;
    const char *type = ivar_getTypeEncoding(ivar);
    return type && type[0] == '@' ? object_getIvar(object, ivar) : nil;
}

static NSDictionary *OhrtAboutFeatures(NSDate **when) {
    id defaults = OhrtCall(OhrtCurrentSession(), @"sessionUserDefaults");
    if (![defaults respondsToSelector:@selector(objectForKey:)]) return nil;
    id kept = ((id (*)(id, SEL, id))objc_msgSend)(defaults, @selector(objectForKey:), @"personalization_features");
    if ([kept isKindOfClass:[NSData class]]) kept = [NSJSONSerialization JSONObjectWithData:kept options:0 error:nil];
    if (![kept isKindOfClass:[NSDictionary class]]) return nil;
    // Kept in seconds since 2001, as Apple's dates are.
    id stamp = kept[@"timestamp"];
    if (when && [stamp isKindOfClass:[NSNumber class]]) *when = [NSDate dateWithTimeIntervalSinceReferenceDate:[stamp doubleValue]];
    id features = kept[@"features"];
    return [features isKindOfClass:[NSDictionary class]] ? features : nil;
}

static BOOL OhrtAboutFilled(id value) {
    if ([value isKindOfClass:[NSNumber class]]) return [value doubleValue] != -1;
    return [value isKindOfClass:[NSString class]] && [value length];
}

static NSString *OhrtAboutNumber(id value) {
    if ([value isKindOfClass:[NSString class]]) return value;
    double number = [value doubleValue];
    if (number == floor(number) && fabs(number) < 1e15) return OhrtGrouped((long long)number);
    // No exponents: one decimal on a large number, up to four on a small
    // one with the zeros at its end left off.
    if (fabs(number) >= 100 && fabs(number) < 1e15) {
        long long tenths = llround(fabs(number) * 10);
        return [NSString stringWithFormat:@"%@%@.%lld", number < 0 ? @"-" : @"", OhrtGrouped(tenths / 10), tenths % 10];
    }
    NSString *text = [NSString stringWithFormat:@"%.4f", number];
    while ([text hasSuffix:@"0"]) text = [text substringToIndex:text.length - 1];
    return [text hasSuffix:@"."] ? [text stringByAppendingString:@"0"] : text;
}

static NSString *OhrtAboutTime(id value) {
    long long seconds = [value longLongValue];
    if (seconds < 3600) return [NSString stringWithFormat:@"%lldm", seconds / 60];
    return [NSString stringWithFormat:@"%lldh %lldm", seconds / 3600, (seconds % 3600) / 60];
}

static NSString *OhrtAboutRate(id value) {
    return [NSString stringWithFormat:@"%.1f%%", [value doubleValue] * 100];
}

// The codes Instagram's own gender setting posts: its picker offers 1, 2, 4
// and 3, with words of your own only for 4.
static NSString *OhrtAboutGender(id value) {
    NSDictionary<NSNumber *, NSString *> *names = @{@1 : @"male", @2 : @"female", @3 : @"prefer not to say", @4 : @"custom"};
    NSString *name = [value isKindOfClass:[NSNumber class]] ? names[@([value integerValue])] : nil;
    return name ?: OhrtAboutNumber(value);
}

static NSString *OhrtAboutYesNo(id value) {
    return [value isKindOfClass:[NSNumber class]] ? ([value boolValue] ? @"yes" : @"no") : OhrtAboutNumber(value);
}

static NSString *OhrtAboutBytes(id value) {
    return [NSString stringWithFormat:@"%.1f GB", [value doubleValue] / 1e9];
}

static NSString *OhrtAboutOf28(id value) {
    return [OhrtAboutNumber(value) stringByAppendingString:@"/28"];
}

typedef NSString * (*OhrtAboutFormat)(id);

static NSString *const kOhrtAboutBestiesKey = @"ohrt_about_besties";
static const NSUInteger kOhrtAboutScoresWait = 60;

enum {
    kOhrtAboutBack = 0x11111b,
    kOhrtAboutBorder = 0x5a5a5a,
    kOhrtAboutDim = 0x6c6c6c,
    kOhrtAboutText = 0xbcbcbc,
    kOhrtAboutWhite = 0xffffff,
    kOhrtAboutIndex = 0xf05050,
    kOhrtAboutQuietRed = 0xd9626d,
    kOhrtAboutName = 0x77ca9b,
    kOhrtAboutOff = 0x2d2d3a,
    kOhrtAboutDivide = 0x333340,
};

typedef NS_ENUM(NSInteger, OhrtAboutKind) {
    OhrtAboutKindLine,
    OhrtAboutKindGrid,
    OhrtAboutKindRates,
    OhrtAboutKindRanked,
    OhrtAboutKindRaw,
};

static UIColor *OhrtAboutHex(uint32_t hex) {
    return [UIColor colorWithRed:((hex >> 16) & 255) / 255.0 green:((hex >> 8) & 255) / 255.0 blue:(hex & 255) / 255.0 alpha:1];
}

static uint32_t OhrtAboutMix(uint32_t one, uint32_t other, double part) {
    uint32_t mixed = 0;
    for (int shift = 16; shift >= 0; shift -= 8) {
        double from = (one >> shift) & 255, to = (other >> shift) & 255;
        mixed |= (uint32_t)lround(from + (to - from) * part) << shift;
    }
    return mixed;
}

static NSString *OhrtAboutFit(NSString *text, NSInteger width) {
    if (width < 1) return @"";
    if ((NSInteger)text.length <= width) return text;
    return [[text substringToIndex:width - 1] stringByAppendingString:@"…"];
}

@interface OhrtAboutRow : NSObject
@property (nonatomic, copy) NSString *label, *value, *about;
// For a meter: how much of it is lit, from 0 to 1.
@property (nonatomic) double part;
// For a ranked row: its place in the list, from 1.
@property (nonatomic) NSUInteger place;
@end

@implementation OhrtAboutRow
@end

@interface OhrtAboutBox : NSObject
@property (nonatomic) OhrtAboutKind kind;
// `note` sits at the right of the top border, `foot` at the right of the
// bottom one, and `under` is a dim line below the rows.
@property (nonatomic, copy) NSString *title, *note, *foot, *under;
@property (nonatomic, copy) NSArray<OhrtAboutRow *> *rows;
// Its values are not here yet: the rows hold their places, empty.
@property (nonatomic) BOOL loading;
@end

@implementation OhrtAboutBox
@end

static const NSInteger kOhrtAboutColumns = 56;
static const CGFloat kOhrtAboutSide = 5, kOhrtAboutTop = 8;

@interface OhrtAboutPage : UIView
@property (nonatomic, copy) NSArray<OhrtAboutBox *> *boxes;
@property (nonatomic, copy) void (^tapped)(OhrtAboutRow *row);
// The label of the row whose explanation is open, which is drawn lit.
@property (nonatomic, copy) NSString *selected;
- (CGFloat)heightForWidth:(CGFloat)width;
- (CGRect)areaOfRowLabelled:(NSString *)label;
@end

static const CFTimeInterval kOhrtAboutFill = 0.8;

@implementation OhrtAboutPage {
    CGFloat _cw, _ch;
    UIFont *_plain, *_bold;
    NSMutableArray<NSArray *> *_hits;
    BOOL _hitsStale;
    // When each box with meters began to fill, by its title.
    NSMutableDictionary<NSString *, NSNumber *> *_began;
    CADisplayLink *_link;
}

static UIFont *OhrtAboutFont(CGFloat advance, UIFontWeight weight) {
    UIFont *probe = [UIFont monospacedSystemFontOfSize:100 weight:weight];
    CGFloat wide = [@"0" sizeWithAttributes:@{NSFontAttributeName : probe}].width;
    return [UIFont monospacedSystemFontOfSize:wide > 0 ? 100 * advance / wide : 11 weight:weight];
}

- (void)measure:(CGFloat)width {
    CGFloat cw = (width - 2 * kOhrtAboutSide) / kOhrtAboutColumns;
    if (cw == _cw && _plain) return;
    _cw = cw;
    CGFloat scale = [UIScreen mainScreen].scale;
    _ch = round(cw * 17 / 7 * scale) / scale;
    _plain = OhrtAboutFont(cw, UIFontWeightRegular);
    _bold = OhrtAboutFont(cw, UIFontWeightBold);
    _hitsStale = YES;
}

- (NSInteger)linesIn:(OhrtAboutBox *)box {
    if (box.kind == OhrtAboutKindGrid) return (box.rows.count + 1) / 2;
    return box.rows.count + (box.under.length ? 1 : 0);
}

- (CGFloat)heightForWidth:(CGFloat)width {
    [self measure:width];
    NSInteger lines = 2;
    for (OhrtAboutBox *box in self.boxes) lines += [self linesIn:box] + 2;
    return kOhrtAboutTop + lines * _ch + 12;
}

- (CGFloat)x:(NSInteger)column {
    return kOhrtAboutSide + column * _cw;
}

- (CGFloat)y:(NSInteger)row {
    return kOhrtAboutTop + row * _ch;
}

- (BOOL)fills:(OhrtAboutBox *)box {
    return box.kind == OhrtAboutKindRates || box.kind == OhrtAboutKindRanked;
}

- (CGRect)areaOfBox:(OhrtAboutBox *)wanted {
    NSInteger row = 2;
    for (OhrtAboutBox *box in self.boxes) {
        NSInteger lines = [self linesIn:box];
        if (box == wanted) return CGRectMake(0, [self y:row], self.bounds.size.width, (lines + 2) * _ch);
        row += lines + 2;
    }
    return CGRectZero;
}

// A box with meters fills from empty the first time its values are shown,
// and again if they were not there at first.
- (void)setBoxes:(NSArray<OhrtAboutBox *> *)boxes {
    _boxes = [boxes copy];
    _hitsStale = YES;
    if (!_began) _began = [NSMutableDictionary dictionary];
    BOOL filling = NO;
    for (OhrtAboutBox *box in _boxes) {
        if (![self fills:box]) continue;
        if (box.loading) {
            [_began removeObjectForKey:box.title];
        } else if (!_began[box.title]) {
            _began[box.title] = @(CACurrentMediaTime());
            filling = YES;
        }
    }
    if (filling) [self startFilling];
    [self setNeedsDisplay];
}

- (void)startFilling {
    if (!self.window || _link) return;
    _link = [CADisplayLink displayLinkWithTarget:self selector:@selector(fill)];
    [_link addToRunLoop:[NSRunLoop mainRunLoop] forMode:NSRunLoopCommonModes];
}

- (double)filledOf:(OhrtAboutBox *)box {
    NSNumber *began = _began[box.title];
    if (box.loading) return 0;
    if (!began || !_link) return 1;
    double along = MIN(1, MAX(0, (CACurrentMediaTime() - began.doubleValue) / kOhrtAboutFill));
    return 1 - pow(1 - along, 3);
}

- (void)fill {
    BOOL more = NO;
    CFTimeInterval now = CACurrentMediaTime();
    for (OhrtAboutBox *box in self.boxes) {
        NSNumber *began = _began[box.title];
        if (![self fills:box] || box.loading || !began) continue;
        // One frame past the end, so the last one drawn is the full one.
        if (now - began.doubleValue > kOhrtAboutFill + 0.1) continue;
        more = YES;
        [self setNeedsDisplayInRect:[self areaOfBox:box]];
    }
    if (more) return;
    [_link invalidate];
    _link = nil;
    [self setNeedsDisplay];
}

// Each time the page comes on screen its meters fill again.
- (void)didMoveToWindow {
    [super didMoveToWindow];
    if (!self.window) {
        [_link invalidate];
        _link = nil;
        return;
    }
    for (OhrtAboutBox *box in self.boxes) {
        if ([self fills:box] && !box.loading) _began[box.title] = @(CACurrentMediaTime());
    }
    if (_began.count) [self startFilling];
    [self setNeedsDisplay];
}

- (void)setSelected:(NSString *)selected {
    if (selected == _selected || [selected isEqualToString:_selected]) return;
    _selected = [selected copy];
    [self setNeedsDisplay];
}

- (CGRect)areaOfRowLabelled:(NSString *)label {
    for (NSArray *hit in _hits) {
        if ([((OhrtAboutRow *)hit[1]).label isEqualToString:label]) return [hit[0] CGRectValue];
    }
    return CGRectZero;
}

- (void)put:(NSString *)text row:(NSInteger)row column:(NSInteger)column colour:(uint32_t)colour bold:(BOOL)bold {
    if (!text.length) return;
    UIFont *font = bold ? _bold : _plain;
    [text drawAtPoint:CGPointMake([self x:column], [self y:row] + (_ch - font.lineHeight) / 2) withAttributes:@{NSFontAttributeName : font, NSForegroundColorAttributeName : OhrtAboutHex(colour)}];
}

- (void)put:(NSString *)text row:(NSInteger)row end:(NSInteger)end colour:(uint32_t)colour bold:(BOOL)bold {
    [self put:text row:row column:end - (NSInteger)text.length colour:colour bold:bold];
}

// A label at `column` and its value ending before `column + width`.
- (void)pair:(OhrtAboutRow *)item row:(NSInteger)row column:(NSInteger)column width:(NSInteger)width label:(uint32_t)label value:(uint32_t)colour bold:(BOOL)bold {
    NSString *value = OhrtAboutFit([item.value stringByReplacingOccurrencesOfString:@"_" withString:@" "], width - 4);
    [self put:OhrtAboutFit(item.label, width - (NSInteger)value.length - (value.length ? 1 : 0)) row:row column:column colour:label bold:NO];
    [self put:value row:row end:column + width colour:colour bold:bold];
}

// btop's meters are braille: each cell is two columns of four dots. They
// are drawn as dots here, since the phone's monospaced face borrows its
// braille from another one of a different width.
- (void)meter:(double)part row:(NSInteger)row column:(NSInteger)column cells:(NSInteger)cells colours:(const uint32_t *)stops count:(int)count {
    NSInteger total = cells * 2, lit = part > 0 ? MAX(1, (NSInteger)lround(MIN(1, part) * total)) : 0;
    CGContextRef context = UIGraphicsGetCurrentContext();
    CGFloat radius = _cw * 0.15;
    for (NSInteger dot = 0; dot < total; dot++) {
        uint32_t colour = kOhrtAboutOff;
        if (dot < lit) {
            double along = total > 1 ? (double)dot / (total - 1) : 0;
            if (count == 1) colour = stops[0];
            else colour = along < 0.5 ? OhrtAboutMix(stops[0], stops[1], along * 2) : OhrtAboutMix(stops[1], stops[2], (along - 0.5) * 2);
        }
        CGContextSetFillColorWithColor(context, OhrtAboutHex(colour).CGColor);
        CGFloat x = [self x:column + dot / 2] + _cw * (dot % 2 ? 0.75 : 0.25);
        for (int down = 0; down < 4; down++) {
            CGFloat y = [self y:row] + _ch * (0.2 + 0.2 * down);
            CGContextFillEllipseInRect(context, CGRectMake(x - radius, y - radius, radius * 2, radius * 2));
        }
    }
}

- (void)frame:(OhrtAboutBox *)box index:(NSUInteger)index from:(NSInteger)first to:(NSInteger)last {
    CGFloat left = [self x:0] + _cw / 2, right = [self x:kOhrtAboutColumns - 1] + _cw / 2;
    CGFloat top = [self y:first] + _ch / 2, bottom = [self y:last] + _ch / 2, round = 4;
    UIBezierPath *path = [UIBezierPath bezierPath];
    path.lineWidth = 1;
    for (int side = 0; side < 2; side++) {
        CGFloat x = side ? right : left, inward = side ? -round : round;
        [path moveToPoint:CGPointMake(x + inward, top)];
        [path addQuadCurveToPoint:CGPointMake(x, top + round) controlPoint:CGPointMake(x, top)];
        [path addLineToPoint:CGPointMake(x, bottom - round)];
        [path addQuadCurveToPoint:CGPointMake(x + inward, bottom) controlPoint:CGPointMake(x, bottom)];
    }
    NSString *title = [NSString stringWithFormat:@"%lu%@", (unsigned long)index, box.title];
    NSInteger noteAt = kOhrtAboutColumns - 2 - (NSInteger)box.note.length, footAt = kOhrtAboutColumns - 2 - (NSInteger)box.foot.length;
    // The top line, broken where the title and the note are written into it.
    CGFloat x = left + round;
    [path moveToPoint:CGPointMake(x, top)];
    [path addLineToPoint:CGPointMake([self x:2] - 1, top)];
    x = [self x:2 + (NSInteger)title.length] + 1;
    if (box.note.length) {
        [path moveToPoint:CGPointMake(x, top)];
        [path addLineToPoint:CGPointMake([self x:noteAt] - 1, top)];
        x = [self x:kOhrtAboutColumns - 2] + 1;
    }
    [path moveToPoint:CGPointMake(x, top)];
    [path addLineToPoint:CGPointMake(right - round, top)];
    x = left + round;
    if (box.foot.length) {
        [path moveToPoint:CGPointMake(x, bottom)];
        [path addLineToPoint:CGPointMake([self x:footAt] - 1, bottom)];
        x = [self x:kOhrtAboutColumns - 2] + 1;
    }
    [path moveToPoint:CGPointMake(x, bottom)];
    [path addLineToPoint:CGPointMake(right - round, bottom)];
    [OhrtAboutHex(kOhrtAboutBorder) setStroke];
    [path stroke];
    [self put:[title substringToIndex:title.length - box.title.length] row:first column:2 colour:kOhrtAboutIndex bold:YES];
    [self put:box.title row:first column:2 + (NSInteger)(title.length - box.title.length) colour:kOhrtAboutWhite bold:YES];
    [self put:box.note row:first column:noteAt colour:kOhrtAboutDim bold:NO];
    [self put:box.foot row:last column:footAt colour:kOhrtAboutDim bold:NO];
}

// Only the boxes the rectangle touches are drawn, so that one box filling
// does not redraw the page. Where each row is, for taps, is worked out for
// the whole page whenever its rows or its width change.
- (void)drawRect:(CGRect)rect {
    [self measure:self.bounds.size.width];
    BOOL collect = _hitsStale || !_hits;
    if (collect) _hits = [NSMutableArray array];
    _hitsStale = NO;
    const NSInteger columns = kOhrtAboutColumns, inner = columns - 4, middle = columns / 2;
    if (CGRectGetMinY(rect) < [self y:1]) {
        [self put:@"hidden account data" row:0 column:1 colour:kOhrtAboutWhite bold:YES];
        [self put:[@"ohrtstagram " stringByAppendingString:OHRT_VERSION] row:0 end:columns - 1 colour:kOhrtAboutDim bold:NO];
    }
    static const uint32_t rates[] = {0xf05050, 0xff40b6, 0x4897d4, 0x50f095, 0xf0c050};
    static const uint32_t close[] = {0x4897d4, 0x8080ff, 0xff40b6};
    NSInteger row = 2;
    NSUInteger index = 0;
    for (OhrtAboutBox *box in self.boxes) {
        NSInteger lines = [self linesIn:box];
        index++;
        BOOL seen = CGRectIntersectsRect(rect, CGRectMake(0, [self y:row], self.bounds.size.width, (lines + 2) * _ch));
        if (!seen && !collect) {
            row += lines + 2;
            continue;
        }
        if (seen) [self frame:box index:index from:row to:row + lines + 1];
        double filled = [self filledOf:box];
        for (NSUInteger place = 0; place < box.rows.count; place++) {
            OhrtAboutRow *item = box.rows[place];
            BOOL grid = box.kind == OhrtAboutKindGrid, second = grid && place % 2;
            NSInteger line = row + 1 + (grid ? place / 2 : place);
            CGRect area = CGRectMake([self x:grid && second ? middle : 1], [self y:line], (grid ? middle - 1 : columns - 2) * _cw, _ch);
            if (collect && item.about.length) [_hits addObject:@[ [NSValue valueWithCGRect:area], item ]];
            if (!seen) continue;
            if (self.selected && [item.label isEqualToString:self.selected]) {
                [OhrtAboutHex(kOhrtAboutOff) setFill];
                UIRectFill(CGRectInset(area, grid ? _cw * 0.5 : 0, 1));
            }
            switch (box.kind) {
                case OhrtAboutKindLine:
                    [self pair:item row:line column:2 width:inner label:kOhrtAboutText value:kOhrtAboutQuietRed bold:YES];
                    break;
                case OhrtAboutKindGrid:
                    [self pair:item row:line column:second ? middle + 1 : 2 width:second ? columns - middle - 3 : middle - 4 label:kOhrtAboutText value:kOhrtAboutWhite bold:YES];
                    break;
                case OhrtAboutKindRates:
                    [self put:OhrtAboutFit(item.label, 24) row:line column:2 colour:kOhrtAboutText bold:NO];
                    [self meter:item.part * filled row:line column:27 cells:20 colours:&rates[place % 5] count:1];
                    [self put:filled >= 1 ? item.value : OhrtAboutRate(@(item.part * filled)) row:line end:columns - 2 colour:kOhrtAboutWhite bold:YES];
                    break;
                case OhrtAboutKindRanked:
                    if (item.place) [self put:OhrtGrouped((long long)item.place) row:line end:7 colour:kOhrtAboutDim bold:NO];
                    [self put:OhrtAboutFit(item.label, 18) row:line column:8 colour:kOhrtAboutName bold:NO];
                    [self meter:item.part * filled row:line column:27 cells:22 colours:close count:3];
                    if (!box.loading) [self put:filled >= 1 ? item.value : [NSString stringWithFormat:@"%.0f", item.part * filled * 100] row:line end:columns - 2 colour:kOhrtAboutWhite bold:YES];
                    break;
                case OhrtAboutKindRaw:
                    [self pair:item row:line column:2 width:inner label:kOhrtAboutDim value:kOhrtAboutText bold:NO];
                    break;
            }
        }
        if (seen && box.kind == OhrtAboutKindGrid) {
            UIBezierPath *divide = [UIBezierPath bezierPath];
            [divide moveToPoint:CGPointMake([self x:middle] - _cw / 2, [self y:row + 1] + 3)];
            [divide addLineToPoint:CGPointMake([self x:middle] - _cw / 2, [self y:row + lines + 1] - 3)];
            [OhrtAboutHex(kOhrtAboutDivide) setStroke];
            [divide stroke];
        } else if (box.under.length) {
            NSInteger line = row + 1 + (NSInteger)box.rows.count;
            if (seen) [self put:OhrtAboutFit(box.under, inner) row:line column:2 colour:kOhrtAboutDim bold:NO];
            if (collect && box.rows.count && box.rows[0].about.length) [_hits addObject:@[ [NSValue valueWithCGRect:CGRectMake([self x:1], [self y:line], (columns - 2) * _cw, _ch)], box.rows[0] ]];
        }
        row += lines + 2;
    }
}

- (void)touched:(UITapGestureRecognizer *)tap {
    CGPoint point = [tap locationInView:self];
    for (NSArray *hit in _hits) {
        if (!CGRectContainsPoint([hit[0] CGRectValue], point)) continue;
        if (self.tapped) self.tapped(hit[1]);
        return;
    }
    if (self.tapped) self.tapped(nil);
}

@end

@interface OhrtAboutViewController : UIViewController
@property (nonatomic, strong) UIScrollView *scroll;
@property (nonatomic, strong) OhrtAboutPage *page;
@property (nonatomic, strong) UIImageView *backdrop;
@property (nonatomic, strong) UIView *panel;
// The predictor's answer, nil while it is being asked.
@property (nonatomic, copy) NSString *nextOpen;
@property (nonatomic) BOOL nextOpenFailed;
@property (nonatomic) NSUInteger asks;
@property (nonatomic) CGFloat bottomRoom;
@property (nonatomic) BOOL waiting;
@property (nonatomic) NSUInteger waited;
@end

@implementation OhrtAboutViewController

// How much of the top the clock and the island take. The screen is laid
// over Instagram's tabs and is not told, so the window is asked.
- (CGFloat)topRoom {
    CGFloat room = self.view.safeAreaInsets.top;
    for (UIScene *scene in [UIApplication sharedApplication].connectedScenes) {
        if (![scene isKindOfClass:[UIWindowScene class]]) continue;
        for (UIWindow *window in ((UIWindowScene *)scene).windows) room = MAX(room, window.safeAreaInsets.top);
    }
    return room;
}

- (void)viewDidLoad {
    [super viewDidLoad];
    self.view.backgroundColor = OhrtAboutHex(kOhrtAboutBack);
    self.scroll = [UIScrollView new];
    self.scroll.alwaysBounceVertical = YES;
    self.scroll.indicatorStyle = UIScrollViewIndicatorStyleWhite;
    self.scroll.contentInsetAdjustmentBehavior = UIScrollViewContentInsetAdjustmentNever;
    [self.view addSubview:self.scroll];

    // The picture behind the top of the page, as faint as a terminal at
    // 0.95 opacity leaves its wallpaper, fading out towards its lower edge.
    NSString *file = [[NSBundle mainBundle] pathForResource:@"OhrtBackdrop" ofType:@"jpg"];
    UIImage *picture = file ? [UIImage imageWithContentsOfFile:file] : nil;
    if (picture) {
        self.backdrop = [[UIImageView alloc] initWithImage:picture];
        self.backdrop.contentMode = UIViewContentModeScaleAspectFill;
        self.backdrop.clipsToBounds = YES;
        self.backdrop.alpha = 0.05;
        CAGradientLayer *fade = [CAGradientLayer layer];
        fade.colors = @[ (id)[UIColor whiteColor].CGColor, (id)[UIColor whiteColor].CGColor, (id)[UIColor clearColor].CGColor ];
        fade.locations = @[ @0, @0.55, @1 ];
        self.backdrop.layer.mask = fade;
        [self.scroll addSubview:self.backdrop];
    }

    self.page = [OhrtAboutPage new];
    self.page.opaque = NO;
    self.page.backgroundColor = [UIColor clearColor];
    self.page.contentMode = UIViewContentModeRedraw;
    [self.page addGestureRecognizer:[[UITapGestureRecognizer alloc] initWithTarget:self.page action:@selector(touched:)]];
    __weak OhrtAboutViewController *weakSelf = self;
    self.page.tapped = ^(OhrtAboutRow *row) {
        [weakSelf explain:row];
    };
    [self.scroll addSubview:self.page];
    [[NSNotificationCenter defaultCenter] addObserver:self selector:@selector(cameBack) name:UIApplicationWillEnterForegroundNotification object:nil];
    [self refresh];
}

- (void)dealloc {
    [[NSNotificationCenter defaultCenter] removeObserver:self];
}

// The app was away: the prediction and the rest are old.
- (void)cameBack {
    if (self.view.window) [self refresh];
}

// The tab was pressed while this was open: up to the top, or if it is
// there already, everything is read again.
- (void)toTop {
    if (self.scroll.contentOffset.y > 1) [self.scroll setContentOffset:CGPointZero animated:YES];
    else [self refresh];
}

- (void)viewDidLayoutSubviews {
    [super viewDidLayoutSubviews];
    CGSize size = self.view.bounds.size;
    CGFloat top = [self topRoom];
    CGRect frame = CGRectMake(0, top, size.width, size.height - top);
    if (!CGRectEqualToRect(self.scroll.frame, frame)) self.scroll.frame = frame;
    // With an explanation open, the page can still be scrolled clear of it.
    CGFloat card = self.panel ? self.panel.bounds.size.height + 16 : 0;
    UIEdgeInsets inset = UIEdgeInsetsMake(0, 0, self.bottomRoom + card, 0);
    if (!UIEdgeInsetsEqualToEdgeInsets(self.scroll.contentInset, inset)) self.scroll.contentInset = inset;
    self.scroll.verticalScrollIndicatorInsets = UIEdgeInsetsMake(0, 0, self.bottomRoom, 0);
    CGRect page = CGRectMake(0, 0, size.width, [self.page heightForWidth:size.width]);
    if (!CGRectEqualToRect(self.page.frame, page)) self.page.frame = page;
    self.scroll.contentSize = page.size;
    if (self.backdrop.image.size.width > 0) {
        CGRect behind = CGRectMake(0, 0, size.width, size.width * self.backdrop.image.size.height / self.backdrop.image.size.width);
        if (!CGRectEqualToRect(self.backdrop.frame, behind)) {
            self.backdrop.frame = behind;
            self.backdrop.layer.mask.frame = self.backdrop.bounds;
        }
    }
}

// Instagram's tab bar controller does not pass "will appear" on to a screen
// laid over it, so the screen fills itself as it loads.
- (void)refresh {
    OhrtTry(@"about", ^{
        [self askNextOpen];
        [self build];
    });
    OhrtLog(@"about: %lu boxes shown", (unsigned long)self.page.boxes.count);
}

// What each of the remaining values is, by Meta's name for it. None of this
// is written down in the app: each is read off the name and held against the
// values seen on one phone, and says so where the two disagree.
static NSString *OhrtAboutMeaning(NSString *key) {
    static NSDictionary<NSString *, NSString *> *meanings;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        meanings = @{
            @"clips_producer_clips_created_28d" : @"Reels you posted in the last 28 days.",
            @"clips_producer_days_since_last_clips_creation" : @"Days since you last posted a reel.",
            @"clips_swipe_foward_28d" : @"Times you swiped on to the next reel in the last 28 days. The misspelling is Meta's.",
            @"clips_vpvd_impression_28d" : @"Reels that stayed on your screen long enough to count as viewed, over 28 days. vpvd is Meta's viewport view duration: how long a thing is actually in view. Where this was checked it equalled viewer_d28_instagram_clips_organic_vpvd_imp.",
            @"feed_fnf_organic_like_28d" : @"Likes you gave in the home feed, over 28 days, to posts from people you follow that were not ads. fnf most likely stands for friends and following.",
            @"feed_vpvd_impression_28d" : @"Feed posts that stayed on your screen long enough to count as viewed, over 28 days.",
            @"follow_button_tap_84d" : @"Times you pressed a follow button in the last 84 days. It counts presses, so following and unfollowing the same account adds up.",
            @"follower_count" : @"How many accounts follow you, as the ranking system last saw it.",
            @"following_count" : @"How many accounts you follow, as the ranking system last saw it.",
            @"instagram_organic_like" : @"Likes you gave to anything that was not an ad, anywhere in the app. The name gives no period, but where this was checked it equalled viewer_d84_instagram_organic_like exactly, so it is the 84 day total.",
            @"kbps_3d" : @"Your connection speed as Insta⁠gram measured it over the last 3 days, in kilobits a second. Divide by 1,000 for megabits. It is used to pick video quality and how much to load ahead.",
            @"kbps_7d" : @"Your connection speed as Insta⁠gram measured it over the last 7 days, in kilobits a second. Divide by 1,000 for megabits.",
            @"max_ram_7d" : @"The most memory your phone reported having in the last 7 days, in bytes. It is the phone's memory, not how much Insta⁠gram used: where this was checked it matched the phone's 12 GB.",
            @"raw_udv_overall_max" : @"Not known. udv is an abbreviation that is nowhere explained in the app.",
            @"reels_user_cohort_segment_based_on_play" : @"The first version of your reels tier, a number for how much you play reels. The scale is not in the app.",
            @"story_reply_l28_trait" : @"A label for how much you reply to stories, over the last 28 days. The possible labels are not in the app.",
            @"unit_tray_time_spent_28d" : @"Time spent in a tray, a sideways strip of items such as the stories row, over 28 days. Which tray is not said.",
            @"user_clips_tab_timespent_1d" : @"Seconds you spent in the Reels tab in one day.",
            @"user_clips_tab_timespent_28d" : @"Seconds you spent in the Reels tab over 28 days.",
            @"user_clips_tab_timespent_7d" : @"Seconds you spent in the Reels tab over 7 days.",
            @"user_connected_feed_like_rate_28d" : @"An older name for the share of posts from people you follow that you liked, over 28 days.",
            @"user_feed_impressions_28d" : @"Posts the home feed showed you in the last 28 days.",
            @"user_feed_inventory_28d" : @"Posts from people you follow that were there for the feed to show you, over 28 days. Inventory is Meta's word for what is available, seen or not.",
            @"user_feed_reciprocal_post_consumption_rate_7d" : @"Of the posts from accounts that follow you back, the share you saw, over 7 days. 1 means all of them.",
            @"user_feed_reciprocal_post_inventory_7d" : @"Posts from accounts that follow you back that were there to show you, over 7 days.",
            @"user_feed_recs_cold_start_bucket" : @"A group for accounts the feed knows too little about to suggest posts to. Cold start is the usual name for that problem.",
            @"user_friend_story_inventory_28d" : @"Stories from accounts that follow you back that were there for you to watch, over 28 days.",
            @"user_interest_feed_inventory_28d" : @"Posts picked for your interests, from accounts you do not follow, that were there to suggest to you, over 28 days.",
            @"user_num_comments_received_28d" : @"Comments your posts got in the last 28 days.",
            @"user_num_comments_received_by_normal_28d" : @"Comments received in the last 28 days, counted \"by normal\". What normal means is not in the app, and where this was checked the number was far larger than the plain count beside it, so it does not count the same thing.",
            @"user_num_l7_core_foreground_session_count" : @"Times you brought Insta⁠gram to the front in the last 7 days. The same count as core_foreground_session_count_l7 under a second name.",
            @"user_num_likes_received_by_normal_28d" : @"Likes received in the last 28 days, counted \"by normal\". What normal means is not in the app.",
            @"user_num_videos_28d" : @"Videos you posted in the last 28 days.",
            @"user_sender_l28" : @"On how many of the last 28 days you sent at least one message.",
            @"user_stories_impressions_bucket_28d" : @"A range for how many stories you were shown over 28 days.",
            @"user_story_interaction_received_28d" : @"Replies and reactions your stories got in the last 28 days.",
            @"user_story_like_received_28d" : @"Likes your stories got in the last 28 days.",
            @"user_story_media_impression_received_28d" : @"Views your stories got in the last 28 days.",
            @"viewer_d28_direct_reshare_button_tap" : @"Times you pressed the share button on a post in the last 28 days. Compare it with viewer_d28_direct_reshare_send, the times you went on to send.",
            @"viewer_d28_instagram_clips_organic_time_spent" : @"Named as time spent on reels that were not ads, over 28 days. Where this was checked it equalled the count of viewed reels exactly, so it may hold that count and not a time.",
            @"viewer_d28_instagram_clips_organic_vpvd_imp" : @"Reels, not ads, that stayed on your screen long enough to count as viewed, over 28 days.",
            @"viewer_d28_instagram_clips_viewer_entry" : @"Times you went into the full screen reels player in the last 28 days.",
            @"viewer_d28_instagram_clips_viewer_entry_ctr" : @"Of the times a reel was offered to you outside the player, the share where you tapped in, over 28 days. ctr is click through rate.",
            @"viewer_d28_instagram_explore_organic_impression" : @"Posts Explore showed you in the last 28 days, not counting ads.",
            @"viewer_d28_instagram_feed_fnf_organic_impression" : @"Posts from people you follow that the home feed showed you in the last 28 days, not counting ads.",
            @"viewer_d28_instagram_feed_instagram_organic_like" : @"Likes you gave in the home feed in the last 28 days to posts that were not ads.",
            @"viewer_d28_instagram_feed_vpvd_impression" : @"Feed posts that stayed on your screen long enough to count as viewed, over 28 days. One post can count more than once.",
            @"viewer_d28_instagram_organic_like" : @"Named as likes you gave to anything that was not an ad, over 28 days. Where this was checked it was smaller than the feed's own count for the same days, so it does not cover what its name says.",
            @"viewer_d28_instagram_organic_vpvd_imp" : @"Things that were not ads and stayed on your screen long enough to count as viewed, over 28 days.",
            @"viewer_d28_instagram_rifu_chaining_time_spent" : @"Time spent in the run of reels that opens when you tap a reel in the feed, over 28 days. rifu most likely stands for reels in feed unit.",
            @"viewer_d28_instagram_rifu_clips_swipe_forward" : @"Swipes on to the next reel after opening one from the feed, over 28 days.",
            @"viewer_d28_instagram_rifu_explore_home_click_ctr" : @"Named as a click rate for reels reached from the feed unit or Explore, over 28 days. Where this was checked it was a whole number, so it is a count or a group and not a rate.",
            @"viewer_d28_instagram_story_reel_playback_entry" : @"Times you opened someone's stories in the last 28 days. In Meta's code a reel is one person's run of stories, not a Reel.",
            @"viewer_d28_instagram_unit_tray_time_spent" : @"Seconds spent in a tray, a sideways strip of items, over 28 days. Which tray is not said.",
            @"viewer_d28_video_complete_ctr" : @"Of the videos you started, the share you watched to the end, over 28 days.",
            @"viewer_d7_video_complete" : @"Videos you watched all the way through in the last 7 days.",
            @"viewer_d84_instagram_clips_organic_impression" : @"Reels put in front of you in the last 84 days, not counting ads.",
            @"viewer_d84_instagram_clips_organic_save" : @"Reels you saved in the last 84 days.",
            @"viewer_d84_instagram_clips_swipe_forward" : @"Times you swiped on to the next reel in the last 84 days.",
            @"viewer_d84_instagram_clips_viewer_entry" : @"Times you went into the full screen reels player in the last 84 days.",
            @"viewer_d84_instagram_feed_direct_reshare_send" : @"Posts you sent to someone from the home feed in the last 84 days.",
            @"viewer_d84_instagram_feed_fnf_organic_impression" : @"Posts from people you follow that the home feed showed you in the last 84 days, not counting ads.",
            @"viewer_d84_instagram_feed_fnf_organic_like" : @"Likes you gave in the home feed, over 84 days, to posts from people you follow.",
            @"viewer_d84_instagram_feed_organic_like" : @"Likes you gave in the home feed in the last 84 days to posts that were not ads, followed or suggested.",
            @"viewer_d84_instagram_feed_organic_profile" : @"Times you tapped through from a feed post to its profile in the last 84 days.",
            @"viewer_d84_instagram_organic_like" : @"Likes you gave to anything that was not an ad, anywhere in the app, in the last 84 days.",
            @"viewer_d84_instagram_organic_viewed_impression" : @"Everything that was not an ad and counted as seen by you, anywhere in the app, in the last 84 days.",
            @"viewer_d84_instagram_reel_playback_entry" : @"Times you opened someone's stories in the last 84 days. In Meta's code a reel is one person's run of stories.",
            @"viewer_d84_instagram_reel_send_message" : @"Replies you sent to stories in the last 84 days.",
            @"viewer_d84_instagram_reel_tray_impression" : @"Story circles shown to you in the row at the top of the feed in the last 84 days. Every circle that scrolls into view counts.",
            @"viewer_d84_skip" : @"Things you skipped in the last 84 days. What counts as a skip is not said.",
        };
    });
    NSString *meaning = meanings[key];
    if (meaning) return [meaning stringByAppendingString:@"\n\nWorked out from Meta's name for it and the values seen. Meta does not publish what these mean."];
    // A name not met before is taken apart instead.
    NSDictionary<NSString *, NSString *> *parts = @{
        @"l7" : @"the last 7 days", @"l28" : @"the last 28 days", @"d7" : @"a total over 7 days", @"d28" : @"a total over 28 days", @"d84" : @"a total over 84 days", @"1d" : @"one day", @"7d" : @"7 days",
        @"28d" : @"28 days", @"84d" : @"84 days", @"clips" : @"Reels", @"reel" : @"one person's stories", @"connected" : @"from people you follow", @"organic" : @"not an ad", @"fnf" : @"friends and following",
        @"vpvd" : @"on screen long enough to count as viewed", @"ifr" : @"suggested in the feed", @"rifu" : @"reels in the feed", @"inventory" : @"what was there to show you", @"impression" : @"shown to you",
        @"ctr" : @"a click through rate", @"viewer" : @"about what you look at", @"bucket" : @"a range, not an exact number", @"timespent" : @"time, in seconds", @"reciprocal" : @"accounts that follow you back",
    };
    NSMutableArray<NSString *> *read = [NSMutableArray array];
    for (NSString *part in [key componentsSeparatedByString:@"_"]) {
        if (parts[part]) [read addObject:[NSString stringWithFormat:@"%@ is %@", part, parts[part]]];
    }
    NSString *start = @"One of the values Insta\u2060gram stores about you, under the name Meta gave it. This one has not been looked into.";
    return read.count ? [NSString stringWithFormat:@"%@ In the name, %@.", start, [read componentsJoinedByString:@", "]] : start;
}

static OhrtAboutRow *OhrtAboutPlain(NSString *label, NSString *value, NSString *about) {
    OhrtAboutRow *row = [OhrtAboutRow new];
    row.label = label;
    row.value = value;
    row.about = about;
    return row;
}

static OhrtAboutBox *OhrtAboutBoxed(OhrtAboutKind kind, NSString *title, NSString *note, NSArray<OhrtAboutRow *> *rows) {
    OhrtAboutBox *box = [OhrtAboutBox new];
    box.kind = kind;
    box.title = title;
    box.note = note;
    box.rows = rows;
    return box;
}

static void OhrtAboutAdd(NSMutableArray<OhrtAboutRow *> *rows, NSDictionary *features, NSString *label, NSString *key, OhrtAboutFormat format, NSString *about) {
    id value = features[key];
    if (!OhrtAboutFilled(value)) return;
    NSString *named = [NSString stringWithFormat:@"%@\n\nInsta\u2060gram's name for it: %@", about, key];
    OhrtAboutRow *row = OhrtAboutPlain(label, format ? format(value) : OhrtAboutNumber(value), named);
    if (format == OhrtAboutRate) row.part = [value doubleValue];
    [rows addObject:row];
}

static NSString *OhrtAboutBestieMeaning(NSUInteger scored) {
    return [NSString stringWithFormat:@"The score Meta's servers give this account for how close you are, out of 100. It is one of %@ accounts scored for you, and Insta\u2060gram uses the scores to "
                                      @"order its suggestions, such as who to add to close friends and who to message. Shown are the first three places, then eight more spread down to the last. "
                                      @"How the score is worked out stays on Meta's servers.\n\nInsta\u2060gram's name for it: coefficient_besties_list_ranking",
                                      OhrtGrouped((long long)scored)];
}

- (NSArray<OhrtAboutRow *> *)besties:(NSUInteger *)total {
    id service = OhrtCall(OhrtCurrentSession(), @"userBootstrapService");
    id bootstrap = OhrtAboutIvar(service, "_bootstrap");
    id surfaces = OhrtCallValue(bootstrap, @"surfaces");
    if ([surfaces isKindOfClass:[NSSet class]]) surfaces = [surfaces allObjects];
    NSDictionary *scores = nil;
    for (id surface in [surfaces isKindOfClass:[NSArray class]] ? surfaces : @[]) {
        if ([OhrtCallValue(surface, @"name") isEqual:@"coefficient_besties_list_ranking"]) scores = [OhrtAboutIvar(surface, "_scores") copy];
    }
    if (![scores isKindOfClass:[NSDictionary class]] || !scores.count) return @[];
    NSMutableDictionary<NSString *, NSString *> *names = [NSMutableDictionary dictionary];
    id users = OhrtCallValue(bootstrap, @"users");
    if ([users isKindOfClass:[NSSet class]]) users = [users allObjects];
    for (id user in [users isKindOfClass:[NSArray class]] ? users : @[]) {
        id pk = OhrtCallValue(user, @"pk");
        id username = OhrtCallValue(user, @"username");
        if (pk && [username isKindOfClass:[NSString class]]) names[[pk description]] = username;
    }
    // Most of the list comes at exactly 0: accounts Instagram listed and
    // did not score. They are left out, of the places and of the count.
    NSMutableDictionary *real = [NSMutableDictionary dictionary];
    for (id key in scores) {
        if ([scores[key] isKindOfClass:[NSNumber class]] && [scores[key] doubleValue] > 0) real[key] = scores[key];
    }
    scores = real;
    if (!scores.count) return @[];
    NSArray *ordered = [scores keysSortedByValueUsingComparator:^NSComparisonResult(id one, id other) {
        return [other compare:one];
    }];
    NSString *about = OhrtAboutBestieMeaning(scores.count);
    // The first three, then eight more places spread down to the last, each
    // the same number of times further down than the one before. The top of
    // the list is too close together to tell apart as bars, and how long the
    // list is differs from one account to the next.
    NSUInteger count = ordered.count;
    static BOOL told;
    if (!told) {
        told = YES;
        NSUInteger nameless = 0;
        for (id key in ordered) nameless += names[[key description]] == nil;
        OhrtLog(@"about: %lu accounts scored above zero, %lu of them with no user in the list", (unsigned long)count, (unsigned long)nameless);
    }
    NSMutableOrderedSet<NSNumber *> *places = [NSMutableOrderedSet orderedSet];
    for (NSUInteger place = 1; place <= MIN(count, 3); place++) [places addObject:@(place)];
    if (count > 3) {
        for (int step = 1; step <= 8; step++) [places addObject:@(MIN(count, (NSUInteger)llround(3 * pow(count / 3.0, step / 8.0))))];
        [places addObject:@(count)];
    }
    NSMutableArray<OhrtAboutRow *> *rows = [NSMutableArray array];
    for (NSNumber *place in places) {
        id key = ordered[place.unsignedIntegerValue - 1];
        id score = scores[key];
        if (![score isKindOfClass:[NSNumber class]]) continue;
        NSString *name = names[[key description]];
        OhrtAboutRow *row = OhrtAboutPlain(name ? [@"@" stringByAppendingString:name] : [@"id " stringByAppendingString:[key description]], [NSString stringWithFormat:@"%.0f", [score doubleValue] * 100], about);
        row.part = [score doubleValue];
        row.place = place.unsignedIntegerValue;
        [rows addObject:row];
    }
    if (total) *total = scores.count;
    return rows;
}

- (void)build {
    NSDate *when = nil;
    NSDictionary *f = OhrtAboutFeatures(&when);
    NSMutableArray<OhrtAboutBox *> *boxes = [NSMutableArray array];

    NSString *asked = self.nextOpen ? @"instagram expects you to reopen the app in" : self.nextOpenFailed ? @"casper gave no estimate on this phone" : @"asking casper when you'll open the app next";
    OhrtAboutBox *next = OhrtAboutBoxed(OhrtAboutKindLine, @"next open", @"casper, a model on this phone", @[ OhrtAboutPlain(asked, self.nextOpen ?: @"",
                              @"Insta\u2060gram's guess at how long until you next open the app. The model runs on your phone and looks at how often you opened the app over the last hour up to the "
                              @"last week, how long you stayed, the time of day, your unread messages and which screen you last left from. Insta\u2060gram uses the guess to decide when to "
                              @"fetch new posts in the background.\n\nInsta\u2060gram's name for it: IGCasper, minutes_to_next_target_event") ]);
    next.under = @"worked out from when and how often you open it";
    next.foot = @"tap a row for what it means";
    [boxes addObject:next];

    NSMutableArray<OhrtAboutRow *> *rows = [NSMutableArray array];
    OhrtAboutAdd(rows, f, @"reels group", @"clips_cohort", NULL,
                 @"The group Insta⁠gram puts you in for Reels. The names of the groups are chosen on Meta's servers and the others are not in the app, so what ranks exist besides this one is not known.");
    OhrtAboutAdd(rows, f, @"reels tier", @"reels_user_cohort_segment_based_on_play_v2", NULL,
                 @"A tier based on how much you play reels. The scale is not in the app, so what the number is out of is not known.");
    OhrtAboutAdd(rows, f, @"predicted age", @"user_predicted_age", NULL,
                 @"The age Insta⁠gram reckons you are. Meta has said it uses a model that estimates age from things like how old an account is and how it is used. Whether this number is that model's "
                 @"answer is not confirmed.");
    OhrtAboutAdd(rows, f, @"gender", @"gender", OhrtAboutGender,
                 @"The gender on file for you, in the codes of Insta⁠gram's own gender setting: 1 male, 2 female, 3 prefer not to say, 4 custom. Whether it copies what you set or is predicted cannot be "
                 @"told from the app.");
    OhrtAboutAdd(rows, f, @"teen, by model", @"user_is_teen_model_based", OhrtAboutYesNo, @"Whether a model, as opposed to your stated birthday, takes you for a teenager.");
    OhrtAboutAdd(rows, f, @"notes on offer", @"notes_inventory_bucket", NULL, @"Roughly how many Notes there are to show you, as a range.");
    if (rows.count) {
        OhrtAboutBox *labels = OhrtAboutBoxed(OhrtAboutKindGrid, @"labels", @"sent with your feed, daily", rows);
        if (when) {
            NSDateFormatter *formatter = [NSDateFormatter new];
            formatter.locale = [NSLocale localeWithLocaleIdentifier:@"en_US_POSIX"];
            formatter.dateFormat = @"MM.dd.yy HH:mm";
            labels.foot = [@"sent " stringByAppendingString:[formatter stringFromDate:when]];
        }
        [boxes addObject:labels];
    }

    rows = [NSMutableArray array];
    OhrtAboutAdd(rows, f, @"time in app", @"user_timespent_28d_sec", OhrtAboutTime, @"How long you had Insta⁠gram open over the last 28 days.");
    OhrtAboutAdd(rows, f, @"opens, 7d", @"core_foreground_session_count_l7", NULL, @"How many times you brought Insta⁠gram to the front in the last 7 days.");
    OhrtAboutAdd(rows, f, @"feed, per day", @"user_feed_timespent_1d", OhrtAboutTime, @"Time on the home feed in one day.");
    OhrtAboutAdd(rows, f, @"stories, per day", @"user_stories_timespent_1d", OhrtAboutTime, @"Time watching stories in one day.");
    OhrtAboutAdd(rows, f, @"dms sent", @"user_total_sends_28d", NULL, @"Messages you sent in the last 28 days.");
    OhrtAboutAdd(rows, f, @"dms read", @"user_total_message_reads_28d", NULL, @"Messages you read in the last 28 days.");
    OhrtAboutAdd(rows, f, @"posts shared", @"viewer_d28_direct_reshare_send", NULL, @"Posts you sent to someone in a message in the last 28 days.");
    OhrtAboutAdd(rows, f, @"reels shown", @"viewer_d28_instagram_clips_organic_impression", NULL, @"Reels put in front of you in the last 28 days, not counting ads.");
    OhrtAboutAdd(rows, f, @"reels swiped", @"viewer_d28_instagram_clips_swipe_forward", NULL, @"Times you swiped on to the next reel in the last 28 days.");
    OhrtAboutAdd(rows, f, @"videos finished", @"viewer_d28_video_complete", NULL, @"Videos you watched all the way through in the last 28 days.");
    OhrtAboutAdd(rows, f, @"days on explore", @"user_explore_l28", OhrtAboutOf28, @"On how many of the last 28 days you opened Explore.");
    OhrtAboutAdd(rows, f, @"stories offered", @"user_story_inventory_28d", NULL, @"How many stories there were for you to watch in the last 28 days.");
    OhrtAboutAdd(rows, f, @"days active", @"user_l28_ig_classic_count", OhrtAboutOf28, @"On how many of the last 28 days you used Insta\u2060gram.");
    OhrtAboutAdd(rows, f, @"days messaging", @"user_sender_l28", OhrtAboutOf28, @"On how many of the last 28 days you sent at least one message.");
    if (rows.count) [boxes addObject:OhrtAboutBoxed(OhrtAboutKindGrid, @"last 28 days", @"as instagram counted", rows)];

    rows = [NSMutableArray array];
    OhrtAboutAdd(rows, f, @"posts you like", @"user_feed_connected_like_rate_d28", OhrtAboutRate, @"Of the posts shown to you from people you follow, the share you liked, over 28 days.");
    OhrtAboutAdd(rows, f, @"profile taps", @"user_feed_connected_profile_tap_rate_d28", OhrtAboutRate, @"Of the posts shown to you from people you follow, the share where you tapped through to the profile, over 28 days.");
    OhrtAboutAdd(rows, f, @"posts you share", @"user_feed_connected_reshare_rate_d28", OhrtAboutRate, @"Of the posts shown to you from people you follow, the share you sent to someone, over 28 days.");
    OhrtAboutAdd(rows, f, @"suggested reels liked", @"user_feed_ifr_reels_like_rate_28d", OhrtAboutRate, @"Of the reels Insta⁠gram suggested in your feed, the share you liked.");
    OhrtAboutAdd(rows, f, @"follows that follow back", @"user_reciprocal_follow_rate", OhrtAboutRate, @"Of the accounts you follow, the share that follow you back.");
    if (rows.count) [boxes addObject:OhrtAboutBoxed(OhrtAboutKindRates, @"rates", @"of what you were shown", rows)];

    // Instagram fills its list of scores a couple of seconds after it
    // starts. The box is there from the first at its full height: with the
    // rows shown last time, kept on the phone, or failing that with empty
    // ones that fill when the list comes.
    NSUserDefaults *defaults = [NSUserDefaults standardUserDefaults];
    NSString *viewer = [OhrtCall(OhrtCall(OhrtCurrentSession(), @"user"), @"pk") description] ?: @"";
    NSUInteger scored = 0;
    NSArray<OhrtAboutRow *> *closest = [self besties:&scored];
    OhrtAboutBox *besties = OhrtAboutBoxed(OhrtAboutKindRanked, @"bestie_coefficient", nil, closest);
    if (closest.count) {
        NSMutableArray *kept = [NSMutableArray array];
        for (OhrtAboutRow *row in closest) [kept addObject:@{@"label" : row.label, @"value" : row.value, @"part" : @(row.part), @"place" : @(row.place)}];
        NSDictionary *keep = @{@"rows" : kept, @"scored" : @(scored), @"viewer" : viewer};
        if (![keep isEqual:[defaults dictionaryForKey:kOhrtAboutBestiesKey]]) [defaults setObject:keep forKey:kOhrtAboutBestiesKey];
        if (self.waited) OhrtLog(@"about: the scores came %lu seconds after the screen opened", (unsigned long)self.waited);
        self.waited = 0;
    } else {
        NSDictionary *kept = [defaults dictionaryForKey:kOhrtAboutBestiesKey];
        NSMutableArray<OhrtAboutRow *> *last = [NSMutableArray array];
        if ([kept[@"viewer"] isEqual:viewer]) {
            scored = [kept[@"scored"] unsignedIntegerValue];
            for (NSDictionary *one in [kept[@"rows"] isKindOfClass:[NSArray class]] ? kept[@"rows"] : @[]) {
                if (![one isKindOfClass:[NSDictionary class]] || ![one[@"label"] isKindOfClass:[NSString class]] || ![one[@"value"] isKindOfClass:[NSString class]]) continue;
                OhrtAboutRow *row = OhrtAboutPlain(one[@"label"], one[@"value"], OhrtAboutBestieMeaning(scored));
                row.part = [one[@"part"] doubleValue];
                row.place = [one[@"place"] unsignedIntegerValue];
                [last addObject:row];
            }
        }
        if (!last.count) {
            besties.loading = YES;
            for (int place = 0; place < 11; place++) [last addObject:OhrtAboutPlain(@"", @"", nil)];
        }
        besties.rows = last;
        [self waitForScores];
    }
    besties.note = besties.loading ? (self.waited < kOhrtAboutScoresWait ? @"scores loading" : @"no scores on this phone yet") : [OhrtGrouped((long long)scored) stringByAppendingString:@" accounts scored"];
    if (f || !besties.loading) [boxes addObject:besties];

    // Everything else it filled, under its own names.
    NSMutableSet<NSString *> *shown = [NSMutableSet setWithArray:@[
        @"clips_cohort", @"reels_user_cohort_segment_based_on_play_v2", @"user_predicted_age", @"gender", @"user_is_teen_model_based", @"user_l28_ig_classic_count", @"notes_inventory_bucket",
        @"user_timespent_28d_sec", @"user_feed_timespent_1d", @"user_stories_timespent_1d", @"core_foreground_session_count_l7", @"user_total_sends_28d", @"user_total_message_reads_28d",
        @"viewer_d28_direct_reshare_send", @"viewer_d28_instagram_clips_organic_impression", @"viewer_d28_instagram_clips_swipe_forward", @"viewer_d28_video_complete", @"user_explore_l28",
        @"user_story_inventory_28d", @"user_feed_connected_like_rate_d28", @"user_feed_connected_profile_tap_rate_d28", @"user_feed_connected_reshare_rate_d28", @"user_feed_ifr_reels_like_rate_28d",
        @"user_reciprocal_follow_rate", @"user_sender_l28"
    ]];
    rows = [NSMutableArray array];
    for (NSString *key in [[f allKeys] sortedArrayUsingSelector:@selector(compare:)]) {
        if (![key isKindOfClass:[NSString class]] || [shown containsObject:key] || !OhrtAboutFilled(f[key])) continue;
        [rows addObject:OhrtAboutPlain(key, [key hasPrefix:@"max_ram"] ? OhrtAboutBytes(f[key]) : OhrtAboutNumber(f[key]), OhrtAboutMeaning(key))];
    }
    if (rows.count) [boxes addObject:OhrtAboutBoxed(OhrtAboutKindRaw, @"raw", [NSString stringWithFormat:@"%lu values, meta's names", (unsigned long)rows.count], rows)];

    if (!f) {
        OhrtAboutBox *none = OhrtAboutBoxed(OhrtAboutKindLine, @"profile", @"not here yet", @[ OhrtAboutPlain(@"comes with the home feed", @"waiting", @"Insta⁠gram has not sent it to this phone yet. Open the feed, then come back.") ]);
        [boxes addObject:none];
    }
    self.page.boxes = boxes;
    [self.view setNeedsLayout];
}

// Looks once a second for the list of scores, and builds the page again
// only when it has come or the wait is given up.
- (void)waitForScores {
    if (self.waiting || self.waited >= kOhrtAboutScoresWait) return;
    self.waiting = YES;
    __weak OhrtAboutViewController *weakSelf = self;
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, NSEC_PER_SEC), dispatch_get_main_queue(), ^{
        OhrtAboutViewController *strongSelf = weakSelf;
        if (!strongSelf) return;
        strongSelf.waiting = NO;
        strongSelf.waited++;
        OhrtTry(@"about", ^{
            if ([strongSelf besties:NULL].count || strongSelf.waited >= kOhrtAboutScoresWait) [strongSelf build];
            else [strongSelf waitForScores];
        });
    });
}

// The model answers with a whole number of minutes and the same as a
// fraction. If it has not answered in a few seconds, the row says so.
- (void)askNextOpen {
    id casper = OhrtCall(OhrtCurrentSession(), @"casper");
    SEL estimate = NSSelectorFromString(@"estimateMinutesToNextTargetEventAfterBackground:completionQueue:");
    if (![casper respondsToSelector:estimate]) {
        self.nextOpen = nil;
        self.nextOpenFailed = YES;
        return;
    }
    NSUInteger ask = ++self.asks;
    __weak OhrtAboutViewController *weakSelf = self;
    void (^answer)(long long, float) = ^(long long whole, float minutes) {
        OhrtAboutViewController *strongSelf = weakSelf;
        if (!strongSelf || !(minutes >= 0)) return;
        long long rounded = llround(minutes);
        strongSelf.nextOpen = rounded >= 60 ? [NSString stringWithFormat:@"%lldh %lldm", rounded / 60, rounded % 60] : [NSString stringWithFormat:@"%lldm", rounded];
        strongSelf.nextOpenFailed = NO;
        OhrtTry(@"about", ^{
            [strongSelf build];
        });
    };
    ((void (*)(id, SEL, id, id))objc_msgSend)(casper, estimate, (id)answer, dispatch_get_main_queue());
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, 5 * NSEC_PER_SEC), dispatch_get_main_queue(), ^{
        OhrtAboutViewController *strongSelf = weakSelf;
        if (!strongSelf || strongSelf.asks != ask || strongSelf.nextOpen) return;
        strongSelf.nextOpenFailed = YES;
        OhrtTry(@"about", ^{
            [strongSelf build];
        });
    });
}

- (void)closePanel {
    [self.panel removeFromSuperview];
    self.panel = nil;
    self.page.selected = nil;
    [self.view setNeedsLayout];
}

// What a row means, in a box of the same kind at the foot of the screen.
// The page under it still scrolls, another row swaps it, and a tap on it,
// on its own row or on nothing closes it.
- (void)explain:(OhrtAboutRow *)row {
    BOOL same = !row || [row.label isEqualToString:self.page.selected];
    [self closePanel];
    if (same) return;

    UILabel *head = [UILabel new];
    head.text = row.value.length ? [NSString stringWithFormat:@"%@\n%@", row.label, row.value] : row.label;
    head.font = [UIFont monospacedSystemFontOfSize:12 weight:UIFontWeightBold];
    head.textColor = OhrtAboutHex(kOhrtAboutWhite);
    head.numberOfLines = 0;
    head.lineBreakMode = NSLineBreakByCharWrapping;
    UILabel *body = [UILabel new];
    body.text = row.about;
    body.font = [UIFont monospacedSystemFontOfSize:12 weight:UIFontWeightRegular];
    body.textColor = OhrtAboutHex(kOhrtAboutText);
    body.numberOfLines = 0;
    UILabel *foot = [UILabel new];
    foot.text = @"tap to close";
    foot.font = [UIFont monospacedSystemFontOfSize:11 weight:UIFontWeightRegular];
    foot.textColor = OhrtAboutHex(kOhrtAboutDim);
    foot.textAlignment = NSTextAlignmentRight;

    UIStackView *stack = [[UIStackView alloc] initWithArrangedSubviews:@[ head, body, foot ]];
    stack.axis = UILayoutConstraintAxisVertical;
    stack.spacing = 10;
    stack.layoutMargins = UIEdgeInsetsMake(12, 12, 10, 12);
    stack.layoutMarginsRelativeArrangement = YES;
    stack.userInteractionEnabled = NO;
    stack.translatesAutoresizingMaskIntoConstraints = NO;
    UIView *card = [UIView new];
    card.backgroundColor = OhrtAboutHex(kOhrtAboutBack);
    card.layer.borderColor = OhrtAboutHex(kOhrtAboutBorder).CGColor;
    card.layer.borderWidth = 1;
    card.layer.cornerRadius = 4;
    card.translatesAutoresizingMaskIntoConstraints = NO;
    [card addGestureRecognizer:[[UITapGestureRecognizer alloc] initWithTarget:self action:@selector(closePanel)]];
    [card addSubview:stack];
    [self.view addSubview:card];
    // The box borders sit half a cell in from the side.
    CGFloat side = kOhrtAboutSide + (self.view.bounds.size.width - 2 * kOhrtAboutSide) / kOhrtAboutColumns / 2;
    [NSLayoutConstraint activateConstraints:@[
        [stack.topAnchor constraintEqualToAnchor:card.topAnchor],
        [stack.bottomAnchor constraintEqualToAnchor:card.bottomAnchor],
        [stack.leadingAnchor constraintEqualToAnchor:card.leadingAnchor],
        [stack.trailingAnchor constraintEqualToAnchor:card.trailingAnchor],
        [card.leadingAnchor constraintEqualToAnchor:self.view.leadingAnchor constant:side],
        [card.trailingAnchor constraintEqualToAnchor:self.view.trailingAnchor constant:-side],
        [card.bottomAnchor constraintEqualToAnchor:self.view.bottomAnchor constant:-(self.bottomRoom + 8)],
    ]];
    self.panel = card;
    self.page.selected = row.label;
    [self.view layoutIfNeeded];
    // The row stays in sight above the box.
    CGRect area = [self.page areaOfRowLabelled:row.label];
    if (!CGRectIsEmpty(area)) [self.scroll scrollRectToVisible:CGRectInset([self.page convertRect:area toView:self.scroll], 0, -8) animated:YES];
}

@end

UIViewController *OhrtAboutScreen(CGFloat bottomRoom) {
    OhrtAboutViewController *screen = [OhrtAboutViewController new];
    screen.bottomRoom = bottomRoom;
    return screen;
}

void OhrtAboutShown(UIViewController *screen, CGFloat bottomRoom) {
    if (![screen isKindOfClass:[OhrtAboutViewController class]]) return;
    ((OhrtAboutViewController *)screen).bottomRoom = bottomRoom;
    [(OhrtAboutViewController *)screen refresh];
}

void OhrtAboutToTop(UIViewController *screen) {
    if ([screen isKindOfClass:[OhrtAboutViewController class]]) [(OhrtAboutViewController *)screen toTop];
}
