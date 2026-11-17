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

// The codes Instagram's own gender setting posts: its picker offers 1, 2, 4
// and 3, with words of your own only for 4.
static NSString *OhrtAboutGender(id value) {
    NSDictionary<NSNumber *, NSString *> *names = @{@1 : @"male", @2 : @"female", @3 : @"prefer not to say", @4 : @"custom"};
    NSString *name = [value isKindOfClass:[NSNumber class]] ? names[@([value integerValue])] : nil;
    return name ? [NSString stringWithFormat:@"%@ (%@)", name, value] : OhrtAboutNumber(value);
}

typedef NSString * (*OhrtAboutFormat)(id);

@interface OhrtAboutRow : NSObject
@property (nonatomic, copy) NSString *label, *value, *about;
@end

@implementation OhrtAboutRow
@end

@interface OhrtAboutViewController : UIViewController <UITableViewDataSource, UITableViewDelegate>
@property (nonatomic, strong) UITableView *tableView;
@property (nonatomic, strong) NSArray<NSString *> *titles, *notes;
@property (nonatomic, strong) NSArray<NSArray<OhrtAboutRow *> *> *rows;
@property (nonatomic, copy) NSString *nextOpen;
@end

@implementation OhrtAboutViewController

- (void)viewDidLoad {
    [super viewDidLoad];
    self.view.backgroundColor = [UIColor systemBackgroundColor];
    self.tableView = [[UITableView alloc] initWithFrame:CGRectZero style:UITableViewStyleInsetGrouped];
    self.tableView.dataSource = self;
    self.tableView.delegate = self;
    self.tableView.backgroundColor = [UIColor systemBackgroundColor];
    self.tableView.translatesAutoresizingMaskIntoConstraints = NO;
    [self.view addSubview:self.tableView];
    // Under the status bar and above the tab bar, wherever those are.
    UILayoutGuide *safe = self.view.safeAreaLayoutGuide;
    [NSLayoutConstraint activateConstraints:@[
        [self.tableView.topAnchor constraintEqualToAnchor:safe.topAnchor],
        [self.tableView.bottomAnchor constraintEqualToAnchor:safe.bottomAnchor],
        [self.tableView.leadingAnchor constraintEqualToAnchor:self.view.leadingAnchor],
        [self.tableView.trailingAnchor constraintEqualToAnchor:self.view.trailingAnchor],
    ]];

    UILabel *title = [UILabel new];
    title.text = @"about you";
    title.font = [UIFont systemFontOfSize:28 weight:UIFontWeightBold];
    UILabel *under = [UILabel new];
    under.text = @"What Insta⁠gram keeps about you on this phone and never shows. Tap a row to see what it means.";
    under.font = [UIFont systemFontOfSize:13];
    under.textColor = [UIColor secondaryLabelColor];
    under.numberOfLines = 0;
    UIStackView *stack = [[UIStackView alloc] initWithArrangedSubviews:@[ title, under ]];
    stack.axis = UILayoutConstraintAxisVertical;
    stack.spacing = 4;
    stack.layoutMargins = UIEdgeInsetsMake(12, 20, 4, 20);
    stack.layoutMarginsRelativeArrangement = YES;
    CGFloat width = [UIScreen mainScreen].bounds.size.width;
    CGSize fit = [stack systemLayoutSizeFittingSize:CGSizeMake(width, 0) withHorizontalFittingPriority:UILayoutPriorityRequired verticalFittingPriority:UILayoutPriorityFittingSizeLevel];
    stack.frame = CGRectMake(0, 0, width, fit.height);
    self.tableView.tableHeaderView = stack;
    [self refresh];
}

// Instagram's tab bar controller does not pass "will appear" on to a screen
// laid over it, so the screen fills itself as it loads.
- (void)refresh {
    OhrtTry(@"about", ^{
        [self build];
        [self askNextOpen];
    });
    [self.tableView reloadData];
    OhrtLog(@"about: %lu sections shown", (unsigned long)self.rows.count);
}

static OhrtAboutRow *OhrtAboutPlain(NSString *label, NSString *value, NSString *about) {
    OhrtAboutRow *row = [OhrtAboutRow new];
    row.label = label;
    row.value = value;
    row.about = about;
    return row;
}

static void OhrtAboutAdd(NSMutableArray<OhrtAboutRow *> *rows, NSDictionary *features, NSString *label, NSString *key, OhrtAboutFormat format, NSString *about) {
    id value = features[key];
    if (!OhrtAboutFilled(value)) return;
    NSString *named = [NSString stringWithFormat:@"%@\n\nInsta⁠gram's name for it: %@", about, key];
    [rows addObject:OhrtAboutPlain(label, format ? format(value) : OhrtAboutNumber(value), named)];
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
    NSString *about = [NSString stringWithFormat:@"The score Meta's servers give this account for how close you are, out of 100. It is one of %@ accounts scored for you, and Insta⁠gram uses the scores to "
                                                 @"order its suggestions, such as who to add to close friends and who to message. How the score is worked out stays on Meta's servers.\n\nInsta⁠gram's name for "
                                                 @"it: coefficient_besties_list_ranking",
                                                 OhrtGrouped((long long)scores.count)];
    NSMutableArray<OhrtAboutRow *> *rows = [NSMutableArray array];
    for (id key in ordered) {
        if (rows.count >= 15) break;
        id score = scores[key];
        if (![score isKindOfClass:[NSNumber class]]) continue;
        NSString *name = names[[key description]];
        [rows addObject:OhrtAboutPlain([NSString stringWithFormat:@"%lu. %@", (unsigned long)rows.count + 1, name ? [@"@" stringByAppendingString:name] : [@"id " stringByAppendingString:[key description]]],
                                       [NSString stringWithFormat:@"%.0f/100", [score doubleValue] * 100], about)];
    }
    return rows;
}

- (void)build {
    NSDate *when = nil;
    NSDictionary *f = OhrtAboutFeatures(&when);
    NSMutableArray<NSString *> *titles = [NSMutableArray array], *notes = [NSMutableArray array];
    NSMutableArray<NSArray<OhrtAboutRow *> *> *sections = [NSMutableArray array];
    void (^section)(NSString *, NSString *, NSArray<OhrtAboutRow *> *) = ^(NSString *title, NSString *note, NSArray<OhrtAboutRow *> *rows) {
        if (!rows.count) return;
        [titles addObject:title];
        [notes addObject:note];
        [sections addObject:rows];
    };

    section(@"when instagram expects you back", @"A model on your phone, called Casper in Insta⁠gram's code, guesses when you will next open the app, so that it can load things before you do.",
            @[ OhrtAboutPlain(@"next open", self.nextOpen ?: @"asking…",
                              @"Insta⁠gram's guess at how long until you next open the app. The model runs on your phone and looks at how often you opened the app over the last hour up to the "
                              @"last week, how long you stayed, the time of day, your unread messages and where you were when you last left. Insta⁠gram uses the guess to decide when to "
                              @"fetch new posts in the background.\n\nInsta⁠gram's name for it: IGCasper, minutes_to_next_target_event") ]);

    NSString *profile = @"Sent with your home feed about once a day.";
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
    OhrtAboutAdd(rows, f, @"teen, by its model", @"user_is_teen_model_based", NULL, @"Whether a model, as opposed to your stated birthday, takes you for a teenager. 0 is no.");
    OhrtAboutAdd(rows, f, @"days active, of the last 28", @"user_l28_ig_classic_count", NULL, @"On how many of the last 28 days you used Insta⁠gram.");
    OhrtAboutAdd(rows, f, @"notes on offer", @"notes_inventory_bucket", NULL, @"Roughly how many Notes there are to show you, as a range.");
    section(@"how instagram labels you", profile, rows);

    rows = [NSMutableArray array];
    OhrtAboutAdd(rows, f, @"time in the app", @"user_timespent_28d_sec", OhrtAboutTime, @"How long you had Insta⁠gram open over the last 28 days.");
    OhrtAboutAdd(rows, f, @"app opens, last 7 days", @"core_foreground_session_count_l7", NULL, @"How many times you brought Insta⁠gram to the front in the last 7 days.");
    OhrtAboutAdd(rows, f, @"feed time, one day", @"user_feed_timespent_1d", OhrtAboutTime, @"Time on the home feed in one day.");
    OhrtAboutAdd(rows, f, @"stories time, one day", @"user_stories_timespent_1d", OhrtAboutTime, @"Time watching stories in one day.");
    OhrtAboutAdd(rows, f, @"messages sent", @"user_total_sends_28d", NULL, @"Messages you sent in the last 28 days.");
    OhrtAboutAdd(rows, f, @"messages read", @"user_total_message_reads_28d", NULL, @"Messages you read in the last 28 days.");
    OhrtAboutAdd(rows, f, @"posts shared by message", @"viewer_d28_direct_reshare_send", NULL, @"Posts you sent to someone in a message in the last 28 days.");
    OhrtAboutAdd(rows, f, @"reels shown", @"viewer_d28_instagram_clips_organic_impression", NULL, @"Reels put in front of you in the last 28 days, not counting ads.");
    OhrtAboutAdd(rows, f, @"reels swiped past", @"viewer_d28_instagram_clips_swipe_forward", NULL, @"Times you swiped on to the next reel in the last 28 days.");
    OhrtAboutAdd(rows, f, @"videos watched to the end", @"viewer_d28_video_complete", NULL, @"Videos you watched all the way through in the last 28 days.");
    OhrtAboutAdd(rows, f, @"days you opened explore", @"user_explore_l28", NULL, @"On how many of the last 28 days you opened Explore.");
    OhrtAboutAdd(rows, f, @"stories available to you", @"user_story_inventory_28d", NULL, @"How many stories there were for you to watch in the last 28 days.");
    section(@"your last 28 days, as instagram counted", profile, rows);

    rows = [NSMutableArray array];
    OhrtAboutAdd(rows, f, @"posts you like", @"user_feed_connected_like_rate_d28", OhrtAboutRate, @"Of the posts shown to you from people you follow, the share you liked, over 28 days.");
    OhrtAboutAdd(rows, f, @"posts you tap through to a profile", @"user_feed_connected_profile_tap_rate_d28", OhrtAboutRate, @"The share of those posts where you tapped through to the profile.");
    OhrtAboutAdd(rows, f, @"posts you share", @"user_feed_connected_reshare_rate_d28", OhrtAboutRate, @"The share of those posts you sent to someone.");
    OhrtAboutAdd(rows, f, @"suggested reels you like", @"user_feed_ifr_reels_like_rate_28d", OhrtAboutRate, @"Of the reels Insta⁠gram suggested in your feed, the share you liked.");
    OhrtAboutAdd(rows, f, @"follows that follow back", @"user_reciprocal_follow_rate", OhrtAboutRate, @"Of the accounts you follow, the share that follow you back.");
    section(@"how often you react", profile, rows);

    section(@"who instagram thinks you're closest to", @"Your highest bestie_coefficient scores. Meta's servers work them out and send them to your phone.", [self besties]);

    // Everything else it filled, under its own names.
    NSMutableSet<NSString *> *shown = [NSMutableSet setWithArray:@[
        @"clips_cohort", @"reels_user_cohort_segment_based_on_play_v2", @"user_predicted_age", @"gender", @"user_is_teen_model_based", @"user_l28_ig_classic_count", @"notes_inventory_bucket",
        @"user_timespent_28d_sec", @"user_feed_timespent_1d", @"user_stories_timespent_1d", @"core_foreground_session_count_l7", @"user_total_sends_28d", @"user_total_message_reads_28d",
        @"viewer_d28_direct_reshare_send", @"viewer_d28_instagram_clips_organic_impression", @"viewer_d28_instagram_clips_swipe_forward", @"viewer_d28_video_complete", @"user_explore_l28",
        @"user_story_inventory_28d", @"user_feed_connected_like_rate_d28", @"user_feed_connected_profile_tap_rate_d28", @"user_feed_connected_reshare_rate_d28", @"user_feed_ifr_reels_like_rate_28d",
        @"user_reciprocal_follow_rate"
    ]];
    NSString *raw = @"One of the values Insta⁠gram stores about you, under the name Meta gave it. In those names l7 and l28 mean the last 7 and 28 days, d28 and d84 a total over that many days, clips "
                    @"means Reels, connected means from people you follow, and organic means not an ad.";
    rows = [NSMutableArray array];
    NSUInteger unfilled = 0;
    for (NSString *key in [[f allKeys] sortedArrayUsingSelector:@selector(compare:)]) {
        if (![key isKindOfClass:[NSString class]] || [shown containsObject:key]) continue;
        if (!OhrtAboutFilled(f[key])) {
            unfilled++;
            continue;
        }
        [rows addObject:OhrtAboutPlain(key, OhrtAboutNumber(f[key]), raw)];
    }
    NSString *rest = unfilled ? [NSString stringWithFormat:@"In Meta's own names. %lu more were left unfilled.", (unsigned long)unfilled] : @"In Meta's own names.";
    if (when) {
        NSDateFormatter *formatter = [NSDateFormatter new];
        formatter.locale = [NSLocale localeWithLocaleIdentifier:@"en_US_POSIX"];
        formatter.dateFormat = @"MM.dd.yy HH:mm";
        rest = [rest stringByAppendingFormat:@" Last sent %@.", [formatter stringFromDate:when]];
    }
    section(@"everything else it stores", rest, rows);

    if (!f) section(@"nothing yet", @"The profile comes with the home feed. Open the feed, then come back.", @[ OhrtAboutPlain(@"profile", @"not here yet", @"Insta⁠gram has not sent it to this phone yet.") ]);
    self.titles = titles;
    self.notes = notes;
    self.rows = sections;
}

// The model's answer comes as a whole number and a fraction of minutes; the
// two agreed (161 and 161.18) when this was first asked.
- (void)askNextOpen {
    id casper = OhrtCall(OhrtCurrentSession(), @"casper");
    SEL estimate = NSSelectorFromString(@"estimateMinutesToNextTargetEventAfterBackground:completionQueue:");
    if (![casper respondsToSelector:estimate]) {
        self.nextOpen = @"not on this version";
        return;
    }
    __weak OhrtAboutViewController *weakSelf = self;
    void (^answer)(long long, float) = ^(long long whole, float minutes) {
        OhrtAboutViewController *strongSelf = weakSelf;
        if (!strongSelf) return;
        strongSelf.nextOpen = minutes >= 90 ? [NSString stringWithFormat:@"in %.1f hours", minutes / 60] : [NSString stringWithFormat:@"in %.0f minutes", minutes];
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

- (NSString *)tableView:(UITableView *)tableView titleForFooterInSection:(NSInteger)section {
    return self.notes[section];
}

- (UITableViewCell *)tableView:(UITableView *)tableView cellForRowAtIndexPath:(NSIndexPath *)indexPath {
    UITableViewCell *cell = [tableView dequeueReusableCellWithIdentifier:@"row"] ?: [[UITableViewCell alloc] initWithStyle:UITableViewCellStyleValue1 reuseIdentifier:@"row"];
    OhrtAboutRow *row = self.rows[indexPath.section][indexPath.row];
    cell.backgroundColor = [UIColor secondarySystemBackgroundColor];
    cell.textLabel.text = row.label;
    cell.textLabel.font = [UIFont systemFontOfSize:14];
    cell.textLabel.numberOfLines = 0;
    cell.detailTextLabel.text = row.value;
    cell.detailTextLabel.font = [UIFont monospacedDigitSystemFontOfSize:14 weight:UIFontWeightSemibold];
    cell.detailTextLabel.textColor = OhrtFactsLineColour();
    return cell;
}

- (void)tableView:(UITableView *)tableView didSelectRowAtIndexPath:(NSIndexPath *)indexPath {
    [tableView deselectRowAtIndexPath:indexPath animated:YES];
    OhrtAboutRow *row = self.rows[indexPath.section][indexPath.row];
    if (!row.about.length) return;
    UIAlertController *alert = [UIAlertController alertControllerWithTitle:[NSString stringWithFormat:@"%@: %@", row.label, row.value] message:row.about preferredStyle:UIAlertControllerStyleAlert];
    [alert addAction:[UIAlertAction actionWithTitle:@"OK" style:UIAlertActionStyleDefault handler:nil]];
    [self presentViewController:alert animated:YES completion:nil];
}

@end

UIViewController *OhrtAboutScreen(void) {
    return [OhrtAboutViewController new];
}
