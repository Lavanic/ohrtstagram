// Shows the like count on a post whose owner has hidden it.
//
// Instagram asks one object whether a post's counts are to be kept from
// view. It says yes for a post whose owner hid them, for a post in an older
// trial that hid them from everyone ("daisy"), or because you chose in
// Instagram's own settings not to see counts on other people's posts. With
// this on it is asked as though the first two were not so. Your own choice
// still stands.
//
// There is only a number to show if Instagram sent one with the post. The
// log says what came with the first such posts seen in the feed.
#import <objc/message.h>

#import "Ohrt.h"

NSString *const kOhrtLikesKey = @"ohrt_hidden_likes";

@interface IGMediaInteractionCountVisibilityHelper : NSObject
@end

@interface IGUFIInteractionCountProvider : NSObject
@end

static void OhrtLikesSay(NSString *what) {
    static NSMutableSet<NSString *> *said;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        said = [NSMutableSet set];
    });
    @synchronized(said) {
        if ([said containsObject:what]) return;
        [said addObject:what];
    }
    OhrtLog(@"likes: %@", what);
}

// Whether `object` answers `name` with a value of the kind `wanted`
// ('B' or 'q'), so that it can be asked without guessing.
static BOOL OhrtLikesAnswers(id object, SEL name, char wanted) {
    NSMethodSignature *signature = [object respondsToSelector:name] ? [object methodSignatureForSelector:name] : nil;
    if (!signature || signature.numberOfArguments != 2) return NO;
    char kind = signature.methodReturnType[0];
    return wanted == 'B' ? (kind == 'B' || kind == 'c') : kind == wanted;
}

static void OhrtLikesLook(id model) {
    SEL hidden = NSSelectorFromString(@"likeAndViewCountsDisabled"), count = NSSelectorFromString(@"likeCount");
    if (!OhrtLikesAnswers(model, hidden, 'B') || !OhrtLikesAnswers(model, count, 'q')) return;
    if (!((BOOL (*)(id, SEL))objc_msgSend)(model, hidden)) return;
    long long likes = ((long long (*)(id, SEL))objc_msgSend)(model, count);
    if (likes < 0) OhrtLikesSay(@"a post that hides its count came with a count below 0");
    else if (likes == 0) OhrtLikesSay(@"a post that hides its count came with a count of 0");
    else OhrtLikesSay([NSString stringWithFormat:@"a post that hides its count came with a count of %lu digits", (unsigned long)[NSString stringWithFormat:@"%lld", likes].length]);
}

%group OhrtLikes

%hook IGMediaInteractionCountVisibilityHelper
- (BOOL)shouldHideLikeAndViewCountsForMediaUserPK:(id)pk likeAndViewCountsDisabled:(BOOL)disabled mediaIsInDaisy:(BOOL)daisy {
    if (disabled) OhrtLikesSay(@"asked about a post whose owner hid its count");
    if (daisy) OhrtLikesSay(@"asked about a post in the old trial");
    return %orig(pk, NO, NO);
}
%end

%hook IGUFIInteractionCountProvider
- (id)initWithViewModel:(id)model interactionCountVisibilityHelper:(id)helper {
    id provider = %orig;
    OhrtTry(@"likes", ^{
        OhrtLikesLook(model);
    });
    return provider;
}
%end

%end

void OhrtInstallLikes(void) {
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        if (!OhrtFeatureReady(kOhrtLikesKey, @"likes")) return;
        %init(OhrtLikes);
        OhrtLog(@"likes: counts their owners hid are shown");
    });
}
