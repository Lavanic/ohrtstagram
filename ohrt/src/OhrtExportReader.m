// Reads an unpacked Instagram export on the phone. The same job as
// ohrt/tools/export.py, file for file, so the two give the same answer for
// the same export: one entry per account with the days and counts, and one
// per conversation with one other person. Dates and counts only.
//
// The export's layout is not documented. Each file is read for the shape it
// had in November 2026 (ohrt/tests/export_test.py has one of each), and a
// file that is missing or shaped otherwise is skipped.
#import "Ohrt.h"

static id OhrtReadJSON(NSURL *url) {
    NSData *data = [NSData dataWithContentsOfURL:url options:NSDataReadingMappedIfSafe error:nil];
    return data ? [NSJSONSerialization JSONObjectWithData:data options:0 error:nil] : nil;
}

// The export writes UTF-8 names out byte by byte. This puts them back.
static NSString *OhrtMended(id text) {
    if (![text isKindOfClass:[NSString class]]) return @"";
    NSData *bytes = [text dataUsingEncoding:NSISOLatin1StringEncoding allowLossyConversion:NO];
    NSString *mended = bytes ? [[NSString alloc] initWithData:bytes encoding:NSUTF8StringEncoding] : nil;
    return mended ?: text;
}

static NSDictionary *OhrtDict(id value) {
    return [value isKindOfClass:[NSDictionary class]] ? value : nil;
}

static NSArray *OhrtList(id value) {
    return [value isKindOfClass:[NSArray class]] ? value : nil;
}

static NSString *OhrtWord(id value) {
    return [value isKindOfClass:[NSString class]] && [value length] ? value : nil;
}

static double OhrtNumber(id value) {
    return [value isKindOfClass:[NSNumber class]] ? [value doubleValue] : 0;
}

// The entry with this label. One that holds other entries has a title
// instead.
static NSDictionary *OhrtLabelled(id values, NSString *label) {
    for (id value in OhrtList(values)) {
        NSDictionary *entry = OhrtDict(value);
        if ([entry[@"label"] isEqual:label] || [entry[@"title"] isEqual:label]) return entry;
    }
    return nil;
}

static NSString *OhrtUsernameOf(NSDictionary *item) {
    return OhrtWord(OhrtLabelled(item[@"label_values"], @"Username")[@"value"]);
}

// The account whose post or story an entry is about.
static NSString *OhrtOwnerOf(NSDictionary *item) {
    for (id entry in OhrtList(OhrtLabelled(item[@"label_values"], @"Owner")[@"dict"])) {
        NSString *name = OhrtWord(OhrtLabelled(OhrtDict(entry)[@"dict"], @"Username")[@"value"]);
        if (name) return name;
    }
    return nil;
}

// The list inside a file, whether it is the file or sits under one key.
static NSArray *OhrtEntries(id data) {
    if (OhrtList(data)) return data;
    NSDictionary *dict = OhrtDict(data);
    if (!dict) return @[];
    NSMutableArray *lists = [NSMutableArray array];
    for (id value in dict.allValues) {
        if (OhrtList(value)) [lists addObject:value];
    }
    if (lists.count == 1 && !dict[@"label_values"]) return lists[0];
    return @[ dict ];
}

@interface OhrtExportFacts : NSObject
@property (nonatomic, strong) NSMutableDictionary<NSString *, NSMutableDictionary *> *people;
@property (nonatomic, strong) NSMutableArray<NSString *> *read;
@end

@implementation OhrtExportFacts

- (instancetype)init {
    if ((self = [super init])) {
        _people = [NSMutableDictionary dictionary];
        _read = [NSMutableArray array];
    }
    return self;
}

- (NSMutableDictionary *)person:(NSString *)username {
    NSString *key = [username stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]].lowercaseString;
    NSMutableDictionary *person = self.people[key];
    if (!person) person = self.people[key] = [NSMutableDictionary dictionary];
    return person;
}

// One day per account: the earliest seen, or the latest.
- (void)date:(NSString *)username key:(NSString *)key stamp:(double)stamp earliest:(BOOL)earliest {
    if (!username.length || !(stamp > 0)) return;
    NSMutableDictionary *person = [self person:username];
    NSNumber *held = person[key];
    if (!held || (earliest ? stamp < held.doubleValue : stamp > held.doubleValue)) person[key] = @((long long)stamp);
}

// How often, and from when to when: [count, first, last].
- (void)count:(NSString *)username key:(NSString *)key stamp:(double)stamp {
    if (!username.length) return;
    NSMutableDictionary *person = [self person:username];
    NSMutableArray<NSNumber *> *tally = person[key];
    if (!tally) tally = person[key] = [@[ @0, @0, @0 ] mutableCopy];
    tally[0] = @(tally[0].longLongValue + 1);
    if (stamp > 0) {
        long long when = (long long)stamp, first = tally[1].longLongValue;
        tally[1] = @(first == 0 || when < first ? when : first);
        if (when > tally[2].longLongValue) tally[2] = @(when);
    }
}

// Reads every entry of the given files. `handle` says whether an entry
// counted.
- (void)each:(NSArray<NSURL *> *)files what:(NSString *)what handle:(BOOL (^)(NSDictionary *item))handle {
    if (!files.count) return;
    NSUInteger total = 0;
    for (NSURL *file in files) {
        @autoreleasepool {
            for (id item in OhrtEntries(OhrtReadJSON(file))) {
                NSDictionary *entry = OhrtDict(item);
                if (entry && handle(entry)) total++;
            }
        }
    }
    [self.read addObject:[NSString stringWithFormat:@"%lu %@", (unsigned long)total, what]];
}

@end

// The files in a folder of the export whose names begin and end as given,
// in name order.
static NSArray<NSURL *> *OhrtFiles(NSURL *root, NSString *folder, NSString *prefix, BOOL numbered) {
    NSURL *directory = [root URLByAppendingPathComponent:folder isDirectory:YES];
    NSArray<NSURL *> *found = [[NSFileManager defaultManager] contentsOfDirectoryAtURL:directory includingPropertiesForKeys:nil options:0 error:nil];
    NSMutableArray<NSURL *> *kept = [NSMutableArray array];
    for (NSURL *file in found) {
        NSString *name = file.lastPathComponent;
        if (![name hasPrefix:prefix] || ![name hasSuffix:@".json"]) continue;
        // "following_2.json" is more of the same list. "following_hashtags.json" is not accounts.
        if (numbered && (name.length <= prefix.length || !isdigit([name characterAtIndex:prefix.length]))) continue;
        [kept addObject:file];
    }
    [kept sortUsingComparator:^NSComparisonResult(NSURL *a, NSURL *b) {
        return [a.lastPathComponent compare:b.lastPathComponent];
    }];
    return kept;
}

static NSArray<NSURL *> *OhrtFile(NSURL *root, NSString *path) {
    NSURL *file = [root URLByAppendingPathComponent:path];
    return [[NSFileManager defaultManager] fileExistsAtPath:file.path] ? @[ file ] : @[];
}

static void OhrtReadPeople(NSURL *root, OhrtExportFacts *facts) {
    NSString *follows = @"connections/followers_and_following";
    NSString *activity = @"your_instagram_activity";

    BOOL (^following)(NSDictionary *) = ^BOOL(NSDictionary *item) {
        NSString *name = OhrtWord(item[@"title"]);
        double first = 0;
        for (id value in OhrtList(item[@"string_list_data"])) {
            NSDictionary *entry = OhrtDict(value);
            if (!name) name = OhrtWord(entry[@"value"]);
            double stamp = OhrtNumber(entry[@"timestamp"]);
            if (stamp > 0 && (first == 0 || stamp < first)) first = stamp;
        }
        [facts date:name key:@"followed" stamp:first earliest:YES];
        return name != nil;
    };
    [facts each:OhrtFile(root, [follows stringByAppendingPathComponent:@"following.json"]) what:@"accounts you follow" handle:following];
    [facts each:OhrtFiles(root, follows, @"following_", YES) what:@"accounts you follow, continued" handle:following];

    [facts each:OhrtFiles(root, follows, @"followers_", NO) what:@"accounts that follow you" handle:^BOOL(NSDictionary *item) {
        for (id value in OhrtList(item[@"string_list_data"])) {
            NSDictionary *entry = OhrtDict(value);
            [facts date:OhrtWord(entry[@"value"]) ?: OhrtWord(item[@"title"]) key:@"follows_you" stamp:OhrtNumber(entry[@"timestamp"]) earliest:YES];
        }
        return YES;
    }];

    BOOL (^(^dated)(NSString *, BOOL))(NSDictionary *) = ^(NSString *key, BOOL earliest) {
        return ^BOOL(NSDictionary *item) {
            NSString *name = OhrtUsernameOf(item);
            [facts date:name key:key stamp:OhrtNumber(item[@"timestamp"]) earliest:earliest];
            return name != nil;
        };
    };
    [facts each:OhrtFile(root, [follows stringByAppendingPathComponent:@"close_friends.json"]) what:@"close friends" handle:dated(@"close_friend", YES)];
    [facts each:OhrtFile(root, [follows stringByAppendingPathComponent:@"recently_unfollowed_profiles.json"]) what:@"accounts you unfollowed" handle:dated(@"unfollowed", NO)];
    [facts each:OhrtFile(root, [follows stringByAppendingPathComponent:@"pending_follow_requests.json"]) what:@"follow requests you sent" handle:dated(@"requested", YES)];
    [facts each:OhrtFile(root, [follows stringByAppendingPathComponent:@"blocked_profiles.json"]) what:@"accounts you blocked" handle:dated(@"blocked", YES)];
    [facts each:OhrtFile(root, [follows stringByAppendingPathComponent:@"restricted_profiles.json"]) what:@"accounts you restricted" handle:dated(@"restricted", YES)];
    [facts each:OhrtFile(root, [follows stringByAppendingPathComponent:@"hide_story_from.json"]) what:@"accounts your story is hidden from" handle:dated(@"story_hidden", YES)];

    BOOL (^(^counted)(NSString *))(NSDictionary *) = ^(NSString *key) {
        return ^BOOL(NSDictionary *item) {
            NSString *owner = OhrtOwnerOf(item);
            [facts count:owner key:key stamp:OhrtNumber(item[@"timestamp"])];
            return owner != nil;
        };
    };
    BOOL (^comment)(NSDictionary *) = ^BOOL(NSDictionary *item) {
        NSDictionary *fields = OhrtDict(item[@"string_map_data"]);
        NSString *owner = OhrtWord(OhrtDict(fields[@"Media Owner"])[@"value"]);
        [facts count:owner key:@"comments" stamp:OhrtNumber(OhrtDict(fields[@"Time"])[@"timestamp"])];
        return owner != nil;
    };
    [facts each:OhrtFile(root, [activity stringByAppendingPathComponent:@"likes/liked_posts.json"]) what:@"posts you liked" handle:counted(@"likes")];
    [facts each:OhrtFiles(root, [activity stringByAppendingPathComponent:@"comments"], @"post_comments_", NO) what:@"comments on posts" handle:comment];
    [facts each:OhrtFile(root, [activity stringByAppendingPathComponent:@"comments/reels_comments.json"]) what:@"comments on reels" handle:comment];
    [facts each:OhrtFile(root, [activity stringByAppendingPathComponent:@"story_interactions/story_likes.json"]) what:@"stories you liked" handle:counted(@"story_likes")];
    [facts each:OhrtFile(root, [activity stringByAppendingPathComponent:@"story_interactions/stories_viewed.json"]) what:@"stories you saw" handle:counted(@"stories_seen")];
    [facts each:OhrtFile(root, [activity stringByAppendingPathComponent:@"saved/saved_posts.json"]) what:@"posts you saved" handle:counted(@"saved")];

    [facts each:OhrtFile(root, @"logged_information/recent_searches/profile_searches.json") what:@"profiles you searched for" handle:^BOOL(NSDictionary *item) {
        for (id value in OhrtList(item[@"string_list_data"])) {
            NSDictionary *entry = OhrtDict(value);
            [facts date:OhrtWord(item[@"title"]) ?: OhrtWord(entry[@"value"]) key:@"searched" stamp:OhrtNumber(entry[@"timestamp"]) earliest:NO];
        }
        return YES;
    }];
    [facts.people removeObjectForKey:@""];
}

// Message threads with one other person: how many messages, and when.
// Threads are named by the other person's display name, not their username,
// so that is what they are kept under. The count of threads behind a name
// says when two people share it.
static NSDictionary *OhrtReadThreads(NSURL *root) {
    NSURL *inbox = [root URLByAppendingPathComponent:@"your_instagram_activity/messages/inbox" isDirectory:YES];
    NSFileManager *files = [NSFileManager defaultManager];
    NSMutableArray<NSDictionary *> *threads = [NSMutableArray array];
    NSCountedSet<NSString *> *names = [NSCountedSet set];
    for (NSURL *folder in [files contentsOfDirectoryAtURL:inbox includingPropertiesForKeys:nil options:0 error:nil]) {
        @autoreleasepool {
            NSArray<NSString *> *people = nil;
            NSMutableArray<NSNumber *> *stamps = [NSMutableArray array];
            NSCountedSet<NSString *> *senders = [NSCountedSet set];
            for (NSURL *file in OhrtFiles(inbox, folder.lastPathComponent, @"message_", NO)) {
                NSDictionary *data = OhrtDict(OhrtReadJSON(file));
                if (!people) {
                    NSMutableArray<NSString *> *found = [NSMutableArray array];
                    for (id person in OhrtList(data[@"participants"])) [found addObject:OhrtMended(OhrtDict(person)[@"name"])];
                    if (found.count) people = found;
                }
                for (id value in OhrtList(data[@"messages"])) {
                    NSDictionary *message = OhrtDict(value);
                    double stamp = OhrtNumber(message[@"timestamp_ms"]);
                    if (stamp > 0) [stamps addObject:@((long long)(stamp / 1000))];
                    [senders addObject:OhrtMended(message[@"sender_name"])];
                }
            }
            if (people.count == 2 && stamps.count) {
                [threads addObject:@{@"people" : people, @"stamps" : stamps, @"senders" : senders}];
                for (NSString *name in people) [names addObject:name];
            }
        }
    }
    if (!threads.count) return @{};
    // The one name that is in every thread is the export's owner.
    NSString *me = nil;
    for (NSString *name in names) {
        if (!me || [names countForObject:name] > [names countForObject:me]) me = name;
    }
    NSMutableDictionary<NSString *, NSMutableDictionary *> *kept = [NSMutableDictionary dictionary];
    for (NSDictionary *thread in threads) {
        NSString *other = nil;
        for (NSString *name in thread[@"people"]) {
            if (![name isEqualToString:me]) {
                other = name;
                break;
            }
        }
        if (!other) continue;
        NSMutableDictionary *entry = kept[other];
        if (!entry) entry = kept[other] = [@{@"threads" : @0, @"messages" : @0, @"yours" : @0, @"first" : @0, @"last" : @0} mutableCopy];
        NSArray<NSNumber *> *stamps = thread[@"stamps"];
        long long first = [[stamps valueForKeyPath:@"@min.self"] longLongValue], last = [[stamps valueForKeyPath:@"@max.self"] longLongValue];
        long long heldFirst = [entry[@"first"] longLongValue];
        entry[@"threads"] = @([entry[@"threads"] longLongValue] + 1);
        entry[@"messages"] = @([entry[@"messages"] longLongValue] + (long long)stamps.count);
        entry[@"yours"] = @([entry[@"yours"] longLongValue] + (long long)[(NSCountedSet *)thread[@"senders"] countForObject:me]);
        entry[@"first"] = @(heldFirst == 0 || first < heldFirst ? first : heldFirst);
        if (last > [entry[@"last"] longLongValue]) entry[@"last"] = @(last);
    }
    return kept;
}

// Whose export this is, from the folder's own name:
// instagram-<username>-<date>-<id>.
static NSString *OhrtExportOwner(NSURL *root) {
    NSRegularExpression *shape = [NSRegularExpression regularExpressionWithPattern:@"^instagram-(.+)-\\d{4}-\\d{2}-\\d{2}-[A-Za-z0-9]+$" options:0 error:nil];
    NSString *name = root.lastPathComponent;
    NSTextCheckingResult *match = [shape firstMatchInString:name options:0 range:NSMakeRange(0, name.length)];
    return match ? [name substringWithRange:[match rangeAtIndex:1]].lowercaseString : nil;
}

// The export's own folder: the one picked, or the single folder inside it
// when unpacking put it one level down.
static NSURL *OhrtExportRoot(NSURL *picked) {
    NSFileManager *files = [NSFileManager defaultManager];
    if ([files fileExistsAtPath:[picked URLByAppendingPathComponent:@"connections"].path]) return picked;
    for (NSURL *inside in [files contentsOfDirectoryAtURL:picked includingPropertiesForKeys:nil options:NSDirectoryEnumerationSkipsHiddenFiles error:nil]) {
        if ([files fileExistsAtPath:[inside URLByAppendingPathComponent:@"connections"].path]) return inside;
    }
    return nil;
}

NSDictionary *OhrtReadExportFolder(NSURL *picked) {
    NSURL *root = OhrtExportRoot(picked);
    if (!root) return nil;
    OhrtExportFacts *facts = [OhrtExportFacts new];
    OhrtReadPeople(root, facts);
    NSDictionary *threads = OhrtReadThreads(root);

    // When it was made: the newest of the files that list who follows whom.
    NSTimeInterval made = 0;
    NSURL *follows = [root URLByAppendingPathComponent:@"connections/followers_and_following" isDirectory:YES];
    for (NSURL *file in [[NSFileManager defaultManager] contentsOfDirectoryAtURL:follows includingPropertiesForKeys:@[ NSURLContentModificationDateKey ] options:0 error:nil]) {
        NSDate *changed = nil;
        if ([file getResourceValue:&changed forKey:NSURLContentModificationDateKey error:nil] && changed.timeIntervalSince1970 > made) made = changed.timeIntervalSince1970;
    }
    if (!(made > 0)) made = [NSDate date].timeIntervalSince1970;

    OhrtLog(@"export: read on the phone: %@", [facts.read componentsJoinedByString:@", "]);
    NSMutableDictionary *result = [@{@"ohrtstagram_facts" : @1, @"exported" : @((long long)made), @"people" : facts.people, @"threads" : threads} mutableCopy];
    NSString *owner = OhrtExportOwner(root);
    if (owner) result[@"account"] = owner;
    return result;
}
