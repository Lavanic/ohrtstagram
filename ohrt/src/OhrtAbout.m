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
    return [NSString stringWithFormat:@"%.4g", number];
}

static NSString *OhrtAboutTime(id value) {
    long long seconds = [value longLongValue];
    if (seconds < 3600) return [NSString stringWithFormat:@"%lldm", seconds / 60];
    return [NSString stringWithFormat:@"%lldh %lldm", seconds / 3600, (seconds % 3600) / 60];
}

static NSString *OhrtAboutRate(id value) {
    return [NSString stringWithFormat:@"%.1f%%", [value doubleValue] * 100];
}

typedef NSString * (*OhrtAboutFormat)(id);

@interface OhrtAboutRow : NSObject
@property (nonatomic, copy) NSString *label, *value;
@end

@implementation OhrtAboutRow
@end

@interface OhrtAboutViewController : UITableViewController
@property (nonatomic, strong) NSArray<NSString *> *titles;
@property (nonatomic, strong) NSArray<NSArray<OhrtAboutRow *> *> *rows;
@property (nonatomic, copy) NSString *nextOpen;
@end

@implementation OhrtAboutViewController

- (instancetype)init {
    return [super initWithStyle:UITableViewStyleInsetGrouped];
}

- (void)viewDidLoad {
    [super viewDidLoad];
    self.title = @"about you";
    self.tableView.allowsSelection = NO;
}

- (void)viewWillAppear:(BOOL)animated {
    [super viewWillAppear:animated];
    OhrtTry(@"about", ^{
        [self build];
        [self askNextOpen];
    });
    [self.tableView reloadData];
}

static void OhrtAboutAdd(NSMutableArray<OhrtAboutRow *> *rows, NSDictionary *features, NSString *label, NSString *key, OhrtAboutFormat format) {
    id value = features[key];
    if (!OhrtAboutFilled(value)) return;
    OhrtAboutRow *row = [OhrtAboutRow new];
    row.label = label;
    row.value = format ? format(value) : OhrtAboutNumber(value);
    [rows addObject:row];
}

static OhrtAboutRow *OhrtAboutPlain(NSString *label, NSString *value) {
    OhrtAboutRow *row = [OhrtAboutRow new];
    row.label = label;
    row.value = value;
    return row;
}

- (NSArray<OhrtAboutRow *> *)besties {
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
    NSArray *ordered = [scores keysSortedByValueUsingComparator:^NSComparisonResult(id one, id other) {
        return [other compare:one];
    }];
    NSMutableArray<OhrtAboutRow *> *rows = [NSMutableArray array];
    for (id key in ordered) {
        if (rows.count >= 15) break;
        id score = scores[key];
        if (![score isKindOfClass:[NSNumber class]]) continue;
        NSString *name = names[[key description]];
        [rows addObject:OhrtAboutPlain(name ? [@"@" stringByAppendingString:name] : [@"id " stringByAppendingString:[key description]],
                                       [NSString stringWithFormat:@"%.0f/100", [score doubleValue] * 100])];
    }
    return rows;
}

- (void)build {
    NSDate *when = nil;
    NSDictionary *f = OhrtAboutFeatures(&when);
    NSMutableArray<NSString *> *titles = [NSMutableArray array];
    NSMutableArray<NSArray<OhrtAboutRow *> *> *sections = [NSMutableArray array];
    void (^section)(NSString *, NSArray<OhrtAboutRow *> *) = ^(NSString *title, NSArray<OhrtAboutRow *> *rows) {
        if (!rows.count) return;
        [titles addObject:title];
        [sections addObject:rows];
    };

    section(@"next open", @[ OhrtAboutPlain(@"instagram's guess", self.nextOpen ?: @"asking…") ]);

    NSMutableArray<OhrtAboutRow *> *rows = [NSMutableArray array];
    OhrtAboutAdd(rows, f, @"reels cohort", @"clips_cohort", NULL);
    OhrtAboutAdd(rows, f, @"reels segment", @"reels_user_cohort_segment_based_on_play_v2", NULL);
    OhrtAboutAdd(rows, f, @"predicted age", @"user_predicted_age", NULL);
    OhrtAboutAdd(rows, f, @"gender code", @"gender", NULL);
    OhrtAboutAdd(rows, f, @"teen, by its model", @"user_is_teen_model_based", NULL);
    OhrtAboutAdd(rows, f, @"active days of 28", @"user_l28_ig_classic_count", NULL);
    OhrtAboutAdd(rows, f, @"notes bucket", @"notes_inventory_bucket", NULL);
    section(@"how instagram files you", rows);

    rows = [NSMutableArray array];
    OhrtAboutAdd(rows, f, @"time in the app, 28 days", @"user_timespent_28d_sec", OhrtAboutTime);
    OhrtAboutAdd(rows, f, @"feed time, 1 day", @"user_feed_timespent_1d", OhrtAboutTime);
    OhrtAboutAdd(rows, f, @"stories time, 1 day", @"user_stories_timespent_1d", OhrtAboutTime);
    OhrtAboutAdd(rows, f, @"app opens, 7 days", @"core_foreground_session_count_l7", NULL);
    OhrtAboutAdd(rows, f, @"dms sent, 28 days", @"user_total_sends_28d", NULL);
    OhrtAboutAdd(rows, f, @"dms read, 28 days", @"user_total_message_reads_28d", NULL);
    OhrtAboutAdd(rows, f, @"posts shared by dm, 28 days", @"viewer_d28_direct_reshare_send", NULL);
    OhrtAboutAdd(rows, f, @"reels seen, 28 days", @"viewer_d28_instagram_clips_organic_impression", NULL);
    OhrtAboutAdd(rows, f, @"reels swiped past, 28 days", @"viewer_d28_instagram_clips_swipe_forward", NULL);
    OhrtAboutAdd(rows, f, @"videos finished, 28 days", @"viewer_d28_video_complete", NULL);
    OhrtAboutAdd(rows, f, @"explore days of 28", @"user_explore_l28", NULL);
    OhrtAboutAdd(rows, f, @"stories on offer, 28 days", @"user_story_inventory_28d", NULL);
    section(@"what you did", rows);

    rows = [NSMutableArray array];
    OhrtAboutAdd(rows, f, @"like rate, people you follow", @"user_feed_connected_like_rate_d28", OhrtAboutRate);
    OhrtAboutAdd(rows, f, @"profile tap rate", @"user_feed_connected_profile_tap_rate_d28", OhrtAboutRate);
    OhrtAboutAdd(rows, f, @"reshare rate", @"user_feed_connected_reshare_rate_d28", OhrtAboutRate);
    OhrtAboutAdd(rows, f, @"reel like rate in feed", @"user_feed_ifr_reels_like_rate_28d", OhrtAboutRate);
    OhrtAboutAdd(rows, f, @"reciprocal follow rate", @"user_reciprocal_follow_rate", OhrtAboutRate);
    section(@"your rates", rows);

    section(@"top bestie_coefficient", [self besties]);

    // Everything else it filled, under its own names.
    NSSet<NSString *> *shown = [NSSet setWithArray:@[
        @"clips_cohort", @"reels_user_cohort_segment_based_on_play_v2", @"user_predicted_age", @"gender", @"user_is_teen_model_based", @"user_l28_ig_classic_count", @"notes_inventory_bucket",
        @"user_timespent_28d_sec", @"user_feed_timespent_1d", @"user_stories_timespent_1d", @"core_foreground_session_count_l7", @"user_total_sends_28d", @"user_total_message_reads_28d",
        @"viewer_d28_direct_reshare_send", @"viewer_d28_instagram_clips_organic_impression", @"viewer_d28_instagram_clips_swipe_forward", @"viewer_d28_video_complete", @"user_explore_l28",
        @"user_story_inventory_28d", @"user_feed_connected_like_rate_d28", @"user_feed_connected_profile_tap_rate_d28", @"user_feed_connected_reshare_rate_d28", @"user_feed_ifr_reels_like_rate_28d",
        @"user_reciprocal_follow_rate"
    ]];
    rows = [NSMutableArray array];
    NSUInteger unfilled = 0;
    for (NSString *key in [[f allKeys] sortedArrayUsingSelector:@selector(compare:)]) {
        if (![key isKindOfClass:[NSString class]] || [shown containsObject:key]) continue;
        if (!OhrtAboutFilled(f[key])) {
            unfilled++;
            continue;
        }
        [rows addObject:OhrtAboutPlain(key, OhrtAboutNumber(f[key]))];
    }
    if (unfilled) [rows addObject:OhrtAboutPlain(@"left unfilled", [NSString stringWithFormat:@"%lu", (unsigned long)unfilled])];
    if (when) {
        NSDateFormatter *formatter = [NSDateFormatter new];
        formatter.locale = [NSLocale localeWithLocaleIdentifier:@"en_US_POSIX"];
        formatter.dateFormat = @"MM.dd.yy HH:mm";
        [rows addObject:OhrtAboutPlain(@"as of", [formatter stringFromDate:when])];
    }
    section(@"the rest, in instagram's words", rows);

    if (!f) section(@"nothing yet", @[ OhrtAboutPlain(@"profile", @"not on this phone yet, open the feed first") ]);
    self.titles = titles;
    self.rows = sections;
}

// The model's answer comes as a whole number and a fraction of minutes; the
// two agreed (161 and 161.18) when this was first asked.
- (void)askNextOpen {
    id casper = OhrtCall(OhrtCurrentSession(), @"casper");
    SEL estimate = NSSelectorFromString(@"estimateMinutesToNextTargetEventAfterBackground:completionQueue:");
    if (![casper respondsToSelector:estimate]) {
        self.nextOpen = @"not on this instagram";
        return;
    }
    __weak OhrtAboutViewController *weakSelf = self;
    void (^answer)(long long, float) = ^(long long whole, float minutes) {
        OhrtAboutViewController *strongSelf = weakSelf;
        if (!strongSelf) return;
        strongSelf.nextOpen = minutes >= 90 ? [NSString stringWithFormat:@"in %.0f min (%.1f h)", minutes, minutes / 60] : [NSString stringWithFormat:@"in %.0f min", minutes];
        OhrtTry(@"about", ^{
            [strongSelf build];
        });
        [strongSelf.tableView reloadData];
    };
    ((void (*)(id, SEL, id, id))objc_msgSend)(casper, estimate, (id)answer, dispatch_get_main_queue());
}

- (NSInteger)numberOfSectionsInTableView:(UITableView *)tableView {
    return self.rows.count;
}

- (NSInteger)tableView:(UITableView *)tableView numberOfRowsInSection:(NSInteger)section {
    return self.rows[section].count;
}

- (NSString *)tableView:(UITableView *)tableView titleForHeaderInSection:(NSInteger)section {
    return self.titles[section];
}

- (UITableViewCell *)tableView:(UITableView *)tableView cellForRowAtIndexPath:(NSIndexPath *)indexPath {
    UITableViewCell *cell = [tableView dequeueReusableCellWithIdentifier:@"row"] ?: [[UITableViewCell alloc] initWithStyle:UITableViewCellStyleValue1 reuseIdentifier:@"row"];
    OhrtAboutRow *row = self.rows[indexPath.section][indexPath.row];
    cell.textLabel.text = row.label;
    cell.textLabel.font = [UIFont systemFontOfSize:13];
    cell.textLabel.numberOfLines = 0;
    cell.detailTextLabel.text = row.value;
    cell.detailTextLabel.font = [UIFont monospacedDigitSystemFontOfSize:13 weight:UIFontWeightMedium];
    cell.detailTextLabel.textColor = OhrtFactsLineColour();
    return cell;
}

@end

UIViewController *OhrtAboutScreen(void) {
    return [OhrtAboutViewController new];
}
