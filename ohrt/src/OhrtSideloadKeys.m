// Instagram makes its device key pairs in a keychain group shared by Meta's
// apps. A sideloaded copy is not signed for that group, so making them
// fails with errSecMissingEntitlement and the keys are never there to
// read. The sideload fix (zxPluginsInject) moves stored keychain items to a
// group the copy does have, but not this call. A key pair refused for that
// reason is made again in that same group, where the fix's reads find it.
#import <Security/Security.h>
#import <dlfcn.h>

#import "Ohrt.h"
#import "../modules/zxPluginsInject/fishhook/fishhook.c"

typedef struct __SecTask *SecTaskRef;
extern SecTaskRef SecTaskCreateFromSelf(CFAllocatorRef allocator);
extern CFTypeRef SecTaskCopyValueForEntitlement(SecTaskRef task, CFStringRef entitlement, CFErrorRef *error);

static SecKeyRef (*gOhrtKeyMake)(CFDictionaryRef, CFErrorRef *);

// The keychain group this copy may use: the one the sideload fix moves
// stored items to, or failing that the first one the copy is signed for.
static NSString *OhrtKeyGroup(void) {
    static NSString *group;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        NSString *__strong *theirs = (NSString *__strong *)dlsym(RTLD_DEFAULT, "accessGroupId");
        if (theirs && [*theirs isKindOfClass:[NSString class]] && [*theirs length]) group = [*theirs copy];
        if (group) return;
        SecTaskRef task = SecTaskCreateFromSelf(NULL);
        id groups = task ? CFBridgingRelease(SecTaskCopyValueForEntitlement(task, CFSTR("keychain-access-groups"), NULL)) : nil;
        if (task) CFRelease((CFTypeRef)task);
        id first = [groups isKindOfClass:[NSArray class]] ? [groups firstObject] : nil;
        if ([first isKindOfClass:[NSString class]]) group = [first copy];
    });
    return group;
}

// What was asked for, with every keychain group it names changed to ours.
static NSDictionary *OhrtKeyMoved(NSDictionary *asked, NSString *group) {
    NSMutableDictionary *moved = [asked mutableCopy];
    id groupKey = (__bridge id)kSecAttrAccessGroup;
    if (moved[groupKey]) moved[groupKey] = group;
    for (id part in @[ (__bridge id)kSecPrivateKeyAttrs, (__bridge id)kSecPublicKeyAttrs ]) {
        if (![moved[part] isKindOfClass:[NSDictionary class]] || !moved[part][groupKey]) continue;
        NSMutableDictionary *inner = [moved[part] mutableCopy];
        inner[groupKey] = group;
        moved[part] = inner;
    }
    return moved;
}

static SecKeyRef OhrtKeyMake(CFDictionaryRef parameters, CFErrorRef *error) {
    CFErrorRef failure = NULL;
    SecKeyRef key = gOhrtKeyMake(parameters, &failure);
    NSString *ours = OhrtKeyGroup();
    if (!key && failure && CFErrorGetCode(failure) == errSecMissingEntitlement && ours.length && [(__bridge id)parameters isKindOfClass:[NSDictionary class]]) {
        CFErrorRef again = NULL;
        SecKeyRef moved = gOhrtKeyMake((__bridge CFDictionaryRef)OhrtKeyMoved((__bridge NSDictionary *)parameters, ours), &again);
        static int told;
        if (__sync_fetch_and_add(&told, 1) < 4) OhrtLog(@"sideload: a key pair refused in Meta's shared group was %@ in this copy's own", moved ? @"made" : @"refused too");
        if (moved) {
            CFRelease(failure);
            failure = NULL;
            key = moved;
        } else if (again) {
            CFRelease(again);
        }
    }
    if (error) *error = failure;
    else if (failure) CFRelease(failure);
    return key;
}

void OhrtInstallSideloadKeys(void) {
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        struct rebinding binds[1] = {{"SecKeyCreateRandomKey", (void *)OhrtKeyMake, (void **)&gOhrtKeyMake}};
        rebind_symbols(binds, 1);
    });
}
