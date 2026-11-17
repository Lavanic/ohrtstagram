// What a profile was like the last time you opened it, so that its line
// can say what has changed since: "+12 followers since 11.10.26",
// "was @old on 11.10.26".
//
// Each time a profile's header is shown, what it says now (username, name,
// bio, picture, private or not, and its three counts) is noted under the
// account's id, with when. A name, username, bio, picture or privacy that
// differs from what was noted before is kept as a change, with the last
// time the old one was seen. The counts are compared with what they were
// when this run of the app first showed the profile, so that they read the
// same however often the header is drawn while you are on it.
//
// It is kept in a file of the app's own on this phone. Only profiles you
// open are noted, and nothing is asked of Instagram for it.
#import "Ohrt.h"

static NSString *const kOhrtLookSeen = @"seen";
static NSString *const kOhrtLookValues = @"values";
static NSString *const kOhrtLookAt = @"at";
static NSString *const kOhrtLookChanges = @"changes";
static const NSUInteger kOhrtLookChangesKept = 20;
static const NSUInteger kOhrtLookPeopleKept = 6000;

// What is noted, and the method that gives it.
static NSArray<NSArray<NSString *> *> *OhrtLookFields(void) {
    return @[
        @[ @"username", @"username" ],
        @[ @"name", @"fullName" ],
        @[ @"bio", @"biography" ],
        @[ @"picture", @"profilePicId" ],
        @[ @"private", @"isPrivate" ],
        @[ @"followers", @"followerCount" ],
        @[ @"following", @"followingCount" ],
        @[ @"posts", @"mediaCount" ],
    ];
}

static BOOL OhrtLookIsCount(NSString *field) {
    return [field isEqualToString:@"followers"] || [field isEqualToString:@"following"] || [field isEqualToString:@"posts"];
}

static NSString *OhrtLookAccount(void) {
    id pk = OhrtCall(OhrtCall(OhrtCurrentSession(), @"user"), @"pk");
    return [pk isKindOfClass:[NSString class]] ? pk : [pk isKindOfClass:[NSNumber class]] ? [pk stringValue] : nil;
}

static NSString *OhrtLookPath(NSString *account) {
    NSString *support = NSSearchPathForDirectoriesInDomains(NSApplicationSupportDirectory, NSUserDomainMask, YES).firstObject;
    return [[support stringByAppendingPathComponent:@"ohrt"] stringByAppendingPathComponent:[NSString stringWithFormat:@"looked-%@.plist", account]];
}

// Everything below runs on the main thread only.

static NSMutableDictionary<NSString *, NSMutableDictionary *> *gOhrtLooks;
static NSString *gOhrtLooksAccount;
static BOOL gOhrtLooksUnsaved;
// What each profile was like before this run first showed it.
static NSMutableDictionary<NSString *, id> *gOhrtLooksBefore;

static void OhrtLooksSave(void);

static NSMutableDictionary *OhrtLookDeepCopy(NSDictionary *person) {
    NSMutableDictionary *copy = [NSMutableDictionary dictionary];
    for (NSString *key in person) {
        id value = person[key];
        if ([value isKindOfClass:[NSDictionary class]]) copy[key] = [value mutableCopy];
        else if ([value isKindOfClass:[NSArray class]]) copy[key] = [value mutableCopy];
        else copy[key] = value;
    }
    return copy;
}

static NSMutableDictionary<NSString *, NSMutableDictionary *> *OhrtLooks(void) {
    NSString *account = OhrtLookAccount();
    if (!account.length) return nil;
    if (gOhrtLooks && [gOhrtLooksAccount isEqualToString:account]) return gOhrtLooks;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        [[NSNotificationCenter defaultCenter] addObserverForName:UIApplicationWillResignActiveNotification object:nil queue:[NSOperationQueue mainQueue] usingBlock:^(NSNotification *note) {
            OhrtLooksSave();
        }];
    });
    // Another account: what the last one has unsaved is written first.
    OhrtLooksSave();
    gOhrtLooksAccount = [account copy];
    gOhrtLooks = [NSMutableDictionary dictionary];
    gOhrtLooksBefore = [NSMutableDictionary dictionary];
    NSDictionary *kept = [NSDictionary dictionaryWithContentsOfFile:OhrtLookPath(account)];
    for (NSString *pk in kept) {
        if ([pk isKindOfClass:[NSString class]] && [kept[pk] isKindOfClass:[NSDictionary class]]) gOhrtLooks[pk] = OhrtLookDeepCopy(kept[pk]);
    }
    OhrtLog(@"looks: %lu profiles noted before", (unsigned long)gOhrtLooks.count);
    return gOhrtLooks;
}

// The notes are made into a file here and written off the main thread.
static void OhrtLooksSave(void) {
    if (!gOhrtLooksUnsaved || !gOhrtLooks || !gOhrtLooksAccount.length) return;
    gOhrtLooksUnsaved = NO;
    if (gOhrtLooks.count > kOhrtLookPeopleKept) {
        NSArray<NSString *> *oldest = [gOhrtLooks keysSortedByValueUsingComparator:^NSComparisonResult(NSDictionary *one, NSDictionary *other) {
            return [@([one[kOhrtLookSeen] doubleValue]) compare:@([other[kOhrtLookSeen] doubleValue])];
        }];
        [gOhrtLooks removeObjectsForKeys:[oldest subarrayWithRange:NSMakeRange(0, gOhrtLooks.count - kOhrtLookPeopleKept)]];
    }
    NSData *data = [NSPropertyListSerialization dataWithPropertyList:gOhrtLooks format:NSPropertyListBinaryFormat_v1_0 options:0 error:nil];
    NSString *path = OhrtLookPath(gOhrtLooksAccount);
    if (!data) return;
    dispatch_async(dispatch_get_global_queue(QOS_CLASS_UTILITY, 0), ^{
        [[NSFileManager defaultManager] createDirectoryAtPath:path.stringByDeletingLastPathComponent withIntermediateDirectories:YES attributes:nil error:nil];
        if (![data writeToFile:path atomically:YES]) OhrtLog(@"looks: the notes could not be written");
    });
}

static void OhrtLooksChanged(void) {
    if (gOhrtLooksUnsaved) return;
    gOhrtLooksUnsaved = YES;
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(30 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
        OhrtLooksSave();
    });
}

// The day, or the time of day if it is today.
static NSString *OhrtLookWhen(id seconds) {
    NSDate *date = [NSDate dateWithTimeIntervalSince1970:[seconds doubleValue]];
    static NSDateFormatter *day, *time;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        day = [NSDateFormatter new];
        day.locale = [NSLocale localeWithLocaleIdentifier:@"en_US_POSIX"];
        day.dateFormat = @"MM.dd.yy";
        time = [NSDateFormatter new];
        time.locale = day.locale;
        time.dateFormat = @"HH:mm";
    });
    return [[NSCalendar currentCalendar] isDateInToday:date] ? [time stringFromDate:date] : [day stringFromDate:date];
}

// A value as it is noted: text with its ends trimmed, or a number. Empty
// text is taken as not sent, which is what an account seen only in passing
// (in the feed, in a list) gives for its bio.
static id OhrtLookValue(id user, NSString *getter) {
    id value = OhrtCallValue(user, getter);
    if ([value isKindOfClass:[NSString class]]) {
        NSString *trimmed = [value stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]];
        return trimmed.length ? trimmed : nil;
    }
    if ([value isKindOfClass:[NSNumber class]]) return value;
    return nil;
}

static NSString *OhrtLookShort(NSString *text, NSUInteger most) {
    NSString *flat = [[text componentsSeparatedByCharactersInSet:[NSCharacterSet newlineCharacterSet]] componentsJoinedByString:@" "];
    return flat.length > most ? [[flat substringToIndex:most - 1] stringByAppendingString:@"\u2026"] : flat;
}

static NSString *OhrtLookChangeText(NSDictionary *change) {
    NSString *field = change[@"field"];
    id old = change[@"old"], now = change[@"new"];
    NSString *when = OhrtLookWhen(change[@"was"]);
    if ([field isEqualToString:@"username"]) return [NSString stringWithFormat:@"was @%@ on %@", old, when];
    if ([field isEqualToString:@"name"]) return [NSString stringWithFormat:@"name was %@ on %@", old, when];
    if ([field isEqualToString:@"bio"]) return [NSString stringWithFormat:@"bio was \u201c%@\u201d on %@", OhrtLookShort(old, 48), when];
    if ([field isEqualToString:@"picture"]) return [@"new picture since " stringByAppendingString:when];
    if ([field isEqualToString:@"private"]) return [NSString stringWithFormat:@"went %@ since %@", [now boolValue] ? @"private" : @"public", when];
    return nil;
}

NSArray<NSString *> *OhrtLookedChanges(id user, NSString *pk) {
    NSMutableDictionary<NSString *, NSMutableDictionary *> *looks = OhrtLooks();
    if (!looks || !pk.length) return @[];
    NSNumber *now = @((long long)[NSDate date].timeIntervalSince1970);
    NSMutableDictionary *person = looks[pk];
    if (!gOhrtLooksBefore[pk]) gOhrtLooksBefore[pk] = person ? OhrtLookDeepCopy(person) : [NSNull null];
    if (!person) person = looks[pk] = [NSMutableDictionary dictionary];
    NSMutableDictionary *values = [person[kOhrtLookValues] isKindOfClass:[NSMutableDictionary class]] ? person[kOhrtLookValues] : (person[kOhrtLookValues] = [NSMutableDictionary dictionary]);
    NSMutableDictionary *at = [person[kOhrtLookAt] isKindOfClass:[NSMutableDictionary class]] ? person[kOhrtLookAt] : (person[kOhrtLookAt] = [NSMutableDictionary dictionary]);
    NSMutableArray *changes = [person[kOhrtLookChanges] isKindOfClass:[NSMutableArray class]] ? person[kOhrtLookChanges] : (person[kOhrtLookChanges] = [NSMutableArray array]);

    BOOL changed = NO;
    // Note what the profile says now, once it has loaded: an account seen
    // only in passing comes without its counts, and with a privacy that is
    // not to be trusted.
    if (![OhrtLookValue(user, @"followerCount") isKindOfClass:[NSNumber class]]) return @[];
    NSMutableDictionary *current = [NSMutableDictionary dictionary];
    for (NSArray<NSString *> *field in OhrtLookFields()) {
        id value = OhrtLookValue(user, field[1]);
        if (!value) continue;
        current[field[0]] = value;
        id old = values[field[0]];
        if (old && ![old isEqual:value] && !OhrtLookIsCount(field[0])) {
            [changes addObject:@{@"field" : field[0], @"old" : old, @"new" : value, @"was" : at[field[0]] ?: now, @"found" : now}];
            if (changes.count > kOhrtLookChangesKept) [changes removeObjectsInRange:NSMakeRange(0, changes.count - kOhrtLookChangesKept)];
            OhrtLog(@"looks: a profile's %@ changed since it was last opened", field[0]);
        }
        if (![values[field[0]] isEqual:value]) changed = YES;
        values[field[0]] = value;
        at[field[0]] = now;
    }
    // The file is written for a change, and otherwise at most hourly for
    // the times: the header is drawn many times a visit.
    if (current.count && (changed || now.doubleValue - [person[kOhrtLookSeen] doubleValue] > 3600)) {
        person[kOhrtLookSeen] = now;
        OhrtLooksChanged();
    }

    NSMutableArray<NSString *> *facts = [NSMutableArray array];

    // The counts, against what they were before this run first showed it.
    id before = gOhrtLooksBefore[pk];
    if ([before isKindOfClass:[NSDictionary class]]) {
        NSDictionary *was = before[kOhrtLookValues], *wasAt = before[kOhrtLookAt];
        NSMutableArray<NSString *> *moved = [NSMutableArray array];
        id since = nil;
        for (NSArray<NSString *> *names in @[ @[ @"followers", @"follower", @"followers" ], @[ @"following", @"following", @"following" ], @[ @"posts", @"post", @"posts" ] ]) {
            NSNumber *then = was[names[0]], *nowCount = current[names[0]];
            if (![then isKindOfClass:[NSNumber class]] || ![nowCount isKindOfClass:[NSNumber class]]) continue;
            long long change = nowCount.longLongValue - then.longLongValue;
            if (!change) continue;
            [moved addObject:[NSString stringWithFormat:@"%+lld %@", change, llabs(change) == 1 ? names[1] : names[2]]];
            if (!since) since = wasAt[names[0]];
        }
        if (moved.count && since) [facts addObject:[NSString stringWithFormat:@"%@ since %@", [moved componentsJoinedByString:@", "], OhrtLookWhen(since)]];
    }

    // The latest change of each kind, newest first.
    NSMutableSet<NSString *> *told = [NSMutableSet set];
    for (NSDictionary *change in changes.reverseObjectEnumerator) {
        if (![change isKindOfClass:[NSDictionary class]] || [told containsObject:change[@"field"] ?: @""]) continue;
        [told addObject:change[@"field"] ?: @""];
        NSString *text = OhrtLookChangeText(change);
        if (text) [facts addObject:text];
    }
    return facts;
}
