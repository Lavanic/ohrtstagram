// Our marks where Instagram shows its own.
//
//  - The wordmark at the top of the home feed. Instagram's is a picture on a
//    button in the feed's header, put back whenever the header's title
//    changes. Ours is swapped in after it is, and again from the header's
//    layout in case theirs arrives some other way.
//  - The logo on the login screen. That screen asks the app's asset catalog
//    for a picture by name, and is handed ours.
//  - The launch screen, which is not code: the build rewrites it (ipa.py
//    launch). What is left to do here is to throw away the pictures iOS
//    keeps of the old one.
//
// Each of ours is drawn into a picture the size of theirs, inside the part
// of theirs that is drawn on, so that it is as large as Instagram's own and
// everything around it stays where Instagram put it.
//
// The drawings are in ohrt/brand. The build puts pictures of them in the
// app's folder.
#import <objc/runtime.h>

#import "Ohrt.h"

NSString *const kOhrtWordmarkKey = @"ohrt_wordmark";

static NSString *const kOhrtLaunchBuildKey = @"ohrt_launch_build";

// What the login screen's logo is called in the asset catalog.
static NSString *const kOhrtLoginLogo = @"Instagram";

@interface IGHomeFeedHeaderView : UIView
@end

static char kOhrtOursKey;

static UIImage *OhrtWordmarkSource(void) {
    static UIImage *image;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        NSString *path = [[NSBundle mainBundle] pathForResource:@"OhrtWordmark" ofType:@"png"];
        if (path) image = [UIImage imageWithContentsOfFile:path];
        if (!image) OhrtLog(@"brand: the wordmark's picture is not in the app");
    });
    return image;
}

// The calico jack in the icon's colours, as on the launch screen.
static UIImage *OhrtGlyphSource(void) {
    static UIImage *image;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        NSString *path = [[NSBundle mainBundle] pathForResource:@"ohrt-splash@3x" ofType:@"png"];
        if (path) image = [UIImage imageWithContentsOfFile:path];
        if (!image) OhrtLog(@"brand: the mark's picture is not in the app");
    });
    return image;
}

// Where in a picture anything is drawn, in the picture's points. Empty when
// nothing is, or when it cannot be told.
static CGRect OhrtInkBounds(UIImage *image) {
    CGSize size = image.size;
    if (!(size.width >= 1 && size.height >= 1 && size.width <= 2000 && size.height <= 2000)) return CGRectZero;
    const CGFloat scale = 3;
    size_t width = (size_t)ceil(size.width * scale), height = (size_t)ceil(size.height * scale);
    uint8_t *alpha = calloc(width * height, 1);
    if (!alpha) return CGRectZero;
    CGContextRef context = CGBitmapContextCreate(alpha, width, height, 8, width, NULL, (CGBitmapInfo)kCGImageAlphaOnly);
    if (!context) {
        free(alpha);
        return CGRectZero;
    }
    // UIKit draws from the top left, which is also where the bytes begin.
    CGContextTranslateCTM(context, 0, height);
    CGContextScaleCTM(context, scale, -scale);
    UIGraphicsPushContext(context);
    [image drawInRect:CGRectMake(0, 0, size.width, size.height)];
    UIGraphicsPopContext();
    CGContextRelease(context);

    size_t left = width, top = height, right = 0, bottom = 0;
    BOOL any = NO;
    for (size_t y = 0; y < height; y++) {
        const uint8_t *row = alpha + y * width;
        for (size_t x = 0; x < width; x++) {
            if (row[x] < 24) continue;
            any = YES;
            if (x < left) left = x;
            if (x > right) right = x;
            if (y < top) top = y;
            if (y > bottom) bottom = y;
        }
    }
    free(alpha);
    if (!any) return CGRectZero;
    return CGRectMake(left / scale, top / scale, (right - left + 1) / scale, (bottom - top + 1) / scale);
}

// `source` standing in for `theirs`: a picture of the same size, with ours
// as large as fits inside the part of theirs that is drawn on, and centred
// there. `what` names it in the log.
static UIImage *OhrtMarkLike(UIImage *source, UIImage *theirs, BOOL template, NSString *what) {
    static NSCache *made;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        made = [NSCache new];
    });
    CGSize canvas = theirs.size;
    if (!source || source.size.width < 1 || source.size.height < 1 || !(canvas.width >= 1 && canvas.height >= 1)) return nil;
    NSString *key = [NSString stringWithFormat:@"%@ %.2f %.2f %d", what, canvas.width, canvas.height, template];
    UIImage *ours = [made objectForKey:key];
    if (ours) return ours;

    CGRect ink = OhrtInkBounds(theirs);
    if (CGRectIsEmpty(ink)) ink = CGRectMake(0, 0, canvas.width, canvas.height);
    CGFloat fit = MIN(ink.size.width / source.size.width, ink.size.height / source.size.height);
    CGSize size = CGSizeMake(source.size.width * fit, source.size.height * fit);
    CGRect place = CGRectMake(CGRectGetMidX(ink) - size.width / 2, CGRectGetMidY(ink) - size.height / 2, size.width, size.height);

    UIGraphicsImageRendererFormat *format = [UIGraphicsImageRendererFormat preferredFormat];
    format.opaque = NO;
    UIGraphicsImageRenderer *renderer = [[UIGraphicsImageRenderer alloc] initWithSize:canvas format:format];
    UIImage *drawn = [renderer imageWithActions:^(UIGraphicsImageRendererContext *context) {
        [source drawInRect:place];
    }];
    ours = [drawn imageWithRenderingMode:template ? UIImageRenderingModeAlwaysTemplate : UIImageRenderingModeAlwaysOriginal];
    if (!ours) return nil;
    objc_setAssociatedObject(ours, &kOhrtOursKey, @YES, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    [made setObject:ours forKey:key];
    OhrtLog(@"brand: the %@ is %.0f by %.0f in theirs of %.0f by %.0f, which is drawn on over %.0f by %.0f", what, size.width, size.height, canvas.width,
            canvas.height, ink.size.width, ink.size.height);
    return ours;
}

static void OhrtPutWordmark(UIView *header) {
    static BOOL gaveUp;
    if (gaveUp) return;
    static Ivar ivar;
    if (!ivar) ivar = class_getInstanceVariable([header class], "_logoButton");
    UIButton *button = ivar ? object_getIvar(header, ivar) : nil;
    if (![button isKindOfClass:[UIButton class]]) button = nil;
    UIImage *shown = [button imageForState:UIControlStateNormal];
    // Once, what the header turned out to hold, for reading off the phone.
    static BOOL described;
    if (!described) {
        described = YES;
        OhrtLog(@"brand: the header is %@, its logo button %@, showing a picture of %@ and the title %@", NSStringFromClass([header class]),
                button ? NSStringFromClass([button class]) : @"not found", shown ? NSStringFromCGSize(shown.size) : @"nothing",
                [button titleForState:UIControlStateNormal] ?: @"nothing");
    }
    if (!button) return;
    // No picture means a title is showing in its place.
    if (!shown || objc_getAssociatedObject(shown, &kOhrtOursKey)) return;
    // The button colours the picture, as it does theirs.
    UIImage *ours = OhrtMarkLike(OhrtWordmarkSource(), shown, YES, @"wordmark");
    if (!ours) return;
    [button setImage:ours forState:UIControlStateNormal];
    if ([button imageForState:UIControlStateNormal] != ours) {
        // The button did not keep what it was given. Asking again from
        // every layout would never end.
        gaveUp = YES;
        OhrtLog(@"brand: the header's button did not keep the wordmark, so theirs stays");
        return;
    }
    [button sizeToFit];
    [header setNeedsLayout];
}

// Notes, once each, the pictures the app asks for that look like branding,
// so that the next place worth changing can be read off the phone.
static void OhrtNoteAsset(NSString *name, UIImage *image) {
    static NSMutableSet<NSString *> *noted;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        noted = [NSMutableSet set];
    });
    @synchronized(noted) {
        if (noted.count >= 60 || [noted containsObject:name]) return;
        [noted addObject:name];
    }
    OhrtLog(@"brand: the app asked for its picture %@, %.0f by %.0f%@", name, image.size.width, image.size.height,
            image.renderingMode == UIImageRenderingModeAlwaysTemplate ? @", to be coloured" : @"");
}

static BOOL OhrtLooksBranded(NSString *name) {
    return [name rangeOfString:@"nstagram"].location != NSNotFound || [name rangeOfString:@"ordmark"].location != NSNotFound ||
           [name rangeOfString:@"logo"].location != NSNotFound;
}

%group OhrtBrandHeader

%hook IGHomeFeedHeaderView
- (void)setTitle:(id)title animated:(BOOL)animated {
    %orig;
    OhrtTry(@"wordmark", ^{
        OhrtPutWordmark(self);
    });
}
- (void)layoutSubviews {
    %orig;
    OhrtTry(@"wordmark", ^{
        OhrtPutWordmark(self);
    });
}
%end

%end

%group OhrtBrandAssets

// Every picture from the app's asset catalog comes through here, on
// whichever thread asked.
%hook UIImage
+ (UIImage *)imageNamed:(NSString *)name inBundle:(NSBundle *)bundle compatibleWithTraitCollection:(UITraitCollection *)traits {
    UIImage *image = %orig;
    if (!image || ![name isKindOfClass:[NSString class]] || !OhrtLooksBranded(name)) return image;
    OhrtNoteAsset(name, image);
    if (![name isEqualToString:kOhrtLoginLogo]) return image;
    // A logo taller than it is wide is their mark; a wide one is their name.
    BOOL wide = image.size.width > image.size.height * 2;
    BOOL template = wide || image.renderingMode == UIImageRenderingModeAlwaysTemplate;
    UIImage *ours = OhrtMarkLike(wide ? OhrtWordmarkSource() : OhrtGlyphSource(), image, template, @"login logo");
    return ours ?: image;
}
%end

%end

// iOS keeps pictures of an app's launch screen and does not always notice
// that an update changed it. They are thrown away once per build, and iOS
// makes them again from the launch screen that is there now.
static void OhrtForgetLaunchPictures(void) {
    NSUserDefaults *defaults = [NSUserDefaults standardUserDefaults];
    if ([[defaults stringForKey:kOhrtLaunchBuildKey] isEqualToString:OHRT_BUILD]) return;
    NSString *kept = [NSHomeDirectory() stringByAppendingPathComponent:@"Library/SplashBoard"];
    NSFileManager *files = [NSFileManager defaultManager];
    BOOL had = [files fileExistsAtPath:kept];
    BOOL gone = !had || [files removeItemAtPath:kept error:nil];
    OhrtLog(@"brand: iOS's pictures of the launch screen %@", !had ? @"were not there" : gone ? @"were thrown away" : @"could not be thrown away");
    if (gone) [defaults setObject:OHRT_BUILD forKey:kOhrtLaunchBuildKey];
}

void OhrtInstallBrand(void) {
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        OhrtForgetLaunchPictures();
        if (!OhrtFeature(kOhrtWordmarkKey)) {
            OhrtLog(@"brand: our marks are switched off");
            return;
        }
        if (OhrtGlyphSource()) %init(OhrtBrandAssets);
        NSString *missing = OhrtMissing(@"wordmark");
        if (missing) OhrtLog(@"brand: the wordmark is left out, this Instagram lacks %@", missing);
        else if (OhrtWordmarkSource()) %init(OhrtBrandHeader);
        OhrtLog(@"brand: our marks are on");
    });
}
