// The wordmark: "ohrtstagram" where the top of the home feed says
// "Instagram". The drawing is ohrt/brand/wordmark.svg, and the build puts a
// picture of it in the app's folder.
//
// Instagram shows its own as a picture on a button in the feed's header and
// puts it back whenever the header's title changes. Ours is swapped in after
// it does, and again from the header's layout in case theirs arrives some
// other way. It is drawn to the height of the letters in theirs, not of the
// picture, which may have room around them, and it keeps their picture's
// height so that it sits on the same line.
#import <objc/runtime.h>

#import "Ohrt.h"

NSString *const kOhrtWordmarkKey = @"ohrt_wordmark";

@interface IGHomeFeedHeaderView : UIView
@end

static char kOhrtOursKey;

static UIImage *OhrtWordmarkSource(void) {
    static UIImage *image;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        NSString *path = [[NSBundle mainBundle] pathForResource:@"OhrtWordmark" ofType:@"png"];
        if (path) image = [UIImage imageWithContentsOfFile:path];
        if (!image) OhrtLog(@"wordmark: its picture is not in the app");
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

// Our wordmark, made to stand in for their picture. Only ever asked for on
// the main thread.
static UIImage *OhrtWordmarkLike(UIImage *theirs) {
    static UIImage *last;
    static CGSize lastSize;
    CGSize canvas = theirs.size;
    if (last && CGSizeEqualToSize(lastSize, canvas)) return last;
    UIImage *source = OhrtWordmarkSource();
    if (!source || source.size.height < 1 || !(canvas.width >= 1 && canvas.height >= 1)) return nil;

    CGRect ink = OhrtInkBounds(theirs);
    if (CGRectIsEmpty(ink)) ink = CGRectMake(0, 0, canvas.width, canvas.height);
    CGFloat width = ink.size.height * source.size.width / source.size.height;
    CGFloat left = ink.origin.x;
    CGFloat right = MAX(0, canvas.width - CGRectGetMaxX(ink));
    CGSize size = CGSizeMake(ceil(left + width + right), canvas.height);

    UIGraphicsImageRendererFormat *format = [UIGraphicsImageRendererFormat preferredFormat];
    format.opaque = NO;
    UIGraphicsImageRenderer *renderer = [[UIGraphicsImageRenderer alloc] initWithSize:size format:format];
    UIImage *drawn = [renderer imageWithActions:^(UIGraphicsImageRendererContext *context) {
        [source drawInRect:CGRectMake(left, ink.origin.y, width, ink.size.height)];
    }];
    // Only its shape is used. The button colours it, as it does theirs.
    UIImage *ours = [drawn imageWithRenderingMode:UIImageRenderingModeAlwaysTemplate];
    if (!ours) return nil;
    objc_setAssociatedObject(ours, &kOhrtOursKey, @YES, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    last = ours;
    lastSize = canvas;
    OhrtLog(@"wordmark: theirs is %.0f by %.0f with letters %.1f tall, ours is %.0f by %.0f", canvas.width, canvas.height, ink.size.height, size.width,
            size.height);
    return ours;
}

static void OhrtPutWordmark(UIView *header) {
    static BOOL gaveUp;
    if (gaveUp) return;
    static Ivar ivar;
    if (!ivar) ivar = class_getInstanceVariable([header class], "_logoButton");
    if (!ivar) return;
    UIButton *button = object_getIvar(header, ivar);
    if (![button isKindOfClass:[UIButton class]]) return;
    UIImage *shown = [button imageForState:UIControlStateNormal];
    // No picture means a title is showing in its place.
    if (!shown || objc_getAssociatedObject(shown, &kOhrtOursKey)) return;
    UIImage *ours = OhrtWordmarkLike(shown);
    if (!ours) return;
    [button setImage:ours forState:UIControlStateNormal];
    if ([button imageForState:UIControlStateNormal] != ours) {
        // The button did not keep what it was given. Asking again from
        // every layout would never end.
        gaveUp = YES;
        OhrtLog(@"wordmark: the header's button did not keep the picture, so theirs stays");
        return;
    }
    [button sizeToFit];
    [header setNeedsLayout];
}

%group OhrtWordmark

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

void OhrtInstallWordmark(void) {
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        if (!OhrtFeatureReady(kOhrtWordmarkKey, @"wordmark") || !OhrtWordmarkSource()) return;
        %init(OhrtWordmark);
    });
}
