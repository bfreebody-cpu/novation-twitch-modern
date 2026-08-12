// SPDX-License-Identifier: MIT

#include "SharedAudioRing.hpp"
#include "XPCClient.hpp"

#include <chrono>
#include <cstdio>
#include <cstdlib>
#include <thread>
#include <vector>

int main(int argc, char** argv)
{
    double durationSeconds = 2;
    std::uint32_t sampleRate = 48000;
    if (argc >= 2 && argc <= 3) {
        char* end = nullptr;
        durationSeconds = std::strtod(argv[1], &end);
        if (end == argv[1] || *end != '\0' || durationSeconds <= 0) {
            std::fputs("duration must be positive seconds\n", stderr);
            return 2;
        }
        if (argc == 3) {
            char* rateEnd = nullptr;
            const auto parsedRate = std::strtoul(argv[2], &rateEnd, 10);
            if (rateEnd == argv[2] || *rateEnd != '\0' ||
                (parsedRate != 44100 && parsedRate != 48000)) {
                std::fputs("rate must be 44100 or 48000 Hz\n", stderr);
                return 2;
            }
            sampleRate = static_cast<std::uint32_t>(parsedRate);
        }
    } else if (argc != 1) {
        std::fprintf(stderr,
            "Usage: %s [duration-seconds [sample-rate]]\n", argv[0]);
        return 2;
    }

    auto [ring, connection] = twitch::audio::ConnectToXPCService();
    if (!connection || !ring) {
        std::fprintf(stderr, "XPC connection failed: %s\n",
            connection.message.c_str());
        return 1;
    }
    ring->ProducerStart(sampleRate);
    constexpr std::uint32_t callbackFrames = 512;
    std::vector<float> frames(
        callbackFrames * twitch::audio::kChannelCount);
    const auto start = std::chrono::steady_clock::now();
    auto deadline = start;
    std::uint64_t callbacks = 0;
    while (std::chrono::duration<double>(
               std::chrono::steady_clock::now() - start)
               .count() < durationSeconds) {
        const auto snapshot = ring->Snapshot();
        for (std::uint32_t frame = 0; frame < callbackFrames; ++frame) {
            for (std::uint32_t channel = 0;
                 channel < twitch::audio::kChannelCount; ++channel) {
                frames[static_cast<std::size_t>(frame) *
                           twitch::audio::kChannelCount +
                    channel] = twitch::audio::SyntheticPatternSample(
                    snapshot.writeFrame + frame, channel);
            }
        }
        if (!ring->TryWrite(frames.data(), callbackFrames,
                static_cast<double>(snapshot.writeFrame))) {
            std::fputs("XPC producer overrun\n", stderr);
            ring->ProducerStop();
            return 1;
        }
        ++callbacks;
        deadline = start +
            std::chrono::duration_cast<std::chrono::steady_clock::duration>(
                std::chrono::duration<double>(
                    static_cast<double>(callbacks * callbackFrames) /
                        sampleRate));
        std::this_thread::sleep_until(deadline);
    }
    ring->ProducerStop();
    const auto snapshot = ring->Snapshot();
    std::printf("producer_frames=%llu consumer_frames=%llu fill=%llu "
                "drops=%llu overruns=%llu\n",
        static_cast<unsigned long long>(snapshot.producerFrames),
        static_cast<unsigned long long>(snapshot.consumerFrames),
        static_cast<unsigned long long>(snapshot.FillFrames()),
        static_cast<unsigned long long>(snapshot.droppedFrames),
        static_cast<unsigned long long>(snapshot.overrunCount));
    return snapshot.droppedFrames == 0 && snapshot.overrunCount == 0 ? 0 : 1;
}
