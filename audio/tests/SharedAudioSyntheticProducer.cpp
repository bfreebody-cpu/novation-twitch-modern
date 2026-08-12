// SPDX-License-Identifier: MIT

#include "SharedAudioRing.hpp"

#include <chrono>
#include <cstdio>
#include <cstdlib>
#include <cstring>
#include <thread>
#include <vector>

namespace {

struct Options {
    std::string name {twitch::audio::kDefaultSharedMemoryName};
    double durationSeconds {5};
    std::uint32_t sampleRate {48000};
    std::uint32_t callbackFrames {512};
};

bool ParseDouble(const char* text, double& value)
{
    char* end = nullptr;
    value = std::strtod(text, &end);
    return end != text && *end == '\0';
}

bool ParseUnsigned(const char* text, std::uint32_t& value)
{
    char* end = nullptr;
    const auto parsed = std::strtoul(text, &end, 10);
    if (end == text || *end != '\0' || parsed > UINT32_MAX) {
        return false;
    }
    value = static_cast<std::uint32_t>(parsed);
    return true;
}

bool Parse(int argc, char** argv, Options& options)
{
    for (int index = 1; index < argc; ++index) {
        if (index + 1 >= argc) {
            return false;
        }
        const char* value = argv[++index];
        if (std::strcmp(argv[index - 1], "--name") == 0) {
            options.name = value;
        } else if (std::strcmp(argv[index - 1], "--duration") == 0) {
            if (!ParseDouble(value, options.durationSeconds)) {
                return false;
            }
        } else if (std::strcmp(argv[index - 1], "--rate") == 0) {
            if (!ParseUnsigned(value, options.sampleRate)) {
                return false;
            }
        } else if (std::strcmp(argv[index - 1], "--callback-frames") == 0) {
            if (!ParseUnsigned(value, options.callbackFrames)) {
                return false;
            }
        } else {
            return false;
        }
    }
    return options.durationSeconds > 0 &&
        (options.sampleRate == 44100 || options.sampleRate == 48000) &&
        options.callbackFrames > 0 &&
        options.callbackFrames <= twitch::audio::kRingCapacityFrames;
}

} // namespace

int main(int argc, char** argv)
{
    Options options;
    if (!Parse(argc, argv, options)) {
        std::fprintf(stderr,
            "Usage: %s [--name /shm-name] [--duration SECONDS] "
            "[--rate 44100|48000] [--callback-frames N]\n",
            argv[0]);
        return 2;
    }

    auto [ring, result] = twitch::audio::SharedAudioRing::Open(options.name);
    if (!result) {
        std::fprintf(stderr, "shared-memory open failed: %s errno=%d\n",
            result.message.c_str(), result.systemError);
        return 1;
    }

    ring->ProducerStart(options.sampleRate);
    std::vector<float> frames(
        static_cast<std::size_t>(options.callbackFrames) *
        twitch::audio::kChannelCount);
    const auto start = std::chrono::steady_clock::now();
    auto deadline = start;
    std::uint64_t callbacks = 0;
    std::uint64_t lateDeadlines = 0;

    while (std::chrono::duration<double>(
               std::chrono::steady_clock::now() - start)
               .count() < options.durationSeconds) {
        const auto snapshot = ring->Snapshot();
        for (std::uint32_t frame = 0; frame < options.callbackFrames; ++frame) {
            for (std::uint32_t channel = 0;
                 channel < twitch::audio::kChannelCount; ++channel) {
                frames[static_cast<std::size_t>(frame) *
                           twitch::audio::kChannelCount +
                    channel] = twitch::audio::SyntheticPatternSample(
                    snapshot.writeFrame + frame, channel);
            }
        }
        ring->TryWrite(frames.data(), options.callbackFrames,
            static_cast<double>(snapshot.writeFrame));
        ++callbacks;

        deadline = start + std::chrono::duration_cast<std::chrono::steady_clock::duration>(
                               std::chrono::duration<double>(
                                   static_cast<double>(callbacks * options.callbackFrames) /
                                   options.sampleRate));
        if (std::chrono::steady_clock::now() > deadline) {
            ++lateDeadlines;
        } else {
            std::this_thread::sleep_until(deadline);
        }
    }

    ring->ProducerStop();
    const auto snapshot = ring->Snapshot();
    std::printf(
        "{\"event\":\"producer_summary\",\"rate\":%u,"
        "\"callbacks_attempted\":%llu,\"late_deadlines\":%llu,"
        "\"producer_frames\":%llu,\"dropped_frames\":%llu,"
        "\"overruns\":%llu,\"high_water_frames\":%llu}\n",
        options.sampleRate, static_cast<unsigned long long>(callbacks),
        static_cast<unsigned long long>(lateDeadlines),
        static_cast<unsigned long long>(snapshot.producerFrames),
        static_cast<unsigned long long>(snapshot.droppedFrames),
        static_cast<unsigned long long>(snapshot.overrunCount),
        static_cast<unsigned long long>(snapshot.highWaterFrames));
    return snapshot.overrunCount == 0 ? 0 : 1;
}
