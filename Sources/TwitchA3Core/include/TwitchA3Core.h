#ifndef TWITCH_A3_CORE_H
#define TWITCH_A3_CORE_H

#include <stdbool.h>
#include <stddef.h>
#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

enum {
    TwitchA3ChannelCount = 4,
    TwitchA3BytesPerSample = 3,
    TwitchA3BytesPerAudioFrame = TwitchA3ChannelCount * TwitchA3BytesPerSample,
    TwitchA3MaximumUSBPacketBytes = 588,
};

typedef struct TwitchA3RingBuffer {
    float *storage;
    size_t capacityFrames;
    size_t readFrame;
    size_t writeFrame;
    size_t availableFrames;
    uint64_t underrunFrames;
    uint64_t overrunFrames;
} TwitchA3RingBuffer;

/// Returns 44 or 45 at 44.1 kHz and 48 at 48 kHz; returns zero for invalid input.
size_t TwitchA3SamplesForUSBFrame(uint64_t sequence, uint32_t sampleRate);

/// Converts four-channel interleaved Float32 PCM to signed packed-24 LE.
/// Returns bytes written, or zero when an argument/capacity check fails.
size_t TwitchA3PackFloat32ToS24LE(const float *input,
                                 size_t frameCount,
                                 uint8_t *output,
                                 size_t outputCapacity);

/// Initializes a bounded four-channel ring using caller-owned storage.
bool TwitchA3RingInitialize(TwitchA3RingBuffer *ring,
                            float *storage,
                            size_t capacityFrames);

/// Writes as many complete frames as fit and counts rejected frames as overruns.
size_t TwitchA3RingWrite(TwitchA3RingBuffer *ring,
                         const float *input,
                         size_t frameCount);

/// Renders exactly one USB packet. Missing source frames become deterministic
/// silence and are counted as underruns. Returns packet bytes, or zero on error.
size_t TwitchA3RenderUSBPacket(TwitchA3RingBuffer *ring,
                               uint32_t sampleRate,
                               uint64_t usbFrameSequence,
                               uint8_t *output,
                               size_t outputCapacity);

#ifdef __cplusplus
}
#endif

#endif
