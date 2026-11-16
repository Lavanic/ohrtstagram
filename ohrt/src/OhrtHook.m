// Puts a hook in with its original already in place.
//
// The hooking library swaps the method first and hands back the original a
// moment later. While the tweak is being loaded nothing else is running and
// the gap cannot be hit. Hooks put in as the app launches are another
// matter: a call from another thread inside the gap would reach our code
// with no original to pass on to, and crash. So the original is read off
// the class and stored before the swap. The library then stores its own
// answer over it, which is the same method.
//
// Ohrt.h points every hook of ours here, the ones Logos writes included.
// This file must not include it.
#import <objc/runtime.h>
#import <substrate.h>

void OhrtHookMessage(Class cls, SEL selector, IMP replacement, IMP *original) {
    if (original && cls && selector) {
        Method method = class_getInstanceMethod(cls, selector);
        if (method) *original = method_getImplementation(method);
    }
    MSHookMessageEx(cls, selector, replacement, original);
}
