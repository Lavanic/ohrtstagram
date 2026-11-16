// Upstream takes the suggested accounts out of a profile's header, but
// leaves the grey block that stands in for them while they load. With the
// accounts gone nothing ever takes its place, so it stays as a blank gap.
// It goes out with them, under the same switch.
#import "../../src/Utils.h"
#import "Ohrt.h"

@interface IGProfileHeaderView : UIView
@end

// What a profile's header is made of, a few times, for reading off the
// phone: it is how the next thing to move or remove there gets found.
static void OhrtNoteHeader(NSArray *objects) {
    static NSString *last;
    static int noted;
    if (noted >= 6) return;
    NSMutableArray<NSString *> *names = [NSMutableArray array];
    for (id object in objects) [names addObject:NSStringFromClass([object class])];
    NSString *list = [names componentsJoinedByString:@", "];
    if ([list isEqualToString:last]) return;
    last = list;
    noted++;
    OhrtLog(@"profile: its header holds %@", list);
}

%group OhrtSuggested

%hook IGProfileHeaderView
- (id)objectsForListAdapter:(id)adapter {
    NSArray *objects = %orig;
    if (![objects isKindOfClass:[NSArray class]]) return objects;
    OhrtNoteHeader(objects);
    Class standIn = NSClassFromString(@"IGProfileChainingShimmerModel");
    if (!standIn || ![SCIUtils getBoolPref:@"no_suggested_users"]) return objects;
    NSMutableArray *kept = [NSMutableArray arrayWithCapacity:objects.count];
    for (id object in objects) {
        if (![object isKindOfClass:standIn]) [kept addObject:object];
    }
    if (kept.count != objects.count) {
        static BOOL said;
        if (!said) {
            said = YES;
            OhrtLog(@"profile: the block that stands in for suggested accounts is taken out");
        }
    }
    return kept;
}
%end

%end

void OhrtInstallSuggested(void) {
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        if (OhrtSafeLaunch() || OhrtMissing(@"suggested")) return;
        %init(OhrtSuggested);
    });
}
