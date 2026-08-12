// SPDX-License-Identifier: MIT
// USB-independent AudioServerPlugIn feasibility probe.

#include <aspl/ControlRequestHandler.hpp>
#include <aspl/Device.hpp>
#include <aspl/Driver.hpp>
#include <aspl/IORequestHandler.hpp>
#include <aspl/Plugin.hpp>
#include <aspl/Stream.hpp>

#include <CoreAudio/AudioServerPlugIn.h>
#include <CoreFoundation/CoreFoundation.h>
#include <os/log.h>

#include <atomic>
#include <memory>
#include <vector>

namespace {

constexpr Float64 kInitialSampleRate = 48000.0;
constexpr UInt32 kChannelCount = 4;

AudioStreamBasicDescription MakeFormat(Float64 sampleRate)
{
    return {
        .mSampleRate = sampleRate,
        .mFormatID = kAudioFormatLinearPCM,
        .mFormatFlags = kAudioFormatFlagIsFloat | kAudioFormatFlagsNativeEndian |
                        kAudioFormatFlagIsPacked,
        .mBytesPerPacket = kChannelCount * sizeof(Float32),
        .mFramesPerPacket = 1,
        .mBytesPerFrame = kChannelCount * sizeof(Float32),
        .mChannelsPerFrame = kChannelCount,
        .mBitsPerChannel = 8 * sizeof(Float32),
        .mReserved = 0,
    };
}

std::vector<AudioStreamRangedDescription> AvailableFormats()
{
    std::vector<AudioStreamRangedDescription> formats;
    for (const Float64 rate : {44100.0, 48000.0}) {
        AudioStreamRangedDescription description = {};
        description.mFormat = MakeFormat(rate);
        description.mSampleRateRange = {rate, rate};
        formats.push_back(description);
    }
    return formats;
}

class ExperimentalOutputStream final : public aspl::Stream
{
public:
    ExperimentalOutputStream(std::shared_ptr<const aspl::Context> context,
        const std::shared_ptr<aspl::Device>& device,
        const aspl::StreamParameters& parameters)
        : aspl::Stream(std::move(context), device, parameters)
    {
    }

    std::vector<AudioStreamRangedDescription> GetAvailablePhysicalFormats() const override
    {
        return AvailableFormats();
    }

    std::vector<AudioStreamRangedDescription> GetAvailableVirtualFormats() const override
    {
        return AvailableFormats();
    }

    void ApplySampleRate(Float64 rate)
    {
        const auto format = MakeFormat(rate);
        aspl::Stream::SetPhysicalFormatImpl(format);
        aspl::Stream::SetVirtualFormatImpl(format);
    }
};

class ExperimentalDevice final : public aspl::Device
{
public:
    ExperimentalDevice(std::shared_ptr<const aspl::Context> context,
        const aspl::DeviceParameters& parameters)
        : aspl::Device(std::move(context), parameters)
    {
    }

    void SetOutputStream(const std::shared_ptr<ExperimentalOutputStream>& stream)
    {
        outputStream_ = stream;
    }

    std::vector<AudioValueRange> GetAvailableSampleRates() const override
    {
        return {{44100.0, 44100.0}, {48000.0, 48000.0}};
    }

protected:
    OSStatus SetNominalSampleRateImpl(Float64 rate) override
    {
        if (rate != 44100.0 && rate != 48000.0) {
            return kAudioHardwareUnsupportedOperationError;
        }

        const OSStatus status = aspl::Device::SetNominalSampleRateImpl(rate);
        if (status == kAudioHardwareNoError) {
            if (const auto stream = outputStream_.lock()) {
                stream->ApplySampleRate(rate);
            }
        }
        return status;
    }

private:
    std::weak_ptr<ExperimentalOutputStream> outputStream_;
};

class DiscardHandler final : public aspl::ControlRequestHandler,
                             public aspl::IORequestHandler
{
public:
    OSStatus OnStartIO() override
    {
        startCount_.fetch_add(1, std::memory_order_relaxed);
        os_log(OS_LOG_DEFAULT,
            "Twitch HAL probe StartIO: starts=%{public}llu",
            startCount_.load(std::memory_order_relaxed));
        return kAudioHardwareNoError;
    }

    void OnStopIO() override
    {
        os_log(OS_LOG_DEFAULT,
            "Twitch HAL probe StopIO: callbacks=%{public}llu bytes=%{public}llu",
            callbackCount_.load(std::memory_order_relaxed),
            byteCount_.load(std::memory_order_relaxed));
    }

    void OnWriteMixedOutput(const std::shared_ptr<aspl::Stream>&,
        Float64,
        Float64,
        const void*,
        UInt32 byteCount) override
    {
        callbackCount_.fetch_add(1, std::memory_order_relaxed);
        byteCount_.fetch_add(byteCount, std::memory_order_relaxed);
    }

private:
    std::atomic<UInt64> startCount_ {0};
    std::atomic<UInt64> callbackCount_ {0};
    std::atomic<UInt64> byteCount_ {0};
};

std::shared_ptr<aspl::Driver> CreateDriver()
{
    auto context = std::make_shared<aspl::Context>();

    aspl::DeviceParameters deviceParameters;
    deviceParameters.Name = "Novation Twitch Modern Audio - Experimental";
    deviceParameters.Manufacturer = "Novation Twitch Modern community";
    deviceParameters.DeviceUID = "com.twitchmodern.audio.experimental.device";
    deviceParameters.ModelUID = "com.twitchmodern.audio.experimental.model";
    deviceParameters.SampleRate = static_cast<UInt32>(kInitialSampleRate);
    deviceParameters.ChannelCount = kChannelCount;
    deviceParameters.EnableMixing = true;
    deviceParameters.ClockIsStable = true;

    auto device = std::make_shared<ExperimentalDevice>(context, deviceParameters);

    aspl::StreamParameters streamParameters;
    streamParameters.Direction = aspl::Direction::Output;
    streamParameters.StartingChannel = 1;
    streamParameters.Format = MakeFormat(kInitialSampleRate);

    auto stream = std::make_shared<ExperimentalOutputStream>(
        context, device, streamParameters);
    device->SetOutputStream(stream);
    device->AddStreamAsync(stream);

    auto handler = std::make_shared<DiscardHandler>();
    device->SetControlHandler(handler);
    device->SetIOHandler(handler);

    aspl::PluginParameters pluginParameters;
    pluginParameters.Manufacturer = "Novation Twitch Modern community";
    auto plugin = std::make_shared<aspl::Plugin>(context, pluginParameters);
    plugin->AddDevice(device);

    return std::make_shared<aspl::Driver>(context, plugin);
}

} // namespace

extern "C" void* NovationTwitchModernAudioExperimental_Create(
    CFAllocatorRef,
    CFUUIDRef requestedType)
{
    if (!CFEqual(requestedType, kAudioServerPlugInTypeUUID)) {
        return nullptr;
    }

    static const std::shared_ptr<aspl::Driver> driver = CreateDriver();
    return driver->GetReference();
}
