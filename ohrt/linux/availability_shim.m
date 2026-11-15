// @available(...) compiles to a call to __isOSVersionAtLeast, which Apple's
// toolchain supplies from its compiler runtime (libclang_rt.ios.a). The
// toolchain Theos uses on Linux ships without that library, so the link fails
// on the one symbol. These are the same two functions, answered from
// NSProcessInfo.
//
// Only built on Linux: ohrt/build.sh adds this file to the tweak's sources.
// A Mac build links Apple's own and must not get a second copy.
#import <Foundation/Foundation.h>

static NSOperatingSystemVersion OHRTSystemVersion(void) {
    static NSOperatingSystemVersion version;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        version = [[NSProcessInfo processInfo] operatingSystemVersion];
    });
    return version;
}

__attribute__((visibility("hidden")))
int32_t __isOSVersionAtLeast(int32_t major, int32_t minor, int32_t subminor) {
    NSOperatingSystemVersion version = OHRTSystemVersion();
    if (version.majorVersion != major) return version.majorVersion > major;
    if (version.minorVersion != minor) return version.minorVersion > minor;
    return version.patchVersion >= subminor;
}

// Newer compilers call this one instead. Platform 2 is iOS; the tweak is
// never loaded anywhere else.
__attribute__((visibility("hidden")))
int32_t __isPlatformVersionAtLeast(uint32_t platform, uint32_t major, uint32_t minor, uint32_t subminor) {
    (void)platform;
    return __isOSVersionAtLeast((int32_t)major, (int32_t)minor, (int32_t)subminor);
}
