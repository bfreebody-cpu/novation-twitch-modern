#include "TwitchA3Core.h"

#include <math.h>
#include <string.h>

static int32_t TwitchA3FloatToS24(float value)
{
    if (!isfinite(value)) return 0;
    if (value >= 1.0f) return 8388607;
    if (value <= -1.0f) return -8388608;
    long converted = lroundf(value * 8388608.0f);
    if (converted > 8388607) converted = 8388607;
    if (converted < -8388608) converted = -8388608;
    return (int32_t)converted;
}

static void TwitchA3WriteS24LE(float value, uint8_t *output)
{
    uint32_t bits = (uint32_t)TwitchA3FloatToS24(value);
    output[0] = (uint8_t)bits;
    output[1] = (uint8_t)(bits >> 8);
    output[2] = (uint8_t)(bits >> 16);
}

size_t TwitchA3SamplesForUSBFrame(uint64_t sequence, uint32_t sampleRate)
{
    if (sampleRate != 44100 && sampleRate != 48000) return 0;
    return (size_t)((((sequence + 1) * sampleRate) / 1000) -
                    ((sequence * sampleRate) / 1000));
}

size_t TwitchA3PackFloat32ToS24LE(const float *input,
                                 size_t frameCount,
                                 uint8_t *output,
                                 size_t outputCapacity)
{
    if (!input || !output || frameCount == 0 ||
        frameCount > SIZE_MAX / TwitchA3BytesPerAudioFrame) return 0;
    size_t required = frameCount * TwitchA3BytesPerAudioFrame;
    if (outputCapacity < required) return 0;
    for (size_t sample = 0; sample < frameCount * TwitchA3ChannelCount; sample++) {
        TwitchA3WriteS24LE(input[sample], output + sample * TwitchA3BytesPerSample);
    }
    return required;
}

bool TwitchA3RingInitialize(TwitchA3RingBuffer *ring,
                            float *storage,
                            size_t capacityFrames)
{
    if (!ring || !storage || capacityFrames == 0 ||
        capacityFrames > SIZE_MAX / TwitchA3ChannelCount) return false;
    memset(ring, 0, sizeof(*ring));
    ring->storage = storage;
    ring->capacityFrames = capacityFrames;
    return true;
}

size_t TwitchA3RingWrite(TwitchA3RingBuffer *ring,
                         const float *input,
                         size_t frameCount)
{
    if (!ring || !ring->storage || !input || frameCount == 0) return 0;
    size_t freeFrames = ring->capacityFrames - ring->availableFrames;
    size_t accepted = frameCount < freeFrames ? frameCount : freeFrames;
    for (size_t frame = 0; frame < accepted; frame++) {
        size_t destination = (ring->writeFrame + frame) % ring->capacityFrames;
        memcpy(ring->storage + destination * TwitchA3ChannelCount,
               input + frame * TwitchA3ChannelCount,
               TwitchA3ChannelCount * sizeof(float));
    }
    ring->writeFrame = (ring->writeFrame + accepted) % ring->capacityFrames;
    ring->availableFrames += accepted;
    ring->overrunFrames += frameCount - accepted;
    return accepted;
}

size_t TwitchA3RenderUSBPacket(TwitchA3RingBuffer *ring,
                               uint32_t sampleRate,
                               uint64_t usbFrameSequence,
                               uint8_t *output,
                               size_t outputCapacity)
{
    if (!ring || !ring->storage || !output) return 0;
    size_t frames = TwitchA3SamplesForUSBFrame(usbFrameSequence, sampleRate);
    if (frames == 0 || frames > SIZE_MAX / TwitchA3BytesPerAudioFrame) return 0;
    size_t required = frames * TwitchA3BytesPerAudioFrame;
    if (required > outputCapacity || required > TwitchA3MaximumUSBPacketBytes) return 0;

    for (size_t frame = 0; frame < frames; frame++) {
        bool hasFrame = ring->availableFrames > 0;
        size_t source = ring->readFrame;
        for (size_t channel = 0; channel < TwitchA3ChannelCount; channel++) {
            float sample = hasFrame
                ? ring->storage[source * TwitchA3ChannelCount + channel]
                : 0.0f;
            TwitchA3WriteS24LE(sample,
                output + (frame * TwitchA3ChannelCount + channel) * TwitchA3BytesPerSample);
        }
        if (hasFrame) {
            ring->readFrame = (ring->readFrame + 1) % ring->capacityFrames;
            ring->availableFrames--;
        } else {
            ring->underrunFrames++;
        }
    }
    return required;
}
