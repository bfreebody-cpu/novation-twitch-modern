// SPDX-License-Identifier: MIT
// Phase 2 USB-independent helper: consumes shared audio and discards it.

#include "SharedAudioRing.hpp"

#include <algorithm>
#include <chrono>
#include <cmath>
#include <csignal>
#include <cstdio>
#include <cstdlib>
#include <cstring>
#include <sys/resource.h>
#include <thread>
#include <vector>

namespace {

volatile std::sig_atomic_t gStop = 0;

void StopSignal(int)
{
    gStop = 1;
}

struct Options {
    std::string name {twitch::audio::kDefaultSharedMemoryName};
    double durationSeconds {0};
    unsigned reportMilliseconds {1000};
    bool cleanup {false};
    bool discardStale {true};
    bool verifyPattern {false};
};

void Usage(const char* executable)
{
    std::fprintf(stderr,
        "Usage: %s [--duration SECONDS] [--name /shm-name] "
        "[--report-ms N] [--keep-stale] [--verify-pattern] [--cleanup]\n",
        executable);
}

bool ParseDouble(const char* text, double& value)
{
    char* end = nullptr;
    value = std::strtod(text, &end);
    return end != text && *end == '\0' && value >= 0;
}

bool ParseUnsigned(const char* text, unsigned& value)
{
    char* end = nullptr;
    const auto parsed = std::strtoul(text, &end, 10);
    if (end == text || *end != '\0' || parsed == 0 || parsed > 60000) {
        return false;
    }
    value = static_cast<unsigned>(parsed);
    return true;
}

bool ParseOptions(int argc, char** argv, Options& options)
{
    for (int index = 1; index < argc; ++index) {
        if (std::strcmp(argv[index], "--duration") == 0 && index + 1 < argc) {
            if (!ParseDouble(argv[++index], options.durationSeconds)) {
                return false;
            }
        } else if (std::strcmp(argv[index], "--name") == 0 && index + 1 < argc) {
            options.name = argv[++index];
        } else if (std::strcmp(argv[index], "--report-ms") == 0 && index + 1 < argc) {
            if (!ParseUnsigned(argv[++index], options.reportMilliseconds)) {
                return false;
            }
        } else if (std::strcmp(argv[index], "--keep-stale") == 0) {
            options.discardStale = false;
        } else if (std::strcmp(argv[index], "--verify-pattern") == 0) {
            options.verifyPattern = true;
        } else if (std::strcmp(argv[index], "--cleanup") == 0) {
            options.cleanup = true;
        } else {
            return false;
        }
    }
    return true;
}

void PrintSnapshot(const char* event,
    const twitch::audio::RingSnapshot& snapshot, std::uint64_t now,
    std::uint64_t patternErrors, std::uint64_t nonFiniteSamples)
{
    const auto producerAge = snapshot.producerHeartbeatNs == 0 ||
            now < snapshot.producerHeartbeatNs
        ? 0
        : now - snapshot.producerHeartbeatNs;
    rusage usage {};
    getrusage(RUSAGE_SELF, &usage);
    const double userSeconds = usage.ru_utime.tv_sec +
        static_cast<double>(usage.ru_utime.tv_usec) / 1000000.0;
    const double systemSeconds = usage.ru_stime.tv_sec +
        static_cast<double>(usage.ru_stime.tv_usec) / 1000000.0;
    std::printf(
        "{\"event\":\"%s\",\"time_ns\":%llu,\"rate\":%u,"
        "\"fill_frames\":%llu,\"high_water_frames\":%llu,"
        "\"producer_callbacks\":%llu,\"producer_frames\":%llu,"
        "\"consumer_frames\":%llu,\"dropped_frames\":%llu,"
        "\"overruns\":%llu,\"underruns\":%llu,"
        "\"producer_active\":%u,\"consumer_active\":%u,"
        "\"producer_generation\":%u,\"consumer_generation\":%u,"
        "\"producer_age_ns\":%llu,\"last_producer_sample_time\":%.3f,"
        "\"stale_frames_discarded\":%llu,"
        "\"pattern_errors\":%llu,\"non_finite_samples\":%llu,"
        "\"cpu_user_s\":%.6f,\"cpu_system_s\":%.6f,"
        "\"max_rss_bytes\":%ld}\n",
        event,
        static_cast<unsigned long long>(now), snapshot.sampleRate,
        static_cast<unsigned long long>(snapshot.FillFrames()),
        static_cast<unsigned long long>(snapshot.highWaterFrames),
        static_cast<unsigned long long>(snapshot.producerCallbacks),
        static_cast<unsigned long long>(snapshot.producerFrames),
        static_cast<unsigned long long>(snapshot.consumerFrames),
        static_cast<unsigned long long>(snapshot.droppedFrames),
        static_cast<unsigned long long>(snapshot.overrunCount),
        static_cast<unsigned long long>(snapshot.underrunCount),
        snapshot.producerActive, snapshot.consumerActive,
        snapshot.producerGeneration, snapshot.consumerGeneration,
        static_cast<unsigned long long>(producerAge),
        snapshot.lastProducerSampleTime,
        static_cast<unsigned long long>(snapshot.staleFramesDiscarded),
        static_cast<unsigned long long>(patternErrors),
        static_cast<unsigned long long>(nonFiniteSamples), userSeconds,
        systemSeconds, usage.ru_maxrss);
    std::fflush(stdout);
}

} // namespace

int main(int argc, char** argv)
{
    Options options;
    if (!ParseOptions(argc, argv, options)) {
        Usage(argv[0]);
        return 2;
    }
    if (options.cleanup) {
        int error = 0;
        if (!twitch::audio::SharedAudioRing::Unlink(options.name, &error)) {
            std::fprintf(stderr, "cleanup failed: %s\n", std::strerror(error));
            return 1;
        }
        std::printf("cleaned shared memory %s\n", options.name.c_str());
        return 0;
    }

    std::signal(SIGINT, StopSignal);
    std::signal(SIGTERM, StopSignal);

    auto [ring, result] = twitch::audio::SharedAudioRing::Open(options.name);
    if (!result) {
        std::fprintf(stderr, "shared-memory open failed: %s (errno=%d)\n",
            result.message.c_str(), result.systemError);
        return 1;
    }
    std::printf("{\"event\":\"open\",\"shared_memory\":\"%s\","
                "\"disposition\":\"%s\",\"version\":%u,"
                "\"channels\":%u,\"capacity_frames\":%u}\n",
        options.name.c_str(),
        result.disposition == twitch::audio::OpenDisposition::Created ? "created"
                                                                     : "opened",
        twitch::audio::kSharedAudioVersion, twitch::audio::kChannelCount,
        twitch::audio::kRingCapacityFrames);

    if (!ring->ConsumerStart(options.discardStale)) {
        std::fputs("another live helper already owns the consumer role\n", stderr);
        return 1;
    }
    const auto started = std::chrono::steady_clock::now();
    auto nextReport = started;
    std::vector<float> buffer(4096 * twitch::audio::kChannelCount);
    std::uint64_t patternErrors = 0;
    std::uint64_t nonFiniteSamples = 0;

    while (gStop == 0) {
        const auto now = std::chrono::steady_clock::now();
        if (options.durationSeconds > 0 &&
            std::chrono::duration<double>(now - started).count() >=
                options.durationSeconds) {
            break;
        }

        const auto beforeRead = ring->Snapshot();
        const auto read = ring->TryRead(buffer.data(), 4096);
        for (std::uint32_t frame = 0; frame < read; ++frame) {
            for (std::uint32_t channel = 0;
                 channel < twitch::audio::kChannelCount; ++channel) {
                const auto sample = buffer[static_cast<std::size_t>(frame) *
                                               twitch::audio::kChannelCount +
                    channel];
                if (!std::isfinite(sample)) {
                    ++nonFiniteSamples;
                }
                if (options.verifyPattern && sample !=
                        twitch::audio::SyntheticPatternSample(
                            beforeRead.readFrame + frame, channel)) {
                    ++patternErrors;
                }
            }
        }
        if (read == 0) {
            std::this_thread::sleep_for(std::chrono::milliseconds(1));
        }
        if (now >= nextReport) {
            PrintSnapshot("status", ring->Snapshot(),
                twitch::audio::MonotonicTimeNs(), patternErrors,
                nonFiniteSamples);
            nextReport = now +
                std::chrono::milliseconds(options.reportMilliseconds);
        }
    }

    ring->ConsumerStop();
    PrintSnapshot("summary", ring->Snapshot(), twitch::audio::MonotonicTimeNs(),
        patternErrors, nonFiniteSamples);
    return patternErrors == 0 && nonFiniteSamples == 0 ? 0 : 1;
}
