// The app's own text says "ohrtstagram" where it said "Instagram".
//
// This is done where text is put on a label, the plain kind that buttons,
// titles, menus and alerts are made of. What people write (captions,
// comments, messages) is drawn by Instagram's own text views and does not
// pass through here, so their words are left as they wrote them. A label
// can still hold a person's words now and then, and those change too.
//
// Left alone: "Instagram" inside a longer word, an address or a handle
// (OhrtLogic.h says which), and the word as our own screens write it when
// they mean Instagram itself (Ohrt.h says how).
#import "Ohrt.h"
#import "OhrtLogic.h"

NSString *const kOhrtNameKey = @"ohrt_name";

static NSString *const kOhrtTheirs = @"Instagram";
static NSString *const kOhrtOurs = @"ohrtstagram";

// Longer than anything on a button or in a title. Longer text is somebody's
// writing, or the small print, which is about Instagram and should say so.
static const NSUInteger kOhrtLongest = 160;

// The places in `text` where their name stands as a name. Nil when there
// are none.
static NSArray<NSValue *> *OhrtNamePlaces(NSString *text) {
    NSUInteger length = text.length;
    if (length < kOhrtTheirs.length || length > kOhrtLongest) return nil;
    NSMutableArray<NSValue *> *places = nil;
    NSRange search = NSMakeRange(0, length);
    while (search.length >= kOhrtTheirs.length) {
        NSRange found = [text rangeOfString:kOhrtTheirs options:NSLiteralSearch range:search];
        if (found.location == NSNotFound) break;
        NSUInteger end = NSMaxRange(found);
        unichar before = found.location > 0 ? [text characterAtIndex:found.location - 1] : ' ';
        unichar after = end < length ? [text characterAtIndex:end] : ' ';
        unichar next = end + 1 < length ? [text characterAtIndex:end + 1] : ' ';
        if (OhrtNameStandsAlone(before, after, next)) {
            if (!places) places = [NSMutableArray array];
            [places addObject:[NSValue valueWithRange:found]];
        }
        search = NSMakeRange(end, length - end);
    }
    return places;
}

static NSString *OhrtRenamed(NSString *text) {
    NSArray<NSValue *> *places = OhrtNamePlaces(text);
    if (!places) return nil;
    NSMutableString *renamed = [text mutableCopy];
    // From the end, so the places found earlier stay where they were.
    for (NSValue *place in places.reverseObjectEnumerator) [renamed replaceCharactersInRange:place.rangeValue withString:kOhrtOurs];
    return renamed;
}

static NSAttributedString *OhrtRenamedAttributed(NSAttributedString *text) {
    NSArray<NSValue *> *places = OhrtNamePlaces(text.string);
    if (!places) return nil;
    NSMutableAttributedString *renamed = [text mutableCopy];
    for (NSValue *place in places.reverseObjectEnumerator) [renamed replaceCharactersInRange:place.rangeValue withString:kOhrtOurs];
    return renamed;
}

%group OhrtName

%hook UILabel
- (void)setText:(NSString *)text {
    NSString *renamed = [text isKindOfClass:[NSString class]] ? OhrtRenamed(text) : nil;
    %orig(renamed ?: text);
}
- (void)setAttributedText:(NSAttributedString *)text {
    NSAttributedString *renamed = [text isKindOfClass:[NSAttributedString class]] ? OhrtRenamedAttributed(text) : nil;
    %orig(renamed ?: text);
}
%end

%end

void OhrtInstallName(void) {
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        BOOL on = OhrtFeature(kOhrtNameKey);
        if (on) %init(OhrtName);
        OhrtLog(@"name: the app's text %@", on ? @"says ohrtstagram" : @"is left as it is");
    });
}
