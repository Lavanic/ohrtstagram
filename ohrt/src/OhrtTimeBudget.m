// Daily time budget: once today's time in the app passes the budget, a
// screen covers it. "Five more minutes" is always there, because the point
// is to notice, not to lock you out of your messages.
//
// Time is counted only while the app is active, in a few numbers kept in
// the app's own preferences. Nothing here touches Instagram's classes, so
// it does not depend on the Instagram version.
#import <QuartzCore/QuartzCore.h>

#import "../../src/Utils.h"
#import "Ohrt.h"
#import "OhrtLogic.h"

NSString *const kOhrtBudgetMinutesKey = @"ohrt_time_budget_minutes";

static NSString *const kOhrtDayKey = @"ohrt_time_day";
static NSString *const kOhrtSecondsKey = @"ohrt_time_seconds";
// The point in today's count that "five more minutes" lifted the lock to.
static NSString *const kOhrtAllowedUntilKey = @"ohrt_time_allowed_until";

static const NSTimeInterval kOhrtTick = 5.0;
static const NSInteger kOhrtExtraStep = 5;

// Time counted but not yet written down. Every write to the preferences
// tells the whole app they changed, Instagram's own listeners included, so
// the count is written twice a minute and when the app is left, not on
// every tick.
static NSTimeInterval gOhrtUnsaved;
static const NSTimeInterval kOhrtSaveEvery = 30.0;

static NSString *OhrtToday(void) {
    static NSDateFormatter *formatter;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        formatter = [NSDateFormatter new];
        formatter.locale = [NSLocale localeWithLocaleIdentifier:@"en_US_POSIX"];
        formatter.dateFormat = @"yyyy-MM-dd";
    });
    return [formatter stringFromDate:[NSDate date]];
}

// A new day starts the count, and the extra minutes, again.
static void OhrtRollDay(void) {
    NSUserDefaults *defaults = [NSUserDefaults standardUserDefaults];
    NSString *today = OhrtToday();
    if ([[defaults stringForKey:kOhrtDayKey] isEqualToString:today]) return;
    [defaults setObject:today forKey:kOhrtDayKey];
    [defaults setDouble:0 forKey:kOhrtSecondsKey];
    [defaults setDouble:0 forKey:kOhrtAllowedUntilKey];
    gOhrtUnsaved = 0;
}

static void OhrtSaveTime(void) {
    if (gOhrtUnsaved <= 0) return;
    NSUserDefaults *defaults = [NSUserDefaults standardUserDefaults];
    [defaults setDouble:[defaults doubleForKey:kOhrtSecondsKey] + gOhrtUnsaved forKey:kOhrtSecondsKey];
    gOhrtUnsaved = 0;
}

NSTimeInterval OhrtTimeSpentToday(void) {
    OhrtRollDay();
    return [[NSUserDefaults standardUserDefaults] doubleForKey:kOhrtSecondsKey] + gOhrtUnsaved;
}

NSString *OhrtFormatDuration(NSTimeInterval seconds) {
    char text[32];
    OhrtDurationText(seconds, text, sizeof(text));
    return @(text);
}

@interface OhrtLockViewController : UIViewController
@property (nonatomic, copy) void (^onMore)(void);
@property (nonatomic, strong) UILabel *titleLabel;
@property (nonatomic, strong) UILabel *detailLabel;
@end

@implementation OhrtLockViewController

- (void)viewDidLoad {
    [super viewDidLoad];
    self.view.backgroundColor = [UIColor blackColor];

    self.titleLabel = [UILabel new];
    self.titleLabel.font = [UIFont systemFontOfSize:28 weight:UIFontWeightBold];
    self.titleLabel.textColor = OhrtColor(OHRT_WHITE);
    self.titleLabel.textAlignment = NSTextAlignmentCenter;

    self.detailLabel = [UILabel new];
    self.detailLabel.font = [UIFont systemFontOfSize:15];
    self.detailLabel.textColor = OhrtColor(OHRT_TEXT);
    self.detailLabel.textAlignment = NSTextAlignmentCenter;
    self.detailLabel.numberOfLines = 0;

    UIButton *more = [UIButton buttonWithType:UIButtonTypeSystem];
    [more setTitle:[NSString stringWithFormat:@"%ld more minutes", (long)kOhrtExtraStep] forState:UIControlStateNormal];
    more.titleLabel.font = [UIFont systemFontOfSize:16 weight:UIFontWeightSemibold];
    more.tintColor = OhrtColor(OHRT_BODY);
    more.backgroundColor = OhrtColor(OHRT_BLACK);
    more.layer.borderColor = OhrtColor(OHRT_LINE).CGColor;
    more.layer.borderWidth = 1;
    more.layer.cornerRadius = 12;
    more.contentEdgeInsets = UIEdgeInsetsMake(13, 24, 13, 24);
    [more addTarget:self action:@selector(moreTapped) forControlEvents:UIControlEventTouchUpInside];

    UIStackView *stack = [[UIStackView alloc] initWithArrangedSubviews:@[ self.titleLabel, self.detailLabel, more ]];
    stack.axis = UILayoutConstraintAxisVertical;
    stack.alignment = UIStackViewAlignmentCenter;
    stack.spacing = 14;
    [stack setCustomSpacing:26 afterView:self.detailLabel];
    stack.translatesAutoresizingMaskIntoConstraints = NO;
    [self.view addSubview:stack];
    [NSLayoutConstraint activateConstraints:@[
        [stack.centerYAnchor constraintEqualToAnchor:self.view.centerYAnchor],
        [stack.leadingAnchor constraintEqualToAnchor:self.view.leadingAnchor constant:32],
        [stack.trailingAnchor constraintEqualToAnchor:self.view.trailingAnchor constant:-32],
    ]];
}

- (void)moreTapped {
    if (self.onMore) self.onMore();
}

- (UIStatusBarStyle)preferredStatusBarStyle {
    return UIStatusBarStyleLightContent;
}

@end

@interface OhrtTimeBudget : NSObject
@property (nonatomic, strong) NSTimer *timer;
@property (nonatomic) CFTimeInterval lastTick;
@property (nonatomic, strong) UIWindow *lockWindow;
@end

@implementation OhrtTimeBudget

+ (instancetype)shared {
    static OhrtTimeBudget *shared;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        shared = [OhrtTimeBudget new];
    });
    return shared;
}

- (void)start {
    NSNotificationCenter *center = [NSNotificationCenter defaultCenter];
    [center addObserver:self selector:@selector(becameActive) name:UIApplicationDidBecomeActiveNotification object:nil];
    [center addObserver:self selector:@selector(resignedActive) name:UIApplicationWillResignActiveNotification object:nil];
    if ([UIApplication sharedApplication].applicationState == UIApplicationStateActive) [self becameActive];
}

- (void)becameActive {
    self.lastTick = CACurrentMediaTime();
    [self.timer invalidate];
    // In the common modes, or it would stand still for as long as a list is
    // being scrolled, which is most of the time in this app.
    self.timer = [NSTimer timerWithTimeInterval:kOhrtTick target:self selector:@selector(tick) userInfo:nil repeats:YES];
    [[NSRunLoop mainRunLoop] addTimer:self.timer forMode:NSRunLoopCommonModes];
    [self evaluate];
}

- (void)resignedActive {
    [self tick];
    OhrtSaveTime();
    [self.timer invalidate];
    self.timer = nil;
}

- (void)tick {
    CFTimeInterval now = CACurrentMediaTime();
    CFTimeInterval elapsed = OhrtCountedTime(now - self.lastTick, kOhrtTick);
    self.lastTick = now;

    OhrtRollDay();
    gOhrtUnsaved += elapsed;
    if (gOhrtUnsaved >= kOhrtSaveEvery) OhrtSaveTime();
    [self evaluate];
}

- (NSInteger)budgetMinutes {
    return (NSInteger)[SCIUtils getDoublePref:kOhrtBudgetMinutesKey];
}

- (void)evaluate {
    NSInteger budget = [self budgetMinutes];
    NSTimeInterval spent = OhrtTimeSpentToday();
    double allowedUntil = [[NSUserDefaults standardUserDefaults] doubleForKey:kOhrtAllowedUntilKey];
    if (OhrtOverBudget(spent, budget, allowedUntil)) [self showLockForBudget:budget spent:spent];
    else [self hideLock];
}

- (UIWindowScene *)activeScene {
    UIWindowScene *fallback = nil;
    for (UIScene *scene in [UIApplication sharedApplication].connectedScenes) {
        if (![scene isKindOfClass:[UIWindowScene class]]) continue;
        if (scene.activationState == UISceneActivationStateForegroundActive) return (UIWindowScene *)scene;
        if (!fallback) fallback = (UIWindowScene *)scene;
    }
    return fallback;
}

- (void)showLockForBudget:(NSInteger)budget spent:(NSTimeInterval)spent {
    if (!self.lockWindow) {
        UIWindowScene *scene = [self activeScene];
        if (!scene) return;
        OhrtLockViewController *controller = [OhrtLockViewController new];
        __weak typeof(self) weakSelf = self;
        controller.onMore = ^{
            // Five minutes from now, however long the lock has been up.
            double allowedUntil = OhrtAllowedAfterMore(OhrtTimeSpentToday(), kOhrtExtraStep);
            [[NSUserDefaults standardUserDefaults] setDouble:allowedUntil forKey:kOhrtAllowedUntilKey];
            [weakSelf evaluate];
        };
        UIWindow *window = [[UIWindow alloc] initWithWindowScene:scene];
        // Above the app and its sheets, below system alerts.
        window.windowLevel = UIWindowLevelStatusBar + 50;
        window.rootViewController = controller;
        self.lockWindow = window;
        // The keyboard sits above every window of the app, this one too.
        [[UIApplication sharedApplication] sendAction:@selector(resignFirstResponder) to:nil from:nil forEvent:nil];
        OhrtLog(@"time budget: %ld minutes reached, lock shown", (long)budget);
    }
    OhrtLockViewController *controller = (OhrtLockViewController *)self.lockWindow.rootViewController;
    [controller loadViewIfNeeded];
    controller.titleLabel.text = [NSString stringWithFormat:@"That's %@ today", OhrtFormatDuration(spent)];
    controller.detailLabel.text = [NSString stringWithFormat:@"You set a budget of %ld minutes a day.", (long)budget];
    self.lockWindow.hidden = NO;
}

- (void)hideLock {
    if (!self.lockWindow) return;
    self.lockWindow.hidden = YES;
    self.lockWindow = nil;
}

@end

__attribute__((constructor)) static void OhrtTimeBudgetLoad(void) {
    // The application object does not exist yet when the tweak is loaded.
    dispatch_async(dispatch_get_main_queue(), ^{
        [[OhrtTimeBudget shared] start];
    });
}
