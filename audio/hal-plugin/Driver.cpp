// SPDX-License-Identifier: MIT
// USB-independent AudioServerPlugIn feasibility probe.

#include <aspl/ControlRequestHandler.hpp>
#include <aspl/Device.hpp>
#include <aspl/Driver.hpp>
#include <aspl/IORequestHandler.hpp>
#include <aspl/Plugin.hpp>
#include <aspl/Stream.hpp>

#include "SharedAudioRing.hpp"
#include "XPCClient.hpp"

#include <CoreAudio/AudioServerPlugIn.h>
#include <CoreFoundation/CoreFoundation.h>
#include <os/log.h>

#include <atomic>
#include <cstdlib>
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

class SharedMemoryHandler;

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

    void SetSharedMemoryHandler(
        const std::shared_ptr<SharedMemoryHandler>& handler)
    {
        sharedMemoryHandler_ = handler;
    }

    std::vector<AudioValueRange> GetAvailableSampleRates() const override
    {
        return {{44100.0, 44100.0}, {48000.0, 48000.0}};
    }

protected:
    OSStatus SetNominalSampleRateImpl(Float64 rate) override;

private:
    std::weak_ptr<ExperimentalOutputStream> outputStream_;
    std::weak_ptr<SharedMemoryHandler> sharedMemoryHandler_;
};

class SharedMemoryHandler final : public aspl::ControlRequestHandler,
                                  public aspl::IORequestHandler
{
public:
    SharedMemoryHandler()
    {
        Connect();
    }

    void Connect()
    {
        if (ring_) {
            const auto snapshot = ring_->Snapshot();
            const auto now = twitch::audio::MonotonicTimeNs();
            const bool consumerFresh = snapshot.consumerActive != 0 &&
                now >= snapshot.consumerHeartbeatNs &&
                now - snapshot.consumerHeartbeatNs < 2000000000ULL;
            if (consumerFresh) {
                return;
            }
            // The on-demand service exits after a completed stream. Discard
            // its now-orphaned mapping before the next StartIO acquisition.
            ring_.reset();
        }
        const char* overrideName =
            std::getenv("TWITCH_AUDIO_SHARED_MEMORY_NAME");
        std::string transport;
        std::string error;
        if (overrideName != nullptr) {
            auto [ring, result] =
                twitch::audio::SharedAudioRing::Open(overrideName);
            ring_ = std::move(ring);
            transport = overrideName;
            if (!result) {
                error = result.message;
            }
        } else {
            auto [ring, result] = twitch::audio::ConnectToXPCService();
            ring_ = std::move(ring);
            transport = "xpc";
            if (!result) {
                error = result.message;
            }
        }
        if (!ring_) {
            os_log_error(OS_LOG_DEFAULT,
                "Twitch HAL shared memory unavailable: %{public}s",
                error.c_str());
        } else {
            os_log(OS_LOG_DEFAULT,
                "Twitch HAL shared memory connected: transport=%{public}s "
                "version=%u capacity=%u",
                transport.c_str(),
                twitch::audio::kSharedAudioVersion,
                twitch::audio::kRingCapacityFrames);
        }
    }

    ~SharedMemoryHandler() override
    {
        if (ring_ && active_.exchange(false, std::memory_order_acq_rel)) {
            ring_->ProducerStop();
        }
    }

    OSStatus OnStartIO() override
    {
        startCount_.fetch_add(1, std::memory_order_relaxed);
        // coreaudiod may load the plug-in before the logged-in user's
        // LaunchAgent is registered. Retry only at the non-real-time StartIO
        // lifecycle boundary; the mixed-output callback never performs IPC.
        Connect();
        if (ring_ && !active_.exchange(true, std::memory_order_acq_rel)) {
            ring_->ProducerStart(sampleRate_.load(std::memory_order_relaxed));
        }
        os_log(OS_LOG_DEFAULT,
            "Twitch HAL bridge StartIO: starts=%{public}llu rate=%u",
            startCount_.load(std::memory_order_relaxed),
            sampleRate_.load(std::memory_order_relaxed));
        return kAudioHardwareNoError;
    }

    void OnStopIO() override
    {
        if (ring_ && active_.exchange(false, std::memory_order_acq_rel)) {
            ring_->ProducerStop();
        }
        os_log(OS_LOG_DEFAULT,
            "Twitch HAL bridge StopIO: callbacks=%{public}llu bytes=%{public}llu",
            callbackCount_.load(std::memory_order_relaxed),
            byteCount_.load(std::memory_order_relaxed));
    }

    void OnWriteMixedOutput(const std::shared_ptr<aspl::Stream>&,
        Float64,
        Float64 sampleTime,
        const void* bytes,
        UInt32 byteCount) override
    {
        callbackCount_.fetch_add(1, std::memory_order_relaxed);
        byteCount_.fetch_add(byteCount, std::memory_order_relaxed);
        constexpr UInt32 bytesPerFrame = kChannelCount * sizeof(Float32);
        if (ring_ && bytes != nullptr && byteCount % bytesPerFrame == 0) {
            ring_->TryWrite(static_cast<const float*>(bytes),
                byteCount / bytesPerFrame, sampleTime);
        }
    }

    void SetSampleRate(UInt32 sampleRate) noexcept
    {
        sampleRate_.store(sampleRate, std::memory_order_relaxed);
        if (ring_) {
            ring_->SetSampleRate(sampleRate);
        }
    }

private:
    std::unique_ptr<twitch::audio::SharedAudioRing> ring_;
    std::atomic<bool> active_ {false};
    std::atomic<UInt32> sampleRate_ {static_cast<UInt32>(kInitialSampleRate)};
    std::atomic<UInt64> startCount_ {0};
    std::atomic<UInt64> callbackCount_ {0};
    std::atomic<UInt64> byteCount_ {0};
};

OSStatus ExperimentalDevice::SetNominalSampleRateImpl(Float64 rate)
{
    if (rate != 44100.0 && rate != 48000.0) {
        return kAudioHardwareUnsupportedOperationError;
    }

    const OSStatus status = aspl::Device::SetNominalSampleRateImpl(rate);
    if (status == kAudioHardwareNoError) {
        if (const auto stream = outputStream_.lock()) {
            stream->ApplySampleRate(rate);
        }
        if (const auto handler = sharedMemoryHandler_.lock()) {
            handler->SetSampleRate(static_cast<UInt32>(rate));
        }
    }
    return status;
}

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

    auto handler = std::make_shared<SharedMemoryHandler>();
    device->SetSharedMemoryHandler(handler);
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
