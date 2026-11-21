#include <CoreFoundation/CoreFoundation.h>

// Every test process starts from the app's default settings. The app keeps them in the test runner's own defaults,
// so a run killed before it put back what it changed would hand them to the next run. This runs as the test bundle
// loads, before any test reads a setting; Swift has no hook that early.
__attribute__((constructor)) static void startFromDefaultSettings(void) {
    CFArrayRef keys =
        CFPreferencesCopyKeyList(kCFPreferencesCurrentApplication, kCFPreferencesCurrentUser, kCFPreferencesAnyHost);
    if (keys == NULL) return;
    for (CFIndex index = 0; index < CFArrayGetCount(keys); index++) {
        CFStringRef key = CFArrayGetValueAtIndex(keys, index);
        // The app names its settings area.name in lower case. The system's start with a capital and stay: whoever runs
        // the tests may set them here, such as AppleKeyboardUIMode, which turns on keyboard navigation and so decides
        // which focus-ring checks run.
        UniChar first = CFStringGetLength(key) > 0 ? CFStringGetCharacterAtIndex(key, 0) : 0;
        if (first >= 'a' && first <= 'z' && CFStringFind(key, CFSTR("."), 0).location != kCFNotFound
            && !CFStringHasPrefix(key, CFSTR("com.apple."))) {
            CFPreferencesSetAppValue(key, NULL, kCFPreferencesCurrentApplication);
        }
    }
    CFRelease(keys);
    CFPreferencesAppSynchronize(kCFPreferencesCurrentApplication);
}
