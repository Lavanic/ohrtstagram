// Follow back: the accounts you follow that do not follow you.
//
// Both lists are read with Instagram's own list fetcher, the class its
// tagging screen uses for the same followers path, so every request is one
// the app builds and sends itself. Nothing here sees a token or a cookie,
// and nothing leaves the phone.
//
// Instagram meters these lists. Reading them twice in a row got an account
// rate limited, so: a check only starts by hand, pages are a few seconds
// apart, the two lists a minute apart, checks three hours apart, and a
// refusal means a long wait before the next try.
//
// Unfollowing is by hand, one account at a time, through Instagram's own
// follow controller.
#import <objc/message.h>
#import <objc/runtime.h>

#import "../../src/InstagramHeaders.h"
#import "Ohrt.h"
#import "OhrtLogic.h"

static const NSTimeInterval kOhrtBetweenChecks = 3 * 60 * 60;
static const NSTimeInterval kOhrtBetweenLists = 60;
static const NSTimeInterval kOhrtPageWait = 2;
static const NSTimeInterval kOhrtPageTimeout = 45;
static const unsigned kOhrtMaxPages = 600;
static const unsigned kOhrtMaxRetries = 3;

static NSString *OhrtKey(NSString *name, NSString *account) {
    return [NSString stringWithFormat:@"ohrt_followback_%@_%@", name, account];
}

static NSString *OhrtString(id value) {
    if ([value isKindOfClass:[NSString class]]) return value;
    if ([value respondsToSelector:@selector(stringValue)]) return [value stringValue];
    return nil;
}

static id OhrtFindController(UIViewController *root, Class cls) {
    if (!root) return nil;
    if ([root isKindOfClass:cls]) return root;
    for (UIViewController *child in root.childViewControllers) {
        id found = OhrtFindController(child, cls);
        if (found) return found;
    }
    return nil;
}

// The session of the account that is on screen.
static id OhrtCurrentSession(void) {
    Class tabBar = NSClassFromString(@"IGTabBarController");
    if (!tabBar) return nil;
    for (UIScene *scene in [UIApplication sharedApplication].connectedScenes) {
        if (![scene isKindOfClass:[UIWindowScene class]]) continue;
        for (UIWindow *window in ((UIWindowScene *)scene).windows) {
            id controller = OhrtFindController(window.rootViewController, tabBar);
            id session = OhrtCall(controller, @"userSession");
            if (session) return session;
        }
    }
    return nil;
}

#pragma mark - Reading one list

// self is consumed and the result is owned, as for any init.
typedef id (*OhrtListInit)(__attribute__((ns_consumed)) id, SEL, id, id, id) __attribute__((ns_returns_retained));
typedef id (*OhrtConfiguredInit)(__attribute__((ns_consumed)) id, SEL, id) __attribute__((ns_returns_retained));

typedef NS_ENUM(NSInteger, OhrtScanEnd) {
    OhrtScanEndWhole,
    OhrtScanEndRefused,
    OhrtScanEndInterrupted,
};

// True if the error, or one it wraps, is the connection's and not the
// server's.
static BOOL OhrtIsConnectionError(id error) {
    for (int depth = 0; depth < 4 && [error isKindOfClass:[NSError class]]; depth++) {
        if ([[(NSError *)error domain] isEqualToString:NSURLErrorDomain]) return YES;
        error = [(NSError *)error userInfo][NSUnderlyingErrorKey];
    }
    return NO;
}

@interface OhrtListScan : NSObject
// Account id to Instagram's user object, for every account read so far.
@property (nonatomic, strong) NSMutableDictionary<NSString *, id> *users;
@property (nonatomic, strong) id source;
@property (nonatomic, copy) void (^onProgress)(NSUInteger count);
@property (nonatomic, copy) void (^onDone)(OhrtScanEnd end);
@property (nonatomic, strong) NSMutableArray *observers;
@property (nonatomic) unsigned pages;
@property (nonatomic) unsigned emptyPages;
@property (nonatomic) unsigned retries;
@property (nonatomic) NSUInteger generation;
// A page has been asked for and not yet answered.
@property (nonatomic) BOOL awaiting;
// The app left the screen while that page was awaited.
@property (nonatomic) BOOL interrupted;
// A retry is waiting for the app to come back to the front.
@property (nonatomic) BOOL retryWhenActive;
@property (nonatomic) BOOL over;
@end

@implementation OhrtListScan

- (BOOL)startWithSession:(id)session path:(NSString *)path identifier:(NSString *)identifier {
    Class cls = NSClassFromString(@"IGUserListNetworkDataSource");
    SEL init = NSSelectorFromString(@"initWithUserSession:fetchPath:endpointLoggingIdentifier:");
    if (!cls || ![cls instancesRespondToSelector:init]) return NO;

    self.users = [NSMutableDictionary dictionary];
    self.source = ((OhrtListInit)objc_msgSend)([cls alloc], init, session, path, identifier);
    SEL setDelegate = NSSelectorFromString(@"setDelegate:");
    if (!self.source || ![self.source respondsToSelector:setDelegate]) return NO;
    ((void (*)(id, SEL, id))objc_msgSend)(self.source, setDelegate, self);

    __weak typeof(self) weakSelf = self;
    NSNotificationCenter *center = [NSNotificationCenter defaultCenter];
    self.observers = [NSMutableArray array];
    for (NSNotificationName name in @[ UIApplicationWillResignActiveNotification, UIApplicationDidEnterBackgroundNotification ]) {
        [self.observers addObject:[center addObserverForName:name object:nil queue:[NSOperationQueue mainQueue] usingBlock:^(NSNotification *note) {
            if (weakSelf.awaiting) weakSelf.interrupted = YES;
        }]];
    }
    [self.observers addObject:[center addObserverForName:UIApplicationDidBecomeActiveNotification object:nil queue:[NSOperationQueue mainQueue] usingBlock:^(NSNotification *note) {
        if (!weakSelf.retryWhenActive) return;
        weakSelf.retryWhenActive = NO;
        [weakSelf fetch];
    }]];
    [self fetch];
    return YES;
}

- (void)stopObserving {
    for (id observer in self.observers) [[NSNotificationCenter defaultCenter] removeObserver:observer];
    self.observers = nil;
}

- (void)dealloc {
    [self stopObserving];
}

- (void)fetch {
    if (self.over) return;
    NSUInteger generation = ++self.generation;
    self.awaiting = YES;
    self.interrupted = [UIApplication sharedApplication].applicationState != UIApplicationStateActive;
    // If the fetcher is still waiting on the last request, asking again
    // could make it skip a page, and a skipped page of followers is people
    // wrongly named. Its answer is waited for instead.
    if (!OhrtCallBool(self.source, @"loading")) OhrtCallVoid(self.source, @"fetchData");
    // If no answer comes at all, the check stops instead of hanging.
    __weak typeof(self) weakSelf = self;
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(kOhrtPageTimeout * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
        if (weakSelf.generation == generation) [weakSelf pageFailed:NO];
    });
}

- (void)cancel {
    self.over = YES;
    self.generation++;
    self.onDone = nil;
    self.onProgress = nil;
    [self stopObserving];
}

- (void)finish:(OhrtScanEnd)end {
    if (self.over) return;
    self.over = YES;
    self.generation++;
    [self stopObserving];
    void (^done)(OhrtScanEnd) = self.onDone;
    self.onDone = nil;
    if (done) done(end);
}

- (void)pageArrived {
    // One answer for each request. The fetcher may report a page twice,
    // once from its cache and once from the network.
    if (self.over || !self.awaiting) return;
    self.awaiting = NO;
    self.generation++;
    self.pages++;
    self.retries = 0;
    NSUInteger before = self.users.count;
    id results = OhrtCall(self.source, @"allResults");
    if ([results isKindOfClass:[NSArray class]]) {
        for (id user in (NSArray *)results) {
            NSString *account = OhrtString(OhrtCall(user, @"pk"));
            if (account.length && [OhrtCall(user, @"username") isKindOfClass:[NSString class]]) self.users[account] = user;
        }
    }
    if (self.onProgress) self.onProgress(self.users.count);

    unsigned empty = self.emptyPages;
    OhrtScanStep step = OhrtAfterPage(OhrtCallBool(self.source, @"moreAvailable"), before, self.users.count, &empty, self.pages, kOhrtMaxPages);
    self.emptyPages = empty;
    if (step == OhrtScanWhole) {
        [self finish:OhrtScanEndWhole];
        return;
    }
    if (step == OhrtScanGiveUp) {
        // More is promised but nothing new keeps coming: the list cannot be
        // trusted to be whole, and half a followers list would name people
        // who do follow you.
        OhrtLog(@"follow back: a list stopped growing after %u pages", self.pages);
        [self finish:OhrtScanEndRefused];
        return;
    }
    NSTimeInterval wait = kOhrtPageWait + arc4random_uniform(2000) / 1000.0;
    __weak typeof(self) weakSelf = self;
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(wait * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
        [weakSelf fetch];
    });
}

// A page failed, or never came.
- (void)pageFailed:(BOOL)connection {
    if (self.over || !self.awaiting) return;
    self.awaiting = NO;
    self.generation++;
    OhrtFailure failure = OhrtAfterFailure(self.interrupted || connection, self.retries, kOhrtMaxRetries);
    OhrtLog(@"follow back: a page failed (%@), %@", self.interrupted ? @"app left the screen" : connection ? @"connection" : @"no reason given",
            failure == OhrtFailRetry ? @"trying it again" : failure == OhrtFailInterrupted ? @"giving up without a penalty" : @"treating it as a refusal");
    if (failure == OhrtFailRefused) {
        [self finish:OhrtScanEndRefused];
        return;
    }
    if (failure == OhrtFailInterrupted) {
        [self finish:OhrtScanEndInterrupted];
        return;
    }
    self.retries++;
    if ([UIApplication sharedApplication].applicationState != UIApplicationStateActive) {
        self.retryWhenActive = YES;
        return;
    }
    __weak typeof(self) weakSelf = self;
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(5 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
        [weakSelf fetch];
    });
}

// Instagram's fetcher reports back through these three, on whatever thread
// it likes.
- (void)dataSourceDidStartLoading:(id)source {
}

- (void)dataSourceDidFinishLoading:(id)source {
    dispatch_async(dispatch_get_main_queue(), ^{
        if (!OhrtTry(@"follow back", ^{
                [self pageArrived];
            })) [self finish:OhrtScanEndInterrupted];
    });
}

- (void)dataSourceDidFailLoad:(id)source {
    dispatch_async(dispatch_get_main_queue(), ^{
        [self pageFailed:OhrtIsConnectionError(OhrtCall(self.source, @"fetchError"))];
    });
}

@end

#pragma mark - The check

typedef NS_ENUM(NSInteger, OhrtCheckState) {
    OhrtCheckIdle,
    OhrtCheckFollowers,
    OhrtCheckResting,
    OhrtCheckFollowing,
};

@interface OhrtFollowBack : NSObject
@property (nonatomic) OhrtCheckState state;
@property (nonatomic, copy) NSString *account;
@property (nonatomic, copy) NSString *note;
@property (nonatomic, copy) NSArray<NSDictionary *> *accounts;
// Instagram's user objects from a check made since the app started. The
// unfollow button needs one; an account only known from the saved list
// does not have it.
@property (nonatomic, strong) NSDictionary<NSString *, id> *live;
@property (nonatomic, strong) OhrtListScan *scan;
@property (nonatomic, strong) NSDictionary<NSString *, id> *followers;
@property (nonatomic, copy) void (^onChange)(void);
@end

@implementation OhrtFollowBack

+ (instancetype)shared {
    static OhrtFollowBack *shared;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        shared = [OhrtFollowBack new];
    });
    return shared;
}

- (NSString *)file {
    NSString *folder = [NSSearchPathForDirectoriesInDomains(NSApplicationSupportDirectory, NSUserDomainMask, YES).firstObject stringByAppendingPathComponent:@"ohrt"];
    [[NSFileManager defaultManager] createDirectoryAtPath:folder withIntermediateDirectories:YES attributes:nil error:nil];
    return [folder stringByAppendingPathComponent:[NSString stringWithFormat:@"followback-%@.plist", self.account]];
}

static NSString *OhrtSessionAccount(id session) {
    return OhrtString(OhrtCall(OhrtCall(session, @"user"), @"pk"));
}

// Points at the account on screen and loads what was saved for it.
- (BOOL)load {
    NSString *account = OhrtSessionAccount(OhrtCurrentSession());
    if (!account.length) return NO;
    if (![account isEqualToString:self.account]) {
        [self.scan cancel];
        self.scan = nil;
        self.followers = nil;
        self.state = OhrtCheckIdle;
        self.live = nil;
        self.note = nil;
        self.account = account;
        NSArray *saved = [NSArray arrayWithContentsOfFile:[self file]];
        self.accounts = [saved isKindOfClass:[NSArray class]] ? saved : nil;
    }
    return YES;
}

- (NSDate *)checkedAt {
    NSTimeInterval at = [[NSUserDefaults standardUserDefaults] doubleForKey:OhrtKey(@"checked_at", self.account)];
    return at > 0 ? [NSDate dateWithTimeIntervalSince1970:at] : nil;
}

// When the next check may start, or nil if it may start now.
- (NSDate *)availableAt {
    NSUserDefaults *defaults = [NSUserDefaults standardUserDefaults];
    NSTimeInterval at = OhrtNextCheckAt([NSDate date].timeIntervalSince1970, [defaults doubleForKey:OhrtKey(@"checked_at", self.account)],
                                        [defaults doubleForKey:OhrtKey(@"cooldown_until", self.account)], kOhrtBetweenChecks);
    return at > 0 ? [NSDate dateWithTimeIntervalSince1970:at] : nil;
}

- (void)changed {
    if (self.onChange) self.onChange();
}

- (void)stopWithNote:(NSString *)note {
    [self.scan cancel];
    self.scan = nil;
    self.followers = nil;
    self.state = OhrtCheckIdle;
    self.note = note;
    [self changed];
}

- (void)start {
    if (self.state != OhrtCheckIdle || ![self load] || [self availableAt]) return;
    NSString *missing = OhrtMissing(@"followback");
    if (missing) {
        [self stopWithNote:[NSString stringWithFormat:@"This Instagram version does not have what the check was written for (%@).", missing]];
        return;
    }
    self.followers = nil;
    self.note = nil;
    OhrtLog(@"follow back: check started");
    [self readList:@"followers" then:^(NSDictionary *followers) {
        self.followers = followers;
        self.state = OhrtCheckResting;
        [self changed];
        NSString *account = self.account;
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(kOhrtBetweenLists * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
            if (self.state != OhrtCheckResting || ![account isEqualToString:self.account]) return;
            [self readList:@"following" then:^(NSDictionary *following) {
                if (!OhrtTry(@"follow back", ^{
                        [self finishWithFollowing:following];
                    })) [self stopWithNote:@"The check could not finish on this Instagram version."];
            }];
        });
    }];
}

- (void)readList:(NSString *)list then:(void (^)(NSDictionary *users))then {
    id session = OhrtCurrentSession();
    // The account may have been switched since the check began.
    if (![OhrtSessionAccount(session) isEqualToString:self.account]) {
        [self stopWithNote:@"The account changed while the check was running, so it was stopped."];
        return;
    }
    OhrtListScan *scan = [OhrtListScan new];
    __weak typeof(self) weakSelf = self;
    __weak OhrtListScan *weakScan = scan;
    scan.onProgress = ^(NSUInteger count) {
        [weakSelf changed];
    };
    scan.onDone = ^(OhrtScanEnd end) {
        if (end == OhrtScanEndRefused) {
            [weakSelf refused];
        } else if (end == OhrtScanEndInterrupted) {
            [weakSelf stopWithNote:@"The check was interrupted: the app left the screen or the connection dropped. Nothing was saved. Start it again when it can run for a few minutes."];
        } else {
            then([weakScan.users copy] ?: @{});
        }
    };
    self.scan = scan;
    self.state = [list isEqualToString:@"followers"] ? OhrtCheckFollowers : OhrtCheckFollowing;
    // The same path and name Instagram's own screens use for these lists.
    NSString *path = [NSString stringWithFormat:@"/friendships/%@/%@/", self.account, list];
    NSString *identifier = [NSString stringWithFormat:@"friendships.api.views.%@", list];
    __block BOOL started = NO;
    OhrtTry(@"follow back", ^{
        started = [scan startWithSession:session path:path identifier:identifier];
    });
    if (!started) {
        [self stopWithNote:@"This Instagram version does not have the list reader this check was written for."];
        return;
    }
    [self changed];
}

// A list that Instagram stopped answering for, or that came back short. It
// does not say why, and the likeliest reason is its rate limit, so the wait
// before the next try grows: 12, 24, 48, then 72 hours.
- (void)refused {
    NSUserDefaults *defaults = [NSUserDefaults standardUserDefaults];
    NSInteger failures = [defaults integerForKey:OhrtKey(@"failures", self.account)] + 1;
    double hours = OhrtRefusalWaitHours(failures);
    [defaults setInteger:failures forKey:OhrtKey(@"failures", self.account)];
    [defaults setDouble:[NSDate date].timeIntervalSince1970 + hours * 3600 forKey:OhrtKey(@"cooldown_until", self.account)];
    OhrtLog(@"follow back: refused, next check in %.0f hours", hours);
    [self stopWithNote:[NSString stringWithFormat:@"Instagram stopped answering part way through. That is usually its rate limit, so the next check waits %.0f hours.", hours]];
}

static long OhrtCount(id boxed) {
    return [boxed respondsToSelector:@selector(integerValue)] ? (long)[boxed integerValue] : 0;
}

- (void)finishWithFollowing:(NSDictionary<NSString *, id> *)following {
    NSMutableArray<NSDictionary *> *accounts = [NSMutableArray array];
    NSMutableDictionary<NSString *, id> *live = [NSMutableDictionary dictionary];
    for (NSString *account in following) {
        if (self.followers[account]) continue;
        id user = following[account];
        NSString *username = OhrtCall(user, @"username");
        NSString *name = OhrtCall(user, @"fullName");
        [accounts addObject:@{
            @"pk" : account,
            @"username" : [username isKindOfClass:[NSString class]] ? username : @"",
            @"name" : [name isKindOfClass:[NSString class]] ? name : @"",
        }];
        live[account] = user;
    }
    [accounts sortUsingComparator:^NSComparisonResult(NSDictionary *a, NSDictionary *b) {
        return [a[@"username"] caseInsensitiveCompare:b[@"username"]];
    }];

    // Instagram's own count of followers, to hold the list against. A list
    // that came back short would name people who do follow you.
    id me = OhrtCall(OhrtCurrentSession(), @"user");
    long expected = OhrtCount(OhrtCall(me, @"followerCount"));
    NSMutableString *note = [NSMutableString stringWithFormat:@"Read %lu followers and %lu following.", (unsigned long)self.followers.count, (unsigned long)following.count];
    if (OhrtListLooksShort((long)self.followers.count, expected)) {
        [note appendFormat:@" Instagram counts %ld followers, so the list came back short and some accounts below may follow you after all.", expected];
    }
    OhrtLog(@"follow back: done, %lu followers, %lu following, %lu not following back", (unsigned long)self.followers.count, (unsigned long)following.count, (unsigned long)accounts.count);

    self.accounts = accounts;
    self.live = live;
    self.note = note;
    self.followers = nil;
    self.scan = nil;
    self.state = OhrtCheckIdle;
    [accounts writeToFile:[self file] atomically:YES];
    NSUserDefaults *defaults = [NSUserDefaults standardUserDefaults];
    [defaults setDouble:[NSDate date].timeIntervalSince1970 forKey:OhrtKey(@"checked_at", self.account)];
    [defaults setInteger:0 forKey:OhrtKey(@"failures", self.account)];
    [self changed];
}

- (void)remove:(NSString *)account {
    NSMutableArray *accounts = [self.accounts mutableCopy];
    [accounts filterUsingPredicate:[NSPredicate predicateWithBlock:^BOOL(NSDictionary *entry, NSDictionary *bindings) {
        return ![entry[@"pk"] isEqual:account];
    }]];
    self.accounts = accounts;
    [accounts writeToFile:[self file] atomically:YES];
    [self changed];
}

- (NSString *)status {
    switch (self.state) {
        case OhrtCheckFollowers:
            return [NSString stringWithFormat:@"Reading your followers: %lu so far", (unsigned long)self.scan.users.count];
        case OhrtCheckResting:
            return [NSString stringWithFormat:@"%lu followers read. Resting a minute before the second list.", (unsigned long)self.followers.count];
        case OhrtCheckFollowing:
            return [NSString stringWithFormat:@"Reading who you follow: %lu so far", (unsigned long)self.scan.users.count];
        case OhrtCheckIdle:
            break;
    }
    NSMutableArray<NSString *> *lines = [NSMutableArray array];
    NSDateFormatter *formatter = [NSDateFormatter new];
    formatter.dateStyle = NSDateFormatterMediumStyle;
    formatter.timeStyle = NSDateFormatterShortStyle;
    formatter.doesRelativeDateFormatting = YES;
    NSDate *checked = [self checkedAt];
    [lines addObject:checked ? [NSString stringWithFormat:@"Last checked %@.", [formatter stringFromDate:checked]] : @"Not checked yet."];
    if (self.note) [lines addObject:self.note];
    NSDate *available = [self availableAt];
    if (available) [lines addObject:[NSString stringWithFormat:@"The next check can start %@.", [formatter stringFromDate:available]]];
    return [lines componentsJoinedByString:@"\n"];
}

@end

#pragma mark - The screen

@interface OhrtFollowBackViewController : UITableViewController
// Kept alive while an unfollow is on its way.
@property (nonatomic, strong) NSMutableDictionary<NSString *, id> *controllers;
@property (nonatomic, strong) NSMutableSet<NSString *> *pending;
@end

@implementation OhrtFollowBackViewController

- (instancetype)init {
    self = [super initWithStyle:UITableViewStyleInsetGrouped];
    if (!self) return nil;
    self.title = @"Follow back";
    self.controllers = [NSMutableDictionary dictionary];
    self.pending = [NSMutableSet set];
    return self;
}

- (void)viewWillAppear:(BOOL)animated {
    [super viewWillAppear:animated];
    OhrtFollowBack *check = [OhrtFollowBack shared];
    [check load];
    __weak typeof(self) weakSelf = self;
    check.onChange = ^{
        [weakSelf.tableView reloadData];
    };
    [self.tableView reloadData];
}

- (void)viewDidDisappear:(BOOL)animated {
    [super viewDidDisappear:animated];
    [OhrtFollowBack shared].onChange = nil;
}

- (NSInteger)numberOfSectionsInTableView:(UITableView *)tableView {
    return 2;
}

- (NSInteger)tableView:(UITableView *)tableView numberOfRowsInSection:(NSInteger)section {
    return section == 0 ? 2 : [OhrtFollowBack shared].accounts.count;
}

- (NSString *)tableView:(UITableView *)tableView titleForHeaderInSection:(NSInteger)section {
    if (section == 0) return nil;
    NSArray *accounts = [OhrtFollowBack shared].accounts;
    return accounts ? [NSString stringWithFormat:@"Not following you back: %lu", (unsigned long)accounts.count] : nil;
}

- (NSString *)tableView:(UITableView *)tableView titleForFooterInSection:(NSInteger)section {
    if (section == 0) return @"Reads your followers and who you follow, slowly, with Instagram's own list reader. It takes a few minutes.";
    return [OhrtFollowBack shared].accounts.count ? @"Tap an account to open its profile." : nil;
}

- (UITableViewCell *)tableView:(UITableView *)tableView cellForRowAtIndexPath:(NSIndexPath *)indexPath {
    OhrtFollowBack *check = [OhrtFollowBack shared];
    UITableViewCell *cell = [[UITableViewCell alloc] initWithStyle:UITableViewCellStyleDefault reuseIdentifier:nil];
    UIListContentConfiguration *content = cell.defaultContentConfiguration;

    if (indexPath.section == 0) {
        if (indexPath.row == 0) {
            content.text = [check status];
            content.textProperties.font = [UIFont preferredFontForTextStyle:UIFontTextStyleSubheadline];
            content.textProperties.color = [UIColor secondaryLabelColor];
            cell.selectionStyle = UITableViewCellSelectionStyleNone;
        } else {
            BOOL ready = check.state == OhrtCheckIdle && ![check availableAt];
            content.text = check.state == OhrtCheckIdle ? @"Check now" : @"Checking…";
            content.textProperties.color = ready ? [UIColor systemBlueColor] : [UIColor tertiaryLabelColor];
            cell.selectionStyle = ready ? UITableViewCellSelectionStyleDefault : UITableViewCellSelectionStyleNone;
        }
        cell.contentConfiguration = content;
        return cell;
    }

    NSDictionary *entry = check.accounts[indexPath.row];
    NSString *account = entry[@"pk"];
    content.text = entry[@"username"];
    content.secondaryText = [entry[@"name"] length] ? entry[@"name"] : nil;
    cell.contentConfiguration = content;
    if (check.live[account] && OhrtAvailable(@"unfollow")) {
        UIButton *button = [UIButton buttonWithType:UIButtonTypeSystem];
        BOOL busy = [self.pending containsObject:account];
        [button setTitle:busy ? @"…" : @"Unfollow" forState:UIControlStateNormal];
        button.enabled = !busy;
        button.titleLabel.font = [UIFont systemFontOfSize:15 weight:UIFontWeightSemibold];
        button.tintColor = [UIColor systemRedColor];
        objc_setAssociatedObject(button, @selector(unfollowTapped:), account, OBJC_ASSOCIATION_COPY_NONATOMIC);
        [button addTarget:self action:@selector(unfollowTapped:) forControlEvents:UIControlEventTouchUpInside];
        [button sizeToFit];
        cell.accessoryView = button;
    } else {
        cell.accessoryType = UITableViewCellAccessoryDisclosureIndicator;
    }
    return cell;
}

- (void)tableView:(UITableView *)tableView didSelectRowAtIndexPath:(NSIndexPath *)indexPath {
    [tableView deselectRowAtIndexPath:indexPath animated:YES];
    OhrtFollowBack *check = [OhrtFollowBack shared];
    if (indexPath.section == 0) {
        if (indexPath.row == 1) [check start];
        return;
    }
    [self openProfile:check.accounts[indexPath.row][@"username"]];
}

// Instagram's own link for a profile, handed to the app delegate so it is
// this app that opens it and not another copy of Instagram on the phone.
- (void)openProfile:(NSString *)username {
    NSString *escaped = [username stringByAddingPercentEncodingWithAllowedCharacters:[NSCharacterSet URLQueryAllowedCharacterSet]];
    NSURL *url = [NSURL URLWithString:[NSString stringWithFormat:@"instagram://user?username=%@", escaped ?: @""]];
    if (!url) return;
    [self.presentingViewController dismissViewControllerAnimated:YES completion:^{
        UIApplication *application = [UIApplication sharedApplication];
        id<UIApplicationDelegate> delegate = application.delegate;
        if ([delegate respondsToSelector:@selector(application:openURL:options:)]) [delegate application:application openURL:url options:@{}];
    }];
}

- (void)unfollowTapped:(UIButton *)button {
    NSString *account = objc_getAssociatedObject(button, @selector(unfollowTapped:));
    OhrtFollowBack *check = [OhrtFollowBack shared];
    id user = check.live[account];
    if (!user) return;
    NSString *username = OhrtCall(user, @"username");
    UIAlertController *alert = [UIAlertController alertControllerWithTitle:[NSString stringWithFormat:@"Unfollow %@?", username] message:nil preferredStyle:UIAlertControllerStyleAlert];
    [alert addAction:[UIAlertAction actionWithTitle:@"Cancel" style:UIAlertActionStyleCancel handler:nil]];
    [alert addAction:[UIAlertAction actionWithTitle:@"Unfollow" style:UIAlertActionStyleDestructive handler:^(UIAlertAction *action) {
        [self unfollow:account user:user];
    }]];
    [self presentViewController:alert animated:YES completion:nil];
}

static NSInteger OhrtFollowStatus(id user) {
    SEL selector = NSSelectorFromString(@"followStatus");
    return [user respondsToSelector:selector] ? ((NSInteger (*)(id, SEL))objc_msgSend)(user, selector) : -1;
}

- (void)unfollow:(NSString *)account user:(id)user {
    __block BOOL sent = NO;
    BOOL ran = OhrtTry(@"unfollow", ^{
        sent = [self sendUnfollow:account user:user];
    });
    if (ran && sent) return;
    [self.pending removeObject:account];
    [self.controllers removeObjectForKey:account];
    [self.tableView reloadData];
    [self couldNotUnfollow:account];
}

// Hands the unfollow to Instagram's own follow controller, the object
// behind every Following button in the app. Returns NO if it could not be
// set up.
- (BOOL)sendUnfollow:(NSString *)account user:(id)user {
    Class configurationClass = NSClassFromString(@"IGFollowButtonViewConfiguration");
    Class controllerClass = NSClassFromString(@"IGFollowController");
    SEL init = NSSelectorFromString(@"initWithViewConfiguration:");
    SEL perform = NSSelectorFromString(@"_performUnfollow");
    id configuration = OhrtCall(configurationClass, @"defaultButtonConfiguration");
    id session = OhrtCurrentSession();
    if (!configuration || !session || ![controllerClass instancesRespondToSelector:init] || ![controllerClass instancesRespondToSelector:perform]) return NO;
    id controller = ((OhrtConfiguredInit)objc_msgSend)([controllerClass alloc], init, configuration);
    SEL setSession = NSSelectorFromString(@"setUserSession:");
    SEL setUser = NSSelectorFromString(@"setUser:");
    if (!controller || ![controller respondsToSelector:setSession] || ![controller respondsToSelector:setUser]) return NO;
    ((void (*)(id, SEL, id))objc_msgSend)(controller, setSession, session);
    ((void (*)(id, SEL, id))objc_msgSend)(controller, setUser, user);

    NSInteger before = OhrtFollowStatus(user);
    self.controllers[account] = controller;
    [self.pending addObject:account];
    [self.tableView reloadData];
    ((void (*)(id, SEL))objc_msgSend)(controller, perform);

    // Instagram changes the account's follow status when the unfollow goes
    // through. If it has not moved after a while, nothing is claimed.
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(4 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
        [self.pending removeObject:account];
        [self.controllers removeObjectForKey:account];
        BOOL moved = OhrtFollowStatus(user) != before;
        OhrtLog(@"unfollow: follow status %@", moved ? @"moved" : @"did not move");
        if (moved) [[OhrtFollowBack shared] remove:account];
        else [self couldNotUnfollow:account];
        [self.tableView reloadData];
    });
    return YES;
}

- (void)couldNotUnfollow:(NSString *)account {
    UIAlertController *alert = [UIAlertController alertControllerWithTitle:@"Not confirmed"
                                                                   message:@"Instagram did not report the unfollow going through. Open the profile to check, and unfollow there if it did not."
                                                            preferredStyle:UIAlertControllerStyleAlert];
    [alert addAction:[UIAlertAction actionWithTitle:@"OK" style:UIAlertActionStyleDefault handler:nil]];
    [self presentViewController:alert animated:YES completion:nil];
}

@end

UIViewController *OhrtFollowBackScreen(void) {
    return [OhrtFollowBackViewController new];
}
