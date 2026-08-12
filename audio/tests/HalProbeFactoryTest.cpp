// SPDX-License-Identifier: MIT

#include <CoreAudio/AudioServerPlugIn.h>
#include <CoreFoundation/CoreFoundation.h>

#include <cstdio>
#include <cstring>

namespace {

using FactoryFunction = void* (*)(CFAllocatorRef, CFUUIDRef);

int Fail(const char* message)
{
    std::fprintf(stderr, "FAIL: %s\n", message);
    return 1;
}

} // namespace

int main(int argc, char** argv)
{
    if (argc != 2) {
        return Fail("expected path to experimental .driver bundle");
    }

    const auto* pathBytes = reinterpret_cast<const UInt8*>(argv[1]);
    CFURLRef bundleURL = CFURLCreateFromFileSystemRepresentation(
        kCFAllocatorDefault, pathBytes, std::strlen(argv[1]), true);
    if (bundleURL == nullptr) {
        return Fail("could not create bundle URL");
    }

    CFBundleRef bundle = CFBundleCreate(kCFAllocatorDefault, bundleURL);
    CFRelease(bundleURL);
    if (bundle == nullptr) {
        return Fail("could not create CFBundle");
    }

    const CFStringRef expectedIdentifier =
        CFSTR("com.twitchmodern.NovationTwitchModernAudioExperimental");
    if (!CFEqual(CFBundleGetIdentifier(bundle), expectedIdentifier)) {
        CFRelease(bundle);
        return Fail("unexpected bundle identifier");
    }

    if (!CFBundleLoadExecutable(bundle)) {
        CFRelease(bundle);
        return Fail("could not load bundle executable");
    }

    const auto factory = reinterpret_cast<FactoryFunction>(
        CFBundleGetFunctionPointerForName(
            bundle, CFSTR("NovationTwitchModernAudioExperimental_Create")));
    if (factory == nullptr) {
        CFBundleUnloadExecutable(bundle);
        CFRelease(bundle);
        return Fail("factory entry point not exported");
    }

    CFUUIDRef wrongType = CFUUIDCreate(kCFAllocatorDefault);
    const bool rejectedWrongType = factory(kCFAllocatorDefault, wrongType) == nullptr;
    CFRelease(wrongType);
    if (!rejectedWrongType) {
        CFBundleUnloadExecutable(bundle);
        CFRelease(bundle);
        return Fail("factory accepted an unrelated plug-in type");
    }

    if (factory(kCFAllocatorDefault, kAudioServerPlugInTypeUUID) == nullptr) {
        CFBundleUnloadExecutable(bundle);
        CFRelease(bundle);
        return Fail("factory rejected kAudioServerPlugInTypeUUID");
    }

    // The factory owns process-lifetime C++ statics whose destructors reside in
    // the bundle, so deliberately leave the bundle loaded until process exit.
    std::puts("PASS: bundle identity, load, entry point, and type filtering");
    return 0;
}
