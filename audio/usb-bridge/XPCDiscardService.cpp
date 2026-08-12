// SPDX-License-Identifier: MIT
// USB-independent launchd XPC service; consumes and discards shared audio.

#include "SharedAudioRing.hpp"
#include "XPCBridge.hpp"

#include <xpc/xpc.h>

#include <algorithm>
#include <atomic>
#include <chrono>
#include <cmath>
#include <csignal>
#include <cstdio>
#include <cstdlib>
#include <cstring>
#include <pwd.h>
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
    double durationSeconds {0};
    unsigned reportMilliseconds {1000};
    unsigned idleExitMilliseconds {1000};
    uid_t allowedUID {static_cast<uid_t>(-1)};
    bool verifyPattern {false};
};

bool ParseUnsigned(const char* text, unsigned long& value)
{
    char* end = nullptr;
    value = std::strtoul(text, &end, 10);
    return end != text && *end == '\0';
}

bool ParseOptions(int argc, char** argv, Options& options)
{
    if (const passwd* account = getpwnam("_coreaudiod")) {
        options.allowedUID = account->pw_uid;
    }
    for (int index = 1; index < argc; ++index) {
        if (std::strcmp(argv[index], "--duration") == 0 && index + 1 < argc) {
            char* end = nullptr;
            options.durationSeconds = std::strtod(argv[++index], &end);
            if (end == argv[index] || *end != '\0' || options.durationSeconds < 0) {
                return false;
            }
        } else if (std::strcmp(argv[index], "--report-ms") == 0 &&
            index + 1 < argc) {
            unsigned long value = 0;
            if (!ParseUnsigned(argv[++index], value) || value == 0 || value > 60000) {
                return false;
            }
            options.reportMilliseconds = static_cast<unsigned>(value);
        } else if (std::strcmp(argv[index], "--allow-euid") == 0 &&
            index + 1 < argc) {
            unsigned long value = 0;
            if (!ParseUnsigned(argv[++index], value) || value > UINT32_MAX) {
                return false;
            }
            options.allowedUID = static_cast<uid_t>(value);
        } else if (std::strcmp(argv[index], "--idle-exit-ms") == 0 &&
            index + 1 < argc) {
            unsigned long value = 0;
            if (!ParseUnsigned(argv[++index], value) || value == 0 ||
                value > 60000) {
                return false;
            }
            options.idleExitMilliseconds = static_cast<unsigned>(value);
        } else if (std::strcmp(argv[index], "--verify-pattern") == 0) {
            options.verifyPattern = true;
        } else {
            return false;
        }
    }
    return options.allowedUID != static_cast<uid_t>(-1);
}

void PrintSnapshot(const twitch::audio::RingSnapshot& snapshot,
    std::uint64_t patternErrors, std::uint64_t nonFiniteSamples,
    std::uint64_t acceptedPeers, std::uint64_t rejectedPeers,
    const char* event)
{
    rusage usage {};
    getrusage(RUSAGE_SELF, &usage);
    std::printf(
        "{\"event\":\"%s\",\"rate\":%u,\"fill_frames\":%llu,"
        "\"high_water_frames\":%llu,\"producer_callbacks\":%llu,"
        "\"producer_frames\":%llu,\"consumer_frames\":%llu,"
        "\"dropped_frames\":%llu,\"overruns\":%llu,"
        "\"consumer_generation\":%u,\"pattern_errors\":%llu,"
        "\"non_finite_samples\":%llu,\"accepted_peers\":%llu,"
        "\"rejected_peers\":%llu,\"cpu_user_s\":%.6f,"
        "\"cpu_system_s\":%.6f,\"max_rss_bytes\":%ld}\n",
        event, snapshot.sampleRate,
        static_cast<unsigned long long>(snapshot.FillFrames()),
        static_cast<unsigned long long>(snapshot.highWaterFrames),
        static_cast<unsigned long long>(snapshot.producerCallbacks),
        static_cast<unsigned long long>(snapshot.producerFrames),
        static_cast<unsigned long long>(snapshot.consumerFrames),
        static_cast<unsigned long long>(snapshot.droppedFrames),
        static_cast<unsigned long long>(snapshot.overrunCount),
        snapshot.consumerGeneration,
        static_cast<unsigned long long>(patternErrors),
        static_cast<unsigned long long>(nonFiniteSamples),
        static_cast<unsigned long long>(acceptedPeers),
        static_cast<unsigned long long>(rejectedPeers),
        usage.ru_utime.tv_sec + usage.ru_utime.tv_usec / 1000000.0,
        usage.ru_stime.tv_sec + usage.ru_stime.tv_usec / 1000000.0,
        usage.ru_maxrss);
    std::fflush(stdout);
}

} // namespace

int main(int argc, char** argv)
{
    Options options;
    if (!ParseOptions(argc, argv, options)) {
        std::fprintf(stderr,
            "Usage: %s [--duration SECONDS] [--report-ms N] "
            "[--idle-exit-ms N] [--allow-euid UID] [--verify-pattern]\n",
            argv[0]);
        return 2;
    }
    std::signal(SIGINT, StopSignal);
    std::signal(SIGTERM, StopSignal);

    auto [ring, allocation] = twitch::audio::SharedAudioRing::AllocateAnonymous();
    if (!allocation || !ring || !ring->ConsumerStart(true)) {
        std::fprintf(stderr, "could not allocate or claim anonymous audio ring: %s\n",
            allocation.message.c_str());
        return 1;
    }
    xpc_object_t shared =
        xpc_shmem_create(ring->Memory(), ring->MappedByteCount());
    if (shared == nullptr) {
        std::fputs("xpc_shmem_create failed\n", stderr);
        return 1;
    }

    std::atomic<std::uint64_t> acceptedPeers {0};
    std::atomic<std::uint64_t> rejectedPeers {0};
    auto* acceptedPeersPtr = &acceptedPeers;
    auto* rejectedPeersPtr = &rejectedPeers;
    xpc_connection_t listener = xpc_connection_create_mach_service(
        twitch::audio::kXPCServiceName, nullptr,
        XPC_CONNECTION_MACH_SERVICE_LISTENER);
    if (listener == nullptr) {
        std::fputs("could not create XPC Mach service listener\n", stderr);
        xpc_release(shared);
        return 1;
    }
    xpc_connection_set_event_handler(listener, ^(xpc_object_t event) {
        if (xpc_get_type(event) != XPC_TYPE_CONNECTION) {
            return;
        }
        xpc_connection_t peer = static_cast<xpc_connection_t>(event);
        if (xpc_connection_get_euid(peer) != options.allowedUID) {
            rejectedPeersPtr->fetch_add(1, std::memory_order_relaxed);
            xpc_connection_cancel(peer);
            return;
        }
        acceptedPeersPtr->fetch_add(1, std::memory_order_relaxed);
        xpc_connection_set_event_handler(peer, ^(xpc_object_t message) {
            if (xpc_get_type(message) != XPC_TYPE_DICTIONARY) {
                return;
            }
            xpc_object_t reply = xpc_dictionary_create_reply(message);
            if (reply == nullptr) {
                return;
            }
            const char* operation = xpc_dictionary_get_string(
                message, twitch::audio::kXPCOperationKey);
            if (operation == nullptr || std::strcmp(operation,
                    twitch::audio::kXPCAcquireOperation) != 0) {
                xpc_dictionary_set_string(reply,
                    twitch::audio::kXPCErrorKey, "unsupported operation");
            } else {
                xpc_dictionary_set_uint64(reply,
                    twitch::audio::kXPCProtocolVersionKey,
                    twitch::audio::kSharedAudioVersion);
                xpc_dictionary_set_value(reply,
                    twitch::audio::kXPCSharedMemoryKey, shared);
            }
            xpc_connection_send_message(peer, reply);
            xpc_release(reply);
        });
        xpc_connection_activate(peer);
    });
    xpc_connection_activate(listener);

    std::printf("{\"event\":\"ready\",\"service\":\"%s\","
                "\"allowed_euid\":%u,\"version\":%u}\n",
        twitch::audio::kXPCServiceName, options.allowedUID,
        twitch::audio::kSharedAudioVersion);
    std::fflush(stdout);

    const auto started = std::chrono::steady_clock::now();
    auto nextReport = started;
    std::vector<float> frames(4096 * twitch::audio::kChannelCount);
    std::uint64_t patternErrors = 0;
    std::uint64_t nonFiniteSamples = 0;
    bool observedActiveProducer = false;
    auto inactiveSince = started;
    while (gStop == 0) {
        const auto now = std::chrono::steady_clock::now();
        if (options.durationSeconds > 0 &&
            std::chrono::duration<double>(now - started).count() >=
                options.durationSeconds) {
            break;
        }
        const auto before = ring->Snapshot();
        if (before.producerActive != 0) {
            observedActiveProducer = true;
        } else if (observedActiveProducer && before.FillFrames() == 0) {
            if (std::chrono::duration_cast<std::chrono::milliseconds>(
                    now - inactiveSince)
                    .count() >= options.idleExitMilliseconds) {
                break;
            }
        } else {
            inactiveSince = now;
        }
        const auto count = ring->TryRead(frames.data(), 4096);
        for (std::uint32_t frame = 0; frame < count; ++frame) {
            for (std::uint32_t channel = 0;
                 channel < twitch::audio::kChannelCount; ++channel) {
                const float value = frames[static_cast<std::size_t>(frame) *
                                                 twitch::audio::kChannelCount +
                    channel];
                if (!std::isfinite(value)) {
                    ++nonFiniteSamples;
                }
                if (options.verifyPattern && value !=
                        twitch::audio::SyntheticPatternSample(
                            before.readFrame + frame, channel)) {
                    ++patternErrors;
                }
            }
        }
        if (count == 0) {
            std::this_thread::sleep_for(std::chrono::milliseconds(1));
        }
        if (before.producerActive != 0 || count != 0) {
            inactiveSince = now;
        }
        if (now >= nextReport) {
            PrintSnapshot(ring->Snapshot(), patternErrors, nonFiniteSamples,
                acceptedPeers.load(), rejectedPeers.load(), "status");
            nextReport = now +
                std::chrono::milliseconds(options.reportMilliseconds);
        }
    }

    ring->ConsumerStop();
    PrintSnapshot(ring->Snapshot(), patternErrors, nonFiniteSamples,
        acceptedPeers.load(), rejectedPeers.load(), "summary");
    xpc_connection_cancel(listener);
    xpc_release(listener);
    xpc_release(shared);
    return patternErrors == 0 && nonFiniteSamples == 0 ? 0 : 1;
}
