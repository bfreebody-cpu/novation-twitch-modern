// SPDX-License-Identifier: MIT
// Live Core Audio verification for the installed USB-independent HAL probe.

#include <CoreAudio/AudioHardware.h>
#include <CoreFoundation/CoreFoundation.h>

#include <atomic>
#include <chrono>
#include <cstdio>
#include <cstring>
#include <thread>
#include <vector>

namespace {

constexpr const char* kDeviceUID = "com.twitchmodern.audio.experimental.device";

std::atomic<UInt64> gCallbackCount {0};
std::atomic<UInt64> gFrameCount {0};

bool Check(OSStatus status, const char* operation)
{
    if (status == noErr) {
        return true;
    }
    std::fprintf(stderr, "FAIL: %s returned %d (0x%08x)\n",
        operation, status, static_cast<unsigned int>(status));
    return false;
}

template <typename T>
bool ReadProperty(AudioObjectID object,
    AudioObjectPropertySelector selector,
    AudioObjectPropertyScope scope,
    T& value)
{
    const AudioObjectPropertyAddress address = {selector, scope,
        kAudioObjectPropertyElementMain};
    UInt32 size = sizeof(value);
    return Check(AudioObjectGetPropertyData(
        object, &address, 0, nullptr, &size, &value), "AudioObjectGetPropertyData");
}

AudioObjectID FindDevice()
{
    CFStringRef uid = CFStringCreateWithCString(
        kCFAllocatorDefault, kDeviceUID, kCFStringEncodingUTF8);
    AudioObjectID device = kAudioObjectUnknown;
    const AudioObjectPropertyAddress address = {
        kAudioHardwarePropertyTranslateUIDToDevice,
        kAudioObjectPropertyScopeGlobal,
        kAudioObjectPropertyElementMain,
    };
    UInt32 size = sizeof(device);
    const OSStatus status = AudioObjectGetPropertyData(
        kAudioObjectSystemObject, &address, sizeof(uid), &uid, &size, &device);
    CFRelease(uid);
    return Check(status, "translate device UID") ? device : kAudioObjectUnknown;
}

std::vector<AudioValueRange> AvailableRates(AudioObjectID device)
{
    const AudioObjectPropertyAddress address = {
        kAudioDevicePropertyAvailableNominalSampleRates,
        kAudioObjectPropertyScopeGlobal,
        kAudioObjectPropertyElementMain,
    };
    UInt32 size = 0;
    if (!Check(AudioObjectGetPropertyDataSize(
            device, &address, 0, nullptr, &size), "available rate size")) {
        return {};
    }
    std::vector<AudioValueRange> rates(size / sizeof(AudioValueRange));
    if (!Check(AudioObjectGetPropertyData(
            device, &address, 0, nullptr, &size, rates.data()), "available rates")) {
        return {};
    }
    return rates;
}

UInt32 OutputChannelCount(AudioObjectID device)
{
    const AudioObjectPropertyAddress address = {
        kAudioDevicePropertyStreamConfiguration,
        kAudioDevicePropertyScopeOutput,
        kAudioObjectPropertyElementMain,
    };
    UInt32 size = 0;
    if (!Check(AudioObjectGetPropertyDataSize(
            device, &address, 0, nullptr, &size), "output stream config size")) {
        return 0;
    }
    std::vector<unsigned char> storage(size);
    auto* list = reinterpret_cast<AudioBufferList*>(storage.data());
    if (!Check(AudioObjectGetPropertyData(
            device, &address, 0, nullptr, &size, list), "output stream config")) {
        return 0;
    }
    UInt32 channels = 0;
    for (UInt32 index = 0; index < list->mNumberBuffers; ++index) {
        channels += list->mBuffers[index].mNumberChannels;
    }
    return channels;
}

OSStatus IOProc(AudioObjectID,
    const AudioTimeStamp*,
    const AudioBufferList*,
    const AudioTimeStamp*,
    AudioBufferList* output,
    const AudioTimeStamp*,
    void*)
{
    UInt32 frames = 0;
    if (output != nullptr) {
        for (UInt32 index = 0; index < output->mNumberBuffers; ++index) {
            auto& buffer = output->mBuffers[index];
            if (buffer.mData != nullptr) {
                std::memset(buffer.mData, 0, buffer.mDataByteSize);
            }
            if (buffer.mNumberChannels > 0) {
                frames = buffer.mDataByteSize /
                    (buffer.mNumberChannels * static_cast<UInt32>(sizeof(Float32)));
            }
        }
    }
    gCallbackCount.fetch_add(1, std::memory_order_relaxed);
    gFrameCount.fetch_add(frames, std::memory_order_relaxed);
    return noErr;
}

bool SetRate(AudioObjectID device, Float64 rate)
{
    const AudioObjectPropertyAddress address = {
        kAudioDevicePropertyNominalSampleRate,
        kAudioObjectPropertyScopeGlobal,
        kAudioObjectPropertyElementMain,
    };
    if (!Check(AudioObjectSetPropertyData(
            device, &address, 0, nullptr, sizeof(rate), &rate), "set nominal rate")) {
        return false;
    }
    for (int attempt = 0; attempt < 50; ++attempt) {
        Float64 observed = 0;
        if (!ReadProperty(device, kAudioDevicePropertyNominalSampleRate,
                kAudioObjectPropertyScopeGlobal, observed)) {
            return false;
        }
        if (observed == rate) {
            return true;
        }
        std::this_thread::sleep_for(std::chrono::milliseconds(20));
    }
    std::fprintf(stderr, "FAIL: rate did not become %.0f\n", rate);
    return false;
}

bool ExerciseIO(AudioObjectID device, Float64 rate)
{
    if (!SetRate(device, rate)) {
        return false;
    }
    gCallbackCount.store(0, std::memory_order_relaxed);
    gFrameCount.store(0, std::memory_order_relaxed);

    AudioDeviceIOProcID ioProc = nullptr;
    if (!Check(AudioDeviceCreateIOProcID(device, IOProc, nullptr, &ioProc),
            "AudioDeviceCreateIOProcID")) {
        return false;
    }
    if (!Check(AudioDeviceStart(device, ioProc), "AudioDeviceStart")) {
        AudioDeviceDestroyIOProcID(device, ioProc);
        return false;
    }
    std::this_thread::sleep_for(std::chrono::milliseconds(500));
    const bool stopped = Check(AudioDeviceStop(device, ioProc), "AudioDeviceStop");
    const bool destroyed = Check(
        AudioDeviceDestroyIOProcID(device, ioProc), "AudioDeviceDestroyIOProcID");

    const auto callbacks = gCallbackCount.load(std::memory_order_relaxed);
    const auto frames = gFrameCount.load(std::memory_order_relaxed);
    std::printf("io rate=%.0f callbacks=%llu frames=%llu\n", rate, callbacks, frames);
    if (callbacks == 0 || frames == 0) {
        std::fprintf(stderr, "FAIL: no output callbacks at %.0f Hz\n", rate);
        return false;
    }
    return stopped && destroyed;
}

} // namespace

int main()
{
    const AudioObjectID device = FindDevice();
    if (device == kAudioObjectUnknown) {
        std::fputs("FAIL: experimental device not found\n", stderr);
        return 1;
    }

    const UInt32 channels = OutputChannelCount(device);
    const auto rates = AvailableRates(device);
    std::printf("device=%u uid=%s output_channels=%u rates=", device, kDeviceUID, channels);
    for (const auto& rate : rates) {
        std::printf("%.0f-%.0f ", rate.mMinimum, rate.mMaximum);
    }
    std::puts("");

    if (channels != 4 || rates.size() != 2) {
        std::fputs("FAIL: unexpected channel or rate inventory\n", stderr);
        return 1;
    }
    if (!ExerciseIO(device, 44100.0) || !ExerciseIO(device, 48000.0)) {
        return 1;
    }

    std::puts("PASS: HAL discovery, channel/rate inventory, and StartIO/StopIO");
    return 0;
}
