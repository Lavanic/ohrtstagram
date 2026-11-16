// The decisions our features make, as plain C with nothing of UIKit or
// Instagram in it, so ohrt/tests/logic_test.c can run them on the build
// machine. The files that use them only fetch the inputs and act on the
// answer.
#ifndef OHRT_LOGIC_H
#define OHRT_LOGIC_H

#include <math.h>
#include <stddef.h>
#include <stdio.h>
#include <string.h>

// Time budget

// "47m" or "1h 05m".
static inline void OhrtDurationText(double seconds, char *text, size_t size) {
    long minutes = seconds > 0 ? lround(seconds / 60.0) : 0;
    if (minutes < 60) snprintf(text, size, "%ldm", minutes);
    else snprintf(text, size, "%ldh %02ldm", minutes / 60, minutes % 60);
}

// How much of the time since the last tick counts as time in the app. A gap
// longer than two ticks means the app was suspended in between.
static inline double OhrtCountedTime(double elapsed, double tick) {
    if (!(elapsed > 0)) return 0;
    return elapsed > tick * 2 ? tick * 2 : elapsed;
}

// Whether the lock screen should be up. A budget of zero is no budget.
// `allowedUntil` is what "five more minutes" leaves behind: the point in
// today's count, in seconds, up to which the lock stays down. It is a point
// in the count and not an amount on top of the budget, so changing the
// budget afterwards does not stretch it.
static inline int OhrtOverBudget(double spentSeconds, long budgetMinutes, double allowedUntil) {
    if (budgetMinutes <= 0) return 0;
    if (spentSeconds < (double)budgetMinutes * 60.0) return 0;
    return !(spentSeconds < allowedUntil);
}

// What "five more minutes" sets that point to: `step` minutes past the time
// already spent, however far past the budget that is.
static inline double OhrtAllowedAfterMore(double spentSeconds, long step) {
    return (spentSeconds > 0 ? spentSeconds : 0) + (double)step * 60.0;
}

// Facts on a profile

// "now", "45m ago", "3h ago", "2d ago".
static inline void OhrtAgoText(double seconds, char *text, size_t size) {
    if (!(seconds >= 60)) snprintf(text, size, "now");
    else if (seconds < 3600) snprintf(text, size, "%ldm ago", (long)(seconds / 60));
    else if (seconds < 86400) snprintf(text, size, "%ldh ago", (long)(seconds / 3600));
    else snprintf(text, size, "%ldd ago", (long)(seconds / 86400));
}

// How many of the times noted for something fall after `after`, which is
// when the export that already counts the earlier ones was made (0 when
// there is no export). `latest` is set to the last of those, or 0.
static inline size_t OhrtCountAfter(const double *times, size_t count, double after, double *latest) {
    size_t counted = 0;
    *latest = 0;
    for (size_t index = 0; index < count; index++) {
        if (!(times[index] > after)) continue;
        counted++;
        if (times[index] > *latest) *latest = times[index];
    }
    return counted;
}

// The app's name in its text
//
// Whether "Instagram", found in a piece of text, stands there as the app's
// name, given the character before it and the two after it (a space where
// there is none). It does not when it is part of a longer word, of an
// address ("Instagram.com") or of a handle or path ("@Instagram").
static inline int OhrtIsLetterOrDigit(unsigned c) {
    return (c >= 'a' && c <= 'z') || (c >= 'A' && c <= 'Z') || (c >= '0' && c <= '9') || c == '_';
}

static inline int OhrtNameStandsAlone(unsigned before, unsigned after, unsigned next) {
    if (OhrtIsLetterOrDigit(before) || before == '@' || before == '/' || before == '.') return 0;
    if (OhrtIsLetterOrDigit(after)) return 0;
    if (after == '.' && OhrtIsLetterOrDigit(next)) return 0;
    return 1;
}

// Whether the words after "Instagram" make it the name of something of
// Instagram's own, which is not ours to rename: "Instagram for iPad" is
// another app, and calling it ours would mislead.
static inline int OhrtNameIsTheirProduct(const char *after) {
    return strncmp(after, " for ", 5) == 0;
}

// Caught up wall

typedef enum {
    OhrtFeedOther,    // the stories tray and anything else that is not a post
    OhrtFeedPost,     // a post, with the time it was taken
    OhrtFeedTrailer,  // a spinner, a group header, Instagram's own end marker
} OhrtFeedKind;

typedef struct {
    OhrtFeedKind kind;
    double taken;
} OhrtFeedItem;

// How many items of the feed to keep: everything before the first post taken
// at or before `mark`, less any trailers left dangling at the end. Equal to
// `count` when no post is that old. `newest` is set to the time of the
// newest post kept, or 0 when none is.
static inline size_t OhrtWallKeep(const OhrtFeedItem *items, size_t count, double mark, double *newest) {
    size_t end = count;
    *newest = 0;
    for (size_t index = 0; index < count; index++) {
        if (items[index].kind != OhrtFeedPost) continue;
        if (items[index].taken <= mark) {
            end = index;
            break;
        }
        if (items[index].taken > *newest) *newest = items[index].taken;
    }
    if (end == count) return count;
    while (end > 0 && items[end - 1].kind == OhrtFeedTrailer) end--;
    return end;
}

// Whether the posts are newest first, give or take: a post that is newer
// than the one before it is out of order, and one in ten of those is put up
// with (a pinned post, two posted in the same second). The wall only makes
// sense for a feed in time order, and a ranked feed fails this at once.
static inline int OhrtFeedInTimeOrder(const OhrtFeedItem *items, size_t count) {
    size_t posts = 0, outOfOrder = 0;
    double previous = 0;
    for (size_t index = 0; index < count; index++) {
        if (items[index].kind != OhrtFeedPost) continue;
        if (posts > 0 && items[index].taken > previous) outOfOrder++;
        previous = items[index].taken;
        posts++;
    }
    return outOfOrder * 10 <= posts;
}

// The mark a visit starts with: where the wall was last reached, or, with no
// history, a fixed stretch back from now.
static inline double OhrtWallMark(double saved, double now, double firstWindow) {
    return saved > 0 ? saved : now - firstWindow;
}

// Follow back

typedef enum {
    OhrtScanGoOn,      // ask for the next page
    OhrtScanWhole,     // the list is complete
    OhrtScanGiveUp,    // the list cannot be trusted to be complete
} OhrtScanStep;

// What to do after a page of a list has arrived. `emptyPages` counts pages
// in a row that brought nothing new and is updated here. One or two of
// those are forgiven: the fetcher can report the same page more than once.
static inline OhrtScanStep OhrtAfterPage(int moreAvailable, size_t usersBefore, size_t usersAfter, unsigned *emptyPages,
                                         unsigned pages, unsigned maxPages) {
    if (!moreAvailable) return OhrtScanWhole;
    *emptyPages = usersAfter == usersBefore ? *emptyPages + 1 : 0;
    if (*emptyPages >= 3 || pages >= maxPages) return OhrtScanGiveUp;
    return OhrtScanGoOn;
}

typedef enum {
    OhrtFailRetry,        // ask for the same page again
    OhrtFailInterrupted,  // give up, and blame nobody
    OhrtFailRefused,      // Instagram would not answer
} OhrtFailure;

// What a page that failed, or never came, means. `interrupted` says the app
// left the screen or the connection dropped while it was awaited; that is
// worth a few more tries and is not held against the account.
static inline OhrtFailure OhrtAfterFailure(int interrupted, unsigned retries, unsigned maxRetries) {
    if (!interrupted) return OhrtFailRefused;
    return retries < maxRetries ? OhrtFailRetry : OhrtFailInterrupted;
}

// Whether a list that was read is short of what Instagram says it holds by
// more than deleted and deactivated accounts would explain.
static inline int OhrtListLooksShort(long read, long expected) {
    return expected > 0 && read < expected - expected / 10 - 5;
}

// Hours to wait after Instagram has refused a check `failures` times running.
static inline double OhrtRefusalWaitHours(long failures) {
    if (failures <= 1) return 12;
    if (failures == 2) return 24;
    if (failures == 3) return 48;
    return 72;
}

// When the next check may start, or 0 if it may start now. A check that
// finished is spaced from the next by `betweenChecks`. One that was started
// and never finished (interrupted, or the app was closed) has still read
// part of the lists, so it is spaced too, by the shorter `betweenStarts`.
static inline double OhrtNextCheckAt(double now, double checkedAt, double startedAt, double cooldownUntil,
                                     double betweenChecks, double betweenStarts) {
    double at = cooldownUntil;
    if (checkedAt > 0 && checkedAt + betweenChecks > at) at = checkedAt + betweenChecks;
    if (startedAt > 0 && startedAt + betweenStarts > at) at = startedAt + betweenStarts;
    return at > now ? at : 0;
}

// Launch guard
//
// Counts starts that did not settle, so that after two in a row the next one
// can run with every switch off. `stored` is the number kept between runs;
// whoever drives this writes it out whenever it changes.
//
// A start that did not settle is a process that died before it finished
// launching, or within a while of first coming to the front. A process
// started in the background and dropped there is neither, and nor is one
// iOS started ahead of time ("prewarmed") and then threw away.
typedef struct {
    long stored;
    long before;    // what was stored when this process started
    int safe;       // this run has every switch off
    int counted;    // this run is in `stored` as one that has not settled
    int settled;
    int wasActive;
} OhrtGuard;

static inline void OhrtGuardStart(OhrtGuard *guard, long stored) {
    if (stored < 0) stored = 0;
    guard->before = stored;
    guard->safe = stored >= 2;
    guard->stored = stored + 1;
    guard->counted = 1;
    guard->settled = 0;
    guard->wasActive = 0;
}

static inline void OhrtGuardSettle(OhrtGuard *guard) {
    if (guard->settled) return;
    guard->settled = 1;
    guard->stored = 0;
}

// The process turns out not to be a start the user asked for: it was
// prewarmed, or it finished launching in the background. It stops counting
// against the app unless it comes to the front after all.
static inline void OhrtGuardNotAskedFor(OhrtGuard *guard) {
    if (guard->wasActive || guard->settled) return;
    guard->stored = guard->before;
    guard->counted = 0;
}

static inline void OhrtGuardFinishedLaunching(OhrtGuard *guard, int inBackground) {
    if (inBackground) OhrtGuardNotAskedFor(guard);
}

// The app is being launched at the front: a prewarmed process that was not
// counting starts to.
static inline void OhrtGuardLaunchingAtFront(OhrtGuard *guard) {
    if (guard->counted || guard->settled) return;
    guard->stored = guard->before + 1;
    guard->counted = 1;
}

// Returns 1 the first time the app comes to the front in this process,
// which is when the wait for it to settle begins.
static inline int OhrtGuardBecameActive(OhrtGuard *guard) {
    if (guard->wasActive) return 0;
    guard->wasActive = 1;
    OhrtGuardLaunchingAtFront(guard);
    return 1;
}

// The app went to the background or was closed the ordinary way, which is
// not a crash, however soon. A process that was not counting (prewarmed, or
// started in the background) has nothing to settle and must not wipe what
// earlier starts left.
static inline void OhrtGuardLeft(OhrtGuard *guard) {
    if (guard->counted) OhrtGuardSettle(guard);
}

#endif
