// Keeps the count of messages between you and each person going.
//
// The export says how many there were up to the day it was made
// (OhrtExport.m). A like or a follow is something you do in this app, and
// is noted as you do it (OhrtActivity.x). A message is not only that: it
// also arrives, is sent from another phone, or comes in while the app is
// shut. So messages are not noted as they are sent. They are read off the
// conversations themselves. Instagram keeps a conversation as a value that
// it makes anew whenever anything in it changes, whether the change came
// over the live connection, from a fetch or off the disk, and each one made
// is looked through here for messages not read before.
//
// Only a conversation with one other person counts, as in the export, and
// only a message the server has taken: one that is still being sent has no
// id yet, and is counted when it gets one. What is kept of a message is its
// time, and its id boiled down to a number so that it is not counted twice
// (OhrtLogic.h), under the other person's account id. Nothing a message
// says is read.
#import <objc/runtime.h>

#import "Ohrt.h"
#import "OhrtLogic.h"

@interface IGDirectPublishedThread : NSObject
@end

static NSString *OhrtMessagesText(id value) {
    if ([value isKindOfClass:[NSString class]]) return value;
    if ([value isKindOfClass:[NSNumber class]]) return [value stringValue];
    return nil;
}

static id OhrtMessagesIvar(id object, const char *name) {
    Ivar ivar = object ? class_getInstanceVariable([object class], name) : NULL;
    return ivar ? object_getIvar(object, ivar) : nil;
}

// Conversations are made on Instagram's own threads, many at a time when
// the inbox loads. They are looked through one after another, off those
// threads and off the main one.
static dispatch_queue_t OhrtMessagesQueue(void) {
    static dispatch_queue_t queue;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        queue = dispatch_queue_create("ohrt.messages", dispatch_queue_attr_make_with_qos_class(DISPATCH_QUEUE_SERIAL, QOS_CLASS_UTILITY, 0));
    });
    return queue;
}

// Everything from here to the hooks runs on that queue only.

// The messages read since the app started, by id, with their times: most
// of what a conversation holds was in the one made before it.
static NSMutableDictionary<NSString *, NSNumber *> *gOhrtMessagesRead;

static void OhrtMessagesSay(NSString *what) {
    static NSMutableSet<NSString *> *said;
    if (!said) said = [NSMutableSet set];
    if ([said containsObject:what]) return;
    [said addObject:what];
    OhrtLog(@"messages: %@", what);
}

static void OhrtMessagesLook(id thread) {
    id about = OhrtCall(thread, @"metadata");
    if (!about) return;
    OhrtMessagesSay(@"conversations are being read");
    if (OhrtCallBool(about, @"isGroup")) return;
    id people = OhrtCall(about, @"users");
    if (![people isKindOfClass:[NSArray class]]) {
        OhrtMessagesSay(@"a conversation does not list its people as expected");
        return;
    }
    if ([people count] != 1) return;
    NSString *pk = OhrtMessagesText(OhrtCall([people firstObject], @"pk"));
    OhrtProbeThread(about);
    id messages = OhrtCall(thread, @"publishedMessageSet");
    if (!pk.length || ![messages respondsToSelector:@selector(countByEnumeratingWithState:objects:count:)]) return;

    if (!gOhrtMessagesRead) gOhrtMessagesRead = [NSMutableDictionary dictionary];
    if (gOhrtMessagesRead.count > 60000) [gOhrtMessagesRead removeAllObjects];
    NSMutableArray<NSNumber *> *stamps = [NSMutableArray array], *ids = [NSMutableArray array];
    NSUInteger held = 0, unsent = 0, timeless = 0;
    for (id message in (id<NSFastEnumeration>)messages) {
        held++;
        id its = OhrtCall(message, @"metadata");
        NSString *serverId = OhrtMessagesText(OhrtCall(its, @"serverId"));
        NSDate *when = OhrtCall(its, @"serverTimestamp");
        if (!serverId.length) {
            unsent++;
            continue;
        }
        if (![when isKindOfClass:[NSDate class]]) {
            timeless++;
            continue;
        }
        NSNumber *stamp = @(llround(when.timeIntervalSince1970 * 1000.0));
        NSNumber *before = gOhrtMessagesRead[serverId];
        if (before) {
            long long apart = llabs(before.longLongValue - stamp.longLongValue);
            if (apart > 1) OhrtMessagesSay([NSString stringWithFormat:@"one was read again with its time %lld ms off", apart]);
            continue;
        }
        gOhrtMessagesRead[serverId] = stamp;
        // "You missed a call" and the like stand in a conversation as
        // notices, which the export does not count.
        if (OhrtMessagesIvar(OhrtCall(message, @"content"), "_threadActivity")) continue;
        [stamps addObject:stamp];
        [ids addObject:@(OhrtIdNumber(serverId.UTF8String))];
    }

    // What the first few hold, to tell from the log whether messages come
    // with what is needed to count them. Numbers only.
    static NSUInteger told;
    if (told < 16 && (stamps.count || unsent || timeless)) {
        told++;
        OhrtLog(@"messages: a conversation of %lu, %lu not read before, %lu with no id, %lu with no time", (unsigned long)held, (unsigned long)stamps.count, (unsigned long)unsent, (unsigned long)timeless);
    }
    if (!stamps.count) return;
    NSString *viewer = OhrtMessagesText(OhrtCall(thread, @"viewerId"));
    dispatch_async(dispatch_get_main_queue(), ^{
        OhrtTry(@"messages", ^{
            OhrtActivityNoteMessages(pk, viewer, stamps, ids);
        });
    });
}

static void OhrtMessagesMade(id thread) {
    if (!thread) return;
    dispatch_async(OhrtMessagesQueue(), ^{
        OhrtTry(@"messages", ^{
            OhrtMessagesLook(thread);
        });
    });
}

%group OhrtMessages

%hook IGDirectPublishedThread
- (id)initWithThreadId:(id)threadId viewerId:(id)viewerId threadIdV2ForInboxPaging:(id)paging metadata:(id)metadata threadMessagesRange:(id)range messageIslandRange:(id)island visualMessageInfo:(id)visual publishedMessageSet:(id)messages publishedMessagesInCurrentThreadRange:(id)inRange publishedMessagesInCurrentThreadRangeSet:(id)inRangeSet isOldMessageRequest:(BOOL)old primarySortingDate:(id)sorting primarySortingDateIncludingShhMode:(id)sortingShh pinningDateIfPinned:(id)pinned {
    id thread = %orig;
    OhrtMessagesMade(thread);
    return thread;
}

// A conversation read back off the disk is filled in here instead.
- (id)initWithCoder:(id)coder {
    id thread = %orig;
    OhrtMessagesMade(thread);
    return thread;
}
%end

%end

void OhrtInstallMessages(void) {
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        if (!OhrtFeatureReady(kOhrtFactsKey, @"messages")) return;
        %init(OhrtMessages);
    });
}
