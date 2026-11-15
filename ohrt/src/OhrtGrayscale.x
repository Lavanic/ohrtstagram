// Grayscale: the whole app in grey, by a saturation filter on each of its
// windows. It costs some smoothness while it is on: a filtered window is
// drawn off screen first. Nothing here touches Instagram's classes.
#import <QuartzCore/QuartzCore.h>

#import "Ohrt.h"

NSString *const kOhrtGrayscaleKey = @"ohrt_grayscale";

static NSString *const kOhrtFilterName = @"ohrtGrayscale";

// Core Animation's filter class is not in the public headers.
@interface NSObject (OhrtCAFilter)
+ (id)filterWithType:(NSString *)type;
@end

static void OhrtSetGrayscale(UIWindow *window, BOOL on) {
    CALayer *layer = window.layer;
    NSMutableArray *filters = [NSMutableArray array];
    BOOL present = NO;
    for (id filter in layer.filters) {
        if ([[filter valueForKey:@"name"] isEqual:kOhrtFilterName]) present = YES;
        else [filters addObject:filter];
    }
    if (on == present) return;
    if (on) {
        Class filterClass = NSClassFromString(@"CAFilter");
        if (![filterClass respondsToSelector:@selector(filterWithType:)]) return;
        id filter = [filterClass filterWithType:@"colorSaturate"];
        [filter setValue:@0 forKey:@"inputAmount"];
        [filter setValue:kOhrtFilterName forKey:@"name"];
        [filters addObject:filter];
    }
    layer.filters = filters.count ? filters : nil;
}

static void OhrtGrayscaleRefresh(void) {
    BOOL on = OhrtFeature(kOhrtGrayscaleKey);
    for (UIScene *scene in [UIApplication sharedApplication].connectedScenes) {
        if (![scene isKindOfClass:[UIWindowScene class]]) continue;
        for (UIWindow *window in ((UIWindowScene *)scene).windows) OhrtSetGrayscale(window, on);
    }
}

// Windows come and go (sheets, alerts, the lock screen), so each one gets
// the filter as it is shown.
%hook UIWindow
- (void)setHidden:(BOOL)hidden {
    %orig;
    if (!hidden && OhrtFeature(kOhrtGrayscaleKey)) OhrtSetGrayscale(self, YES);
}
- (void)makeKeyAndVisible {
    %orig;
    if (OhrtFeature(kOhrtGrayscaleKey)) OhrtSetGrayscale(self, YES);
}
%end

%ctor {
    %init;
    // The settings switch only writes the preference; this is what makes it
    // take effect on the spot.
    static BOOL last;
    last = OhrtBool(kOhrtGrayscaleKey);
    [[NSNotificationCenter defaultCenter] addObserverForName:NSUserDefaultsDidChangeNotification object:nil queue:[NSOperationQueue mainQueue]
                                                  usingBlock:^(NSNotification *note) {
        BOOL now = OhrtFeature(kOhrtGrayscaleKey);
        if (now == last) return;
        last = now;
        OhrtGrayscaleRefresh();
    }];
}
