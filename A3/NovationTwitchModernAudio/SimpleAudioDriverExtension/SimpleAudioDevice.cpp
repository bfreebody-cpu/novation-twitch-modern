/*
See LICENSE.txt for Apple sample licensing information.

Adapted for the Novation Twitch playback-only AudioDriverKit prototype.
*/

#include "SimpleAudioDevice.h"
#include "SimpleAudioDriver.h"

#include <AudioDriverKit/AudioDriverKit.h>
#include <DriverKit/DriverKit.h>
#include <USBDriverKit/IOUSBHostInterface.h>
#include <USBDriverKit/IOUSBHostPipe.h>

#define kSampleRate_1 44100.0
#define kSampleRate_2 48000.0

constexpr uint32_t kTwitchOutputChannels = 4;
constexpr uint8_t kTwitchPlaybackEndpoint = 0x01;

struct SimpleAudioDevice_IVars
{
    OSSharedPtr<IOUserAudioDriver> m_driver;
    OSSharedPtr<IODispatchQueue> m_work_queue;
    OSSharedPtr<IOUSBHostInterface> m_usb_interface;
    OSSharedPtr<IOUSBHostPipe> m_playback_pipe;
    bool m_usb_open { false };

    IOUserAudioStreamBasicDescription m_stream_format;
    OSSharedPtr<IOUserAudioStream> m_output_stream;
    OSSharedPtr<IOMemoryMap> m_output_memory_map;

    OSSharedPtr<IOTimerDispatchSource> m_zts_timer_event_source;
    OSSharedPtr<OSAction> m_zts_timer_occurred_action;
    uint64_t m_zts_host_ticks_per_buffer { 0 };
};

bool SimpleAudioDevice::init(IOUserAudioDriver* in_driver,
                             bool in_supports_prewarming,
                             OSString* in_device_uid,
                             OSString* in_model_uid,
                             OSString* in_manufacturer_uid,
                             uint32_t in_zero_timestamp_period)
{
    if (!super::init(in_driver, in_supports_prewarming, in_device_uid,
                     in_model_uid, in_manufacturer_uid, in_zero_timestamp_period)) {
        return false;
    }

    ivars = IONewZero(SimpleAudioDevice_IVars, 1);
    if (ivars == nullptr) return false;

    IOReturn error = kIOReturnSuccess;
    ivars->m_driver = OSSharedPtr(in_driver, OSRetain);
    ivars->m_work_queue = GetWorkQueue();

    double sample_rates[] = { kSampleRate_1, kSampleRate_2 };
    SetAvailableSampleRates(sample_rates, 2);
    SetSampleRate(kSampleRate_2);

    IOUserAudioChannelLabel output_layout[kTwitchOutputChannels] = {
        IOUserAudioChannelLabel::Left,
        IOUserAudioChannelLabel::Right,
        IOUserAudioChannelLabel::LeftSurroundDirect,
        IOUserAudioChannelLabel::RightSurroundDirect,
    };

    IOUserAudioStreamBasicDescription formats[] = {
        { kSampleRate_1, IOUserAudioFormatID::LinearPCM,
          IOUserAudioFormatFlags::FormatFlagsNativeFloatPacked,
          sizeof(float) * kTwitchOutputChannels, 1,
          sizeof(float) * kTwitchOutputChannels,
          kTwitchOutputChannels, 32 },
        { kSampleRate_2, IOUserAudioFormatID::LinearPCM,
          IOUserAudioFormatFlags::FormatFlagsNativeFloatPacked,
          sizeof(float) * kTwitchOutputChannels, 1,
          sizeof(float) * kTwitchOutputChannels,
          kTwitchOutputChannels, 32 },
    };

    OSSharedPtr<IOBufferMemoryDescriptor> output_ring;
	auto stream_name = OSSharedPtr(
		OSString::withCString("MASTER 1/2, CUE 3/4"), OSNoRetain);
	IOTimerDispatchSource* timer = nullptr;
	OSAction* timer_action = nullptr;
	IOOperationHandler operation = ^kern_return_t(
		IOUserAudioObjectID, IOUserAudioIOOperation, uint32_t, uint64_t, uint64_t) {
		// HAL has produced Float32 frames in the output ring. The bounded USB
		// scheduler will consume and pack them in the next A3 implementation step.
		return kIOReturnSuccess;
	};
    const auto buffer_bytes = static_cast<uint32_t>(
        in_zero_timestamp_period * sizeof(float) * kTwitchOutputChannels);
    error = IOBufferMemoryDescriptor::Create(kIOMemoryDirectionInOut,
                                             buffer_bytes, 0,
                                             output_ring.attach());
    FailIfError(error, , Failure, "failed to create output ring");

    ivars->m_output_stream = IOUserAudioStream::Create(
        in_driver, IOUserAudioStreamDirection::Output, output_ring.get());
    FailIfNULL(ivars->m_output_stream.get(), error = kIOReturnNoMemory,
               Failure, "failed to create output stream");

    ivars->m_output_stream->SetName(stream_name.get());
    ivars->m_output_stream->SetAvailableStreamFormats(formats, 2);
    ivars->m_stream_format = formats[1];
    ivars->m_output_stream->SetCurrentStreamFormat(&ivars->m_stream_format);
    error = AddStream(ivars->m_output_stream.get());
    FailIfError(error, , Failure, "failed to add output stream");

    SetPreferredOutputChannelLayout(output_layout, kTwitchOutputChannels);
    SetPreferredChannelsForStereo(1, 2);
    SetTransportType(IOUserAudioTransportType::USB);

    error = IOTimerDispatchSource::Create(ivars->m_work_queue.get(), &timer);
    FailIfError(error, , Failure, "failed to create timestamp timer");
    ivars->m_zts_timer_event_source = OSSharedPtr(timer, OSNoRetain);
    error = CreateActionZtsTimerOccurred(sizeof(void*), &timer_action);
    FailIfError(error, , Failure, "failed to create timestamp action");
    ivars->m_zts_timer_occurred_action = OSSharedPtr(timer_action, OSNoRetain);
    ivars->m_zts_timer_event_source->SetHandler(
        ivars->m_zts_timer_occurred_action.get());

    SetIOOperationHandler(operation);
    return true;

Failure:
    ivars->m_driver.reset();
    ivars->m_output_stream.reset();
    ivars->m_zts_timer_event_source.reset();
    ivars->m_zts_timer_occurred_action.reset();
    return false;
}

void SimpleAudioDevice::SetUSBInterface(IOUSBHostInterface* in_interface)
{
    ivars->m_usb_interface = OSSharedPtr(in_interface, OSRetain);
}

void SimpleAudioDevice::free()
{
    if (ivars != nullptr) {
        RestoreUSBState();
        ivars->m_output_memory_map.reset();
        ivars->m_output_stream.reset();
        ivars->m_usb_interface.reset();
        ivars->m_driver.reset();
        ivars->m_zts_timer_occurred_action.reset();
        ivars->m_zts_timer_event_source.reset();
        ivars->m_work_queue.reset();
    }
    IOSafeDeleteNULL(ivars, SimpleAudioDevice_IVars, 1);
    super::free();
}

kern_return_t SimpleAudioDevice::StartIO(IOUserAudioStartStopFlags in_flags)
{
    __block kern_return_t error = kIOReturnSuccess;
    __block OSSharedPtr<IOMemoryDescriptor> output_iomd;
	__block IOUSBHostPipe* pipe = nullptr;

    ivars->m_work_queue->DispatchSync(^() {
        FailIfNULL(ivars->m_usb_interface.get(), error = kIOReturnNoDevice,
                   Failure, "missing Twitch interface 0 provider");

        error = ivars->m_usb_interface->Open(ivars->m_driver.get(), 0, nullptr);
        FailIfError(error, , Failure, "failed to open Twitch interface 0");
        ivars->m_usb_open = true;

        error = ivars->m_usb_interface->SelectAlternateSetting(1);
        FailIfError(error, , Failure, "failed to select interface 0 alt 1");

        error = ivars->m_usb_interface->CopyPipe(kTwitchPlaybackEndpoint, &pipe);
        FailIfError(error, , Failure, "failed to open endpoint 0x01");
        ivars->m_playback_pipe = OSSharedPtr(pipe, OSNoRetain);

        error = super::StartIO(in_flags);
        FailIfError(error, , Failure, "failed to start AudioDriverKit IO");

        output_iomd = ivars->m_output_stream->GetIOMemoryDescriptor();
        FailIfNULL(output_iomd.get(), error = kIOReturnNoMemory,
                   Failure, "missing output memory descriptor");
        error = output_iomd->CreateMapping(0, 0, 0, 0, 0,
                                           ivars->m_output_memory_map.attach());
        FailIfError(error, , Failure, "failed to map output ring");

        error = StartTimers();
        FailIfError(error, , Failure, "failed to start timestamps");
        return;

    Failure:
        super::StopIO(in_flags);
        ivars->m_output_memory_map.reset();
        RestoreUSBState();
    });
    return error;
}

kern_return_t SimpleAudioDevice::StopIO(IOUserAudioStartStopFlags in_flags)
{
    __block kern_return_t error = kIOReturnSuccess;
    ivars->m_work_queue->DispatchSync(^() {
        StopTimers();
        ivars->m_output_memory_map.reset();
        RestoreUSBState();
        error = super::StopIO(in_flags);
    });
    return error;
}

void SimpleAudioDevice::RestoreUSBState()
{
    ivars->m_playback_pipe.reset();
    if (ivars->m_usb_open && ivars->m_usb_interface.get() != nullptr) {
        ivars->m_usb_interface->SelectAlternateSetting(0);
        ivars->m_usb_interface->Close(ivars->m_driver.get(), 0);
    }
    ivars->m_usb_open = false;
}

kern_return_t SimpleAudioDevice::PerformDeviceConfigurationChange(
    uint64_t change_action, OSObject* in_change_info)
{
    if (change_action != k_custom_config_change_action) {
        return super::PerformDeviceConfigurationChange(change_action, in_change_info);
    }
    double next = GetSampleRate() == kSampleRate_1 ? kSampleRate_2 : kSampleRate_1;
    kern_return_t error = SetSampleRate(next);
    if (error == kIOReturnSuccess) {
        error = ivars->m_output_stream->DeviceSampleRateChanged(next);
        ivars->m_stream_format = ivars->m_output_stream->GetCurrentStreamFormat();
        UpdateTimers();
    }
    return error;
}

kern_return_t SimpleAudioDevice::AbortDeviceConfigurationChange(
    uint64_t change_action, OSObject* in_change_info)
{
    return super::AbortDeviceConfigurationChange(change_action, in_change_info);
}

kern_return_t SimpleAudioDevice::HandleChangeSampleRate(double in_sample_rate)
{
    if (in_sample_rate != kSampleRate_1 && in_sample_rate != kSampleRate_2) {
        return kIOReturnUnsupported;
    }
    kern_return_t error = SetSampleRate(in_sample_rate);
    if (error == kIOReturnSuccess) {
        ivars->m_stream_format = ivars->m_output_stream->GetCurrentStreamFormat();
        UpdateTimers();
    }
    return error;
}

kern_return_t SimpleAudioDevice::ToggleDataSource()
{
    return kIOReturnUnsupported;
}

kern_return_t SimpleAudioDevice::StartTimers()
{
    UpdateTimers();
    UpdateCurrentZeroTimestamp(0, 0);
    auto now = mach_absolute_time();
    ivars->m_zts_timer_event_source->WakeAtTime(
        kIOTimerClockMachAbsoluteTime,
        now + ivars->m_zts_host_ticks_per_buffer, 0);
    ivars->m_zts_timer_event_source->SetEnable(true);
    return kIOReturnSuccess;
}

void SimpleAudioDevice::StopTimers()
{
    if (ivars->m_zts_timer_event_source.get() != nullptr) {
        ivars->m_zts_timer_event_source->SetEnable(false);
    }
}

void SimpleAudioDevice::UpdateTimers()
{
    mach_timebase_info_data_t info;
    mach_timebase_info(&info);
    double ticks = static_cast<double>(GetZeroTimestampPeriod()) * NSEC_PER_SEC /
                   GetSampleRate();
    ticks = ticks * info.denom / info.numer;
    ivars->m_zts_host_ticks_per_buffer = static_cast<uint64_t>(ticks);
}

void SimpleAudioDevice::ZtsTimerOccurred_Impl(OSAction*, uint64_t time)
{
    uint64_t sample_time = 0;
    uint64_t host_time = 0;
    GetCurrentZeroTimestamp(&sample_time, &host_time);
    if (host_time == 0) {
        sample_time = 0;
        host_time = time;
    } else {
        sample_time += GetZeroTimestampPeriod();
        host_time += ivars->m_zts_host_ticks_per_buffer;
    }
    UpdateCurrentZeroTimestamp(sample_time, host_time);
    ivars->m_zts_timer_event_source->WakeAtTime(
        kIOTimerClockMachAbsoluteTime,
        host_time + ivars->m_zts_host_ticks_per_buffer, 0);
}
