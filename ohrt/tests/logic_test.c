// Checks the decisions in ohrt/src/OhrtLogic.h.
//   cc -o /tmp/logic_test ohrt/tests/logic_test.c -lm && /tmp/logic_test
#include <string.h>

#include "../src/OhrtLogic.h"

static int failures;

#define CHECK(what, condition) \
    do { \
        if (!(condition)) { \
            failures++; \
            printf("FAIL %s (%s:%d)\n", what, __FILE__, __LINE__); \
        } \
    } while (0)

static int duration_is(double seconds, const char *expected) {
    char text[32];
    OhrtDurationText(seconds, text, sizeof(text));
    return strcmp(text, expected) == 0;
}

static void time_budget(void) {
    CHECK("no time is 0m", duration_is(0, "0m"));
    CHECK("negative time is 0m", duration_is(-30, "0m"));
    CHECK("47 minutes", duration_is(47 * 60, "47m"));
    CHECK("just under an hour rounds to it", duration_is(59 * 60 + 40, "1h 00m"));
    CHECK("an hour and five", duration_is(65 * 60, "1h 05m"));

    CHECK("a normal tick counts whole", OhrtCountedTime(5, 5) == 5);
    CHECK("a late tick still counts", OhrtCountedTime(9, 5) == 9);
    CHECK("a suspended stretch is capped", OhrtCountedTime(3600, 5) == 10);
    CHECK("a clock that went backwards counts nothing", OhrtCountedTime(-4, 5) == 0);
    CHECK("not a number counts nothing", OhrtCountedTime(NAN, 5) == 0);

    char ago[24];
    OhrtAgoText(20, ago, sizeof(ago));
    CHECK("a moment ago is now", strcmp(ago, "now") == 0);
    OhrtAgoText(45 * 60 + 30, ago, sizeof(ago));
    CHECK("minutes", strcmp(ago, "45m ago") == 0);
    OhrtAgoText(3 * 3600 + 59 * 60, ago, sizeof(ago));
    CHECK("hours are not rounded up", strcmp(ago, "3h ago") == 0);
    OhrtAgoText(2 * 86400 + 5, ago, sizeof(ago));
    CHECK("days", strcmp(ago, "2d ago") == 0);
    OhrtAgoText(NAN, ago, sizeof(ago));
    CHECK("not a number is now", strcmp(ago, "now") == 0);

    CHECK("the name on its own", OhrtNameStandsAlone(' ', ' ', 'i'));
    CHECK("the name at the start and the end of a text", OhrtNameStandsAlone(' ', ' ', ' '));
    CHECK("the name before a full stop", OhrtNameStandsAlone(' ', '.', ' '));
    CHECK("the name with a possessive", OhrtNameStandsAlone(' ', '\'', 's'));
    CHECK("the name in quotes", OhrtNameStandsAlone('"', '"', ' '));
    CHECK("an address is not the name", !OhrtNameStandsAlone(' ', '.', 'c'));
    CHECK("a handle is not the name", !OhrtNameStandsAlone('@', ' ', ' '));
    CHECK("a path is not the name", !OhrtNameStandsAlone('/', '/', 'p'));
    CHECK("the end of an address is not the name", !OhrtNameStandsAlone('.', ' ', ' '));
    CHECK("a longer word is not the name", !OhrtNameStandsAlone(' ', 'm', 'e'));
    CHECK("the end of a longer word is not the name", !OhrtNameStandsAlone('y', ' ', ' '));
    CHECK("another of their apps keeps their name", OhrtNameIsTheirProduct(" for iPad"));
    CHECK("and so does one cut short", OhrtNameIsTheirProduct(" for iPa"));
    CHECK("ordinary words after the name do not", !OhrtNameIsTheirProduct(" is great") && !OhrtNameIsTheirProduct("") && !OhrtNameIsTheirProduct(" form"));

    CHECK("no budget never locks", !OhrtOverBudget(999999, 0, 0));
    CHECK("under budget", !OhrtOverBudget(29 * 60, 30, 0));
    CHECK("at budget", OhrtOverBudget(30 * 60, 30, 0));
    CHECK("an allowance that is behind lifts nothing", OhrtOverBudget(40 * 60, 30, 36 * 60));
    CHECK("a negative allowance is ignored", OhrtOverBudget(30 * 60, 30, -600));
    CHECK("an allowance that is not a number is ignored", OhrtOverBudget(30 * 60, 30, NAN));

    // "Five more minutes" has to lift the lock from wherever the count is.
    double allowed = OhrtAllowedAfterMore(30 * 60, 5);
    CHECK("at the budget, five more lifts it", allowed == 35 * 60 && !OhrtOverBudget(30 * 60, 30, allowed));
    CHECK("and it comes back", !OhrtOverBudget(35 * 60 - 1, 30, allowed) && OhrtOverBudget(35 * 60, 30, allowed));
    allowed = OhrtAllowedAfterMore(120 * 60, 5);
    CHECK("two hours in on a half hour budget, one tap lifts it", !OhrtOverBudget(120 * 60, 30, allowed));
    CHECK("and it holds for five minutes, no longer", !OhrtOverBudget(124 * 60, 30, allowed) && OhrtOverBudget(125 * 60, 30, allowed));
    CHECK("a budget raised afterwards does not stretch it", !OhrtOverBudget(124 * 60, 60, allowed) && OhrtOverBudget(125 * 60, 60, allowed));
    CHECK("a budget lowered afterwards does not cut it short", !OhrtOverBudget(124 * 60, 10, allowed));
    CHECK("a budget raised past the count lifts the lock by itself", !OhrtOverBudget(126 * 60, 180, allowed));
    allowed = OhrtAllowedAfterMore(31 * 60 + 20, 5);
    CHECK("part minutes are kept", allowed == 36 * 60 + 20);
    CHECK("a count below zero is taken as zero", OhrtAllowedAfterMore(-50, 5) == 5 * 60);
}

static void wall(void) {
    double newest;
    OhrtFeedItem feed[] = {
        {OhrtFeedOther, 0},   // stories tray
        {OhrtFeedPost, 500},
        {OhrtFeedPost, 400},
        {OhrtFeedTrailer, 0}, // a header for what follows
        {OhrtFeedPost, 300},
        {OhrtFeedPost, 200},
        {OhrtFeedTrailer, 0}, // spinner
    };
    size_t count = sizeof(feed) / sizeof(feed[0]);

    CHECK("nothing old keeps everything", OhrtWallKeep(feed, count, 100, &newest) == count && newest == 500);
    CHECK("cut before the first old post, with its header", OhrtWallKeep(feed, count, 300, &newest) == 3 && newest == 500);
    CHECK("a post taken exactly at the mark is old", OhrtWallKeep(feed, count, 400, &newest) == 2 && newest == 500);
    CHECK("everything old leaves the tray", OhrtWallKeep(feed, count, 500, &newest) == 1 && newest == 0);
    CHECK("an empty feed", OhrtWallKeep(feed, 0, 300, &newest) == 0 && newest == 0);

    OhrtFeedItem only_old[] = {{OhrtFeedTrailer, 0}, {OhrtFeedPost, 10}};
    CHECK("trailers before the only post go too", OhrtWallKeep(only_old, 2, 50, &newest) == 0 && newest == 0);

    // Not in time order: the cut is still at the first old post, and what
    // is newer but further down goes with it.
    OhrtFeedItem unordered[] = {{OhrtFeedPost, 500}, {OhrtFeedPost, 100}, {OhrtFeedPost, 450}};
    CHECK("out of order cuts at the first old post", OhrtWallKeep(unordered, 3, 300, &newest) == 1 && newest == 500);

    CHECK("the following feed is in time order", OhrtFeedInTimeOrder(feed, count));
    CHECK("an empty feed is in time order", OhrtFeedInTimeOrder(feed, 0));
    OhrtFeedItem ranked[] = {{OhrtFeedPost, 300}, {OhrtFeedPost, 900}, {OhrtFeedPost, 100}, {OhrtFeedPost, 700}, {OhrtFeedPost, 500},
                             {OhrtFeedPost, 800}, {OhrtFeedPost, 200}, {OhrtFeedPost, 600}};
    CHECK("a ranked feed is not", !OhrtFeedInTimeOrder(ranked, 8));
    OhrtFeedItem pinned[12];
    for (int index = 0; index < 12; index++) pinned[index] = (OhrtFeedItem){OhrtFeedPost, 1000 - index * 10};
    pinned[0].taken = 5;  // an old post pinned to the top
    CHECK("one pinned post in a dozen is put up with", OhrtFeedInTimeOrder(pinned, 12));
    pinned[4].taken = 2000;
    pinned[8].taken = 3000;
    CHECK("three out of order in a dozen are not", !OhrtFeedInTimeOrder(pinned, 12));
    OhrtFeedItem same[] = {{OhrtFeedPost, 500}, {OhrtFeedPost, 500}, {OhrtFeedPost, 400}};
    CHECK("two posts of the same second are in order", OhrtFeedInTimeOrder(same, 3));

    CHECK("a saved mark is used", OhrtWallMark(1234, 99999, 1000) == 1234);
    CHECK("no saved mark looks back from now", OhrtWallMark(0, 99999, 1000) == 98999);
}

static void follow_back(void) {
    unsigned empty = 0;
    CHECK("no more pages: whole", OhrtAfterPage(0, 0, 0, &empty, 1, 600) == OhrtScanWhole);
    CHECK("an empty list is whole", OhrtAfterPage(0, 0, 0, &empty, 1, 600) == OhrtScanWhole && empty == 0);
    CHECK("new users and more to come: go on", OhrtAfterPage(1, 0, 50, &empty, 1, 600) == OhrtScanGoOn && empty == 0);
    CHECK("one page with nothing new is forgiven", OhrtAfterPage(1, 50, 50, &empty, 2, 600) == OhrtScanGoOn && empty == 1);
    CHECK("and a second", OhrtAfterPage(1, 50, 50, &empty, 3, 600) == OhrtScanGoOn && empty == 2);
    CHECK("a third is not", OhrtAfterPage(1, 50, 50, &empty, 4, 600) == OhrtScanGiveUp);
    empty = 1;
    CHECK("new users forgive the earlier empty page", OhrtAfterPage(1, 50, 80, &empty, 3, 600) == OhrtScanGoOn && empty == 0);
    CHECK("too many pages", OhrtAfterPage(1, 50, 80, &empty, 600, 600) == OhrtScanGiveUp);
    empty = 1;
    CHECK("the last page may be empty", OhrtAfterPage(0, 50, 50, &empty, 4, 600) == OhrtScanWhole);

    CHECK("a failure out of the blue is a refusal", OhrtAfterFailure(0, 0, 3) == OhrtFailRefused);
    CHECK("a failure while away is retried", OhrtAfterFailure(1, 0, 3) == OhrtFailRetry);
    CHECK("and again", OhrtAfterFailure(1, 2, 3) == OhrtFailRetry);
    CHECK("but not for ever", OhrtAfterFailure(1, 3, 3) == OhrtFailInterrupted);

    CHECK("a full list is not short", !OhrtListLooksShort(2497, 2497));
    CHECK("a few missing are deactivated accounts", !OhrtListLooksShort(2480, 2497));
    CHECK("a tenth missing is still let through", !OhrtListLooksShort(2250, 2497));
    CHECK("half missing is short", OhrtListLooksShort(1200, 2497));
    CHECK("an unknown count says nothing", !OhrtListLooksShort(10, 0));
    CHECK("a small list missing a couple is not short", !OhrtListLooksShort(8, 12));
    CHECK("a small list mostly missing is short", OhrtListLooksShort(2, 30));

    CHECK("first refusal", OhrtRefusalWaitHours(1) == 12);
    CHECK("second refusal", OhrtRefusalWaitHours(2) == 24);
    CHECK("third refusal", OhrtRefusalWaitHours(3) == 48);
    CHECK("later refusals", OhrtRefusalWaitHours(4) == 72 && OhrtRefusalWaitHours(40) == 72);

    double three_hours = 3 * 3600, one_hour = 3600;
    CHECK("never checked: now", OhrtNextCheckAt(1000000, 0, 0, 0, three_hours, one_hour) == 0);
    CHECK("just checked: in three hours", OhrtNextCheckAt(1000000, 999000, 0, 0, three_hours, one_hour) == 999000 + three_hours);
    CHECK("checked long ago: now", OhrtNextCheckAt(1000000, 900000, 0, 0, three_hours, one_hour) == 0);
    CHECK("a cooldown outlasts the spacing", OhrtNextCheckAt(1000000, 999000, 0, 1050000, three_hours, one_hour) == 1050000);
    CHECK("a cooldown that has passed", OhrtNextCheckAt(1000000, 0, 0, 999999, three_hours, one_hour) == 0);
    CHECK("started and never finished: in an hour", OhrtNextCheckAt(1000000, 0, 999500, 0, three_hours, one_hour) == 999500 + one_hour);
    CHECK("an unfinished start long ago: now", OhrtNextCheckAt(1000000, 0, 990000, 0, three_hours, one_hour) == 0);
    CHECK("finished after it started: the longer wait", OhrtNextCheckAt(1000000, 999800, 999500, 0, three_hours, one_hour) == 999800 + three_hours);
}

// One process: what it does before it dies, and what it leaves stored.
typedef enum {
    DIES_LAUNCHING, DROPPED_IN_BACKGROUND, DIES_AT_THE_FRONT, FRONT_AFTER_BACKGROUND_DIES, SETTLES, FRONT_AFTER_BACKGROUND_SETTLES,
    LEFT_QUICKLY, PREWARMED_AND_DROPPED, PREWARMED_DIES_LAUNCHING, PREWARMED_SETTLES, LEFT_BEFORE_ACTIVE, BACKGROUND_THEN_LEFT,
} Life;

static long run(long stored, Life life, int *safe) {
    OhrtGuard guard;
    OhrtGuardStart(&guard, stored);
    if (safe) *safe = guard.safe;
    switch (life) {
        case DIES_LAUNCHING:
            break;
        case DROPPED_IN_BACKGROUND:
            OhrtGuardFinishedLaunching(&guard, 1);
            break;
        case DIES_AT_THE_FRONT:
            OhrtGuardFinishedLaunching(&guard, 0);
            OhrtGuardBecameActive(&guard);
            break;
        case FRONT_AFTER_BACKGROUND_DIES:
            OhrtGuardFinishedLaunching(&guard, 1);
            OhrtGuardBecameActive(&guard);
            break;
        case SETTLES:
            OhrtGuardFinishedLaunching(&guard, 0);
            OhrtGuardBecameActive(&guard);
            OhrtGuardSettle(&guard);
            break;
        case FRONT_AFTER_BACKGROUND_SETTLES:
            OhrtGuardFinishedLaunching(&guard, 1);
            OhrtGuardBecameActive(&guard);
            OhrtGuardSettle(&guard);
            break;
        case LEFT_QUICKLY:
            OhrtGuardFinishedLaunching(&guard, 0);
            OhrtGuardBecameActive(&guard);
            OhrtGuardLeft(&guard);
            break;
        case PREWARMED_AND_DROPPED:
            OhrtGuardNotAskedFor(&guard);
            break;
        case PREWARMED_DIES_LAUNCHING:
            OhrtGuardNotAskedFor(&guard);
            OhrtGuardLaunchingAtFront(&guard);
            break;
        case PREWARMED_SETTLES:
            OhrtGuardNotAskedFor(&guard);
            OhrtGuardLaunchingAtFront(&guard);
            OhrtGuardFinishedLaunching(&guard, 0);
            OhrtGuardBecameActive(&guard);
            OhrtGuardSettle(&guard);
            break;
        case LEFT_BEFORE_ACTIVE:
            OhrtGuardFinishedLaunching(&guard, 0);
            OhrtGuardLeft(&guard);
            break;
        case BACKGROUND_THEN_LEFT:
            OhrtGuardFinishedLaunching(&guard, 1);
            OhrtGuardLeft(&guard);
            break;
    }
    return guard.stored;
}

static void guard(void) {
    int safe;
    long stored;

    stored = run(0, SETTLES, &safe);
    CHECK("an ordinary start is not safe mode and leaves nothing", !safe && stored == 0);

    stored = run(0, DIES_LAUNCHING, &safe);
    CHECK("one death while launching is remembered", !safe && stored == 1);
    stored = run(stored, DIES_LAUNCHING, &safe);
    CHECK("a second one too, still not safe mode", !safe && stored == 2);
    stored = run(stored, SETTLES, &safe);
    CHECK("the third start is safe mode, and settling clears it", safe && stored == 0);
    run(stored, SETTLES, &safe);
    CHECK("the start after that is ordinary again", !safe);

    stored = run(run(0, DIES_AT_THE_FRONT, NULL), DIES_AT_THE_FRONT, NULL);
    run(stored, SETTLES, &safe);
    CHECK("two deaths at the front trip it", safe);

    stored = 0;
    for (int index = 0; index < 20; index++) stored = run(stored, DROPPED_IN_BACKGROUND, NULL);
    run(stored, SETTLES, &safe);
    CHECK("any number of background starts never trip it", !safe && stored == 0);

    stored = run(0, DIES_AT_THE_FRONT, NULL);
    stored = run(stored, DROPPED_IN_BACKGROUND, NULL);
    CHECK("a background start between two failures forgets neither", stored == 1);
    stored = run(stored, DIES_AT_THE_FRONT, NULL);
    run(stored, SETTLES, &safe);
    CHECK("so the second failure still trips it", safe);

    stored = run(run(0, FRONT_AFTER_BACKGROUND_DIES, NULL), FRONT_AFTER_BACKGROUND_DIES, NULL);
    run(stored, SETTLES, &safe);
    CHECK("dying at the front after a background start counts", stored == 2 && safe);
    CHECK("settling at the front after a background start clears", run(1, FRONT_AFTER_BACKGROUND_SETTLES, NULL) == 0);

    CHECK("leaving within the wait is not a failure", run(1, LEFT_QUICKLY, NULL) == 0);
    CHECK("nor is leaving before the app was ever at the front", run(1, LEFT_BEFORE_ACTIVE, NULL) == 0);
    CHECK("a background start that is told it left wipes nothing", run(1, BACKGROUND_THEN_LEFT, NULL) == 1);

    stored = 0;
    for (int index = 0; index < 20; index++) stored = run(stored, PREWARMED_AND_DROPPED, NULL);
    run(stored, SETTLES, &safe);
    CHECK("any number of prewarmed starts thrown away never trip it", !safe && stored == 0);
    CHECK("a prewarmed start between two failures forgets neither", run(1, PREWARMED_AND_DROPPED, NULL) == 1);
    stored = run(run(0, PREWARMED_DIES_LAUNCHING, NULL), PREWARMED_DIES_LAUNCHING, NULL);
    run(stored, SETTLES, &safe);
    CHECK("a prewarmed start that dies once it is launched counts", stored == 2 && safe);
    CHECK("a prewarmed start that settles clears", run(1, PREWARMED_SETTLES, NULL) == 0);
    CHECK("a death in safe mode keeps it tripped", run(2, DIES_LAUNCHING, &safe) == 3 && safe);
    CHECK("a nonsense stored value is treated as none", run(-5, DIES_LAUNCHING, &safe) == 1 && !safe);

    OhrtGuard twice;
    OhrtGuardStart(&twice, 0);
    CHECK("the wait starts on the first time at the front", OhrtGuardBecameActive(&twice) == 1);
    CHECK("and not again", OhrtGuardBecameActive(&twice) == 0);
    OhrtGuardSettle(&twice);
    OhrtGuardFinishedLaunching(&twice, 1);
    CHECK("a late launch notice does not unsettle", twice.stored == 0 && twice.settled);
}

int main(void) {
    time_budget();
    wall();
    follow_back();
    guard();
    if (failures) {
        printf("%d failed\n", failures);
        return 1;
    }
    printf("logic: all passed\n");
    return 0;
}
