// The decisions our features make, as plain C with nothing of UIKit or
// Instagram in it, so ohrt/tests/logic_test.c can run them on the build
// machine. The files that use them only fetch the inputs and act on the
// answer.
#ifndef OHRT_LOGIC_H
#define OHRT_LOGIC_H

#include <math.h>
#include <stddef.h>
#include <stdio.h>

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
static inline int OhrtOverBudget(double spentSeconds, long budgetMinutes, long extraMinutes) {
    if (budgetMinutes <= 0) return 0;
    if (extraMinutes < 0) extraMinutes = 0;
    return spentSeconds >= (double)(budgetMinutes + extraMinutes) * 60.0;
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
// in a row that brought nothing new and is updated here.
static inline OhrtScanStep OhrtAfterPage(int moreAvailable, size_t usersBefore, size_t usersAfter, unsigned *emptyPages,
                                         unsigned pages, unsigned maxPages) {
    if (!moreAvailable) return OhrtScanWhole;
    *emptyPages = usersAfter == usersBefore ? *emptyPages + 1 : 0;
    if (*emptyPages >= 2 || pages >= maxPages) return OhrtScanGiveUp;
    return OhrtScanGoOn;
}

// Hours to wait after Instagram has refused a check `failures` times running.
static inline double OhrtRefusalWaitHours(long failures) {
    if (failures <= 1) return 12;
    if (failures == 2) return 24;
    if (failures == 3) return 48;
    return 72;
}

// When the next check may start, or 0 if it may start now.
static inline double OhrtNextCheckAt(double now, double checkedAt, double cooldownUntil, double betweenChecks) {
    double spaced = checkedAt > 0 ? checkedAt + betweenChecks : 0;
    double at = spaced > cooldownUntil ? spaced : cooldownUntil;
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
// started in the background and dropped there is neither.
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

static inline void OhrtGuardFinishedLaunching(OhrtGuard *guard, int inBackground) {
    if (!inBackground || guard->wasActive || guard->settled) return;
    guard->stored = guard->before;
    guard->counted = 0;
}

// Returns 1 the first time the app comes to the front in this process,
// which is when the wait for it to settle begins.
static inline int OhrtGuardBecameActive(OhrtGuard *guard) {
    if (guard->wasActive) return 0;
    guard->wasActive = 1;
    if (!guard->counted && !guard->settled) {
        guard->stored = guard->before + 1;
        guard->counted = 1;
    }
    return 1;
}

// Leaving the app the ordinary way is not a crash, however soon.
static inline void OhrtGuardLeft(OhrtGuard *guard) {
    if (guard->wasActive) OhrtGuardSettle(guard);
}

#endif
