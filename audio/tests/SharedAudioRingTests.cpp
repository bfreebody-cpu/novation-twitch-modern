// SPDX-License-Identifier: MIT

#include "SharedAudioRing.hpp"

#include <xpc/xpc.h>

#include <cmath>
#include <atomic>
#include <cstdio>
#include <cstdlib>
#include <string>
#include <thread>
#include <unistd.h>
#include <vector>

namespace {

int gFailures = 0;

#define CHECK(condition)                                                       \
    do {                                                                       \
        if (!(condition)) {                                                    \
            std::fprintf(stderr, "FAIL %s:%d: %s\n", __FILE__, __LINE__,     \
                #condition);                                                   \
            ++gFailures;                                                       \
        }                                                                      \
    } while (false)

std::string TestName(const char* suffix)
{
    return "/ntm_" + std::to_string(getpid()) + "_" + suffix;
}

std::vector<float> Frames(std::uint32_t count, float base)
{
    std::vector<float> values(
        static_cast<std::size_t>(count) * twitch::audio::kChannelCount);
    for (std::size_t index = 0; index < values.size(); ++index) {
        values[index] = base + static_cast<float>(index) / 1000.0F;
    }
    return values;
}

void CheckEqual(const std::vector<float>& expected,
    const std::vector<float>& observed)
{
    CHECK(expected.size() == observed.size());
    for (std::size_t index = 0;
         index < std::min(expected.size(), observed.size()); ++index) {
        CHECK(std::fabs(expected[index] - observed[index]) < 0.000001F);
    }
}

void BasicAndLifecycle()
{
    const auto name = TestName("basic");
    twitch::audio::SharedAudioRing::Unlink(name);

    // Helper-before-plugin ordering.
    auto [consumer, consumerResult] = twitch::audio::SharedAudioRing::Open(name);
    CHECK(consumerResult);
    if (!consumer) {
        std::fprintf(stderr, "open error: %s errno=%d\n",
            consumerResult.message.c_str(), consumerResult.systemError);
        return;
    }
    CHECK(consumerResult.disposition == twitch::audio::OpenDisposition::Created);
    CHECK(consumer->ConsumerStart());

    auto [producer, producerResult] = twitch::audio::SharedAudioRing::Open(name);
    CHECK(producerResult);
    if (!producer) {
        return;
    }
    CHECK(producerResult.disposition == twitch::audio::OpenDisposition::Opened);
    producer->ProducerStart(44100);

    const auto input = Frames(1000, -0.5F);
    CHECK(producer->TryWrite(input.data(), 1000, 1234.0));
    std::vector<float> output(input.size());
    CHECK(consumer->TryRead(output.data(), 1000) == 1000);
    CheckEqual(input, output);

    producer->ProducerStop();
    consumer->ConsumerStop();
    auto snapshot = producer->Snapshot();
    CHECK(snapshot.sampleRate == 44100);
    CHECK(snapshot.producerStarts == 1);
    CHECK(snapshot.producerStops == 1);
    CHECK(snapshot.consumerStarts == 1);
    CHECK(snapshot.consumerStops == 1);
    CHECK(snapshot.producerFrames == 1000);
    CHECK(snapshot.consumerFrames == 1000);
    CHECK(snapshot.FillFrames() == 0);

    // A restarted helper discards queued audio rather than playing it late.
    CHECK(producer->TryWrite(input.data(), 1000, 2234.0));
    consumer.reset();
    auto [restarted, restartResult] = twitch::audio::SharedAudioRing::Open(name);
    CHECK(restartResult);
    CHECK(restarted->ConsumerStart(true));
    snapshot = restarted->Snapshot();
    CHECK(snapshot.consumerGeneration == 2);
    CHECK(snapshot.staleFramesDiscarded == 1000);
    CHECK(snapshot.FillFrames() == 0);
    restarted->ConsumerStop();

    producer.reset();
    restarted.reset();
    CHECK(twitch::audio::SharedAudioRing::Unlink(name));
}

void WrapAndOverrun()
{
    const auto name = TestName("wrap");
    twitch::audio::SharedAudioRing::Unlink(name);
    auto [producer, result] = twitch::audio::SharedAudioRing::Open(name);
    CHECK(result);
    if (!producer) {
        return;
    }
    auto [consumer, secondResult] = twitch::audio::SharedAudioRing::Open(name);
    CHECK(secondResult);
    if (!consumer) {
        return;
    }
    CHECK(consumer->ConsumerStart(false));

    const std::uint32_t firstCount = twitch::audio::kRingCapacityFrames - 100;
    const auto first = Frames(firstCount, -1.0F);
    CHECK(producer->TryWrite(first.data(), firstCount, 0));
    std::vector<float> firstOutput(first.size());
    CHECK(consumer->TryRead(firstOutput.data(), firstCount) == firstCount);
    CheckEqual(first, firstOutput);

    const auto wrapped = Frames(512, 2.0F);
    CHECK(producer->TryWrite(wrapped.data(), 512, 1));
    std::vector<float> wrappedOutput(wrapped.size());
    CHECK(consumer->TryRead(wrappedOutput.data(), 512) == 512);
    CheckEqual(wrapped, wrappedOutput);

    const auto full = Frames(twitch::audio::kRingCapacityFrames, 3.0F);
    CHECK(producer->TryWrite(
        full.data(), twitch::audio::kRingCapacityFrames, 2));
    CHECK(!producer->TryWrite(wrapped.data(), 512, 3));
    const auto snapshot = producer->Snapshot();
    CHECK(snapshot.overrunCount == 1);
    CHECK(snapshot.droppedFrames == 512);
    CHECK(snapshot.highWaterFrames == twitch::audio::kRingCapacityFrames);

    consumer->ConsumerStop();
    producer.reset();
    consumer.reset();
    CHECK(twitch::audio::SharedAudioRing::Unlink(name));
}

void VersionMismatch()
{
    const auto name = TestName("version");
    twitch::audio::SharedAudioRing::Unlink(name);
    auto [ring, result] = twitch::audio::SharedAudioRing::Open(name);
    CHECK(result);
    if (!ring) {
        return;
    }
    auto [wrong, wrongResult] = twitch::audio::SharedAudioRing::Open(
        name, twitch::audio::kSharedAudioVersion + 1);
    CHECK(!wrong);
    CHECK(wrongResult.error == twitch::audio::OpenError::ProtocolMismatch);
    ring.reset();
    CHECK(twitch::audio::SharedAudioRing::Unlink(name));

    auto [invalid, invalidResult] = twitch::audio::SharedAudioRing::Open(
        "/this_name_is_longer_than_thirty_one_bytes");
    CHECK(!invalid);
    CHECK(invalidResult.error == twitch::audio::OpenError::InvalidName);
}

void AnonymousXPCMapping()
{
    auto [owner, allocation] =
        twitch::audio::SharedAudioRing::AllocateAnonymous();
    CHECK(allocation);
    CHECK(owner);
    if (!owner) {
        return;
    }
    xpc_object_t shared =
        xpc_shmem_create(owner->Memory(), owner->MappedByteCount());
    CHECK(shared != nullptr);
    if (shared == nullptr) {
        return;
    }
    void* address = nullptr;
    const auto mappedBytes = xpc_shmem_map(shared, &address);
    CHECK(address != nullptr);
    CHECK(mappedBytes == owner->MappedByteCount());
    if (address == nullptr || mappedBytes == 0) {
        xpc_release(shared);
        return;
    }
    auto [peer, attach] =
        twitch::audio::SharedAudioRing::Attach(address, mappedBytes);
    CHECK(attach);
    CHECK(peer);
    if (peer) {
        CHECK(peer->ConsumerStart());
        owner->ProducerStart(48000);
        const auto input = Frames(257, 0.125F);
        CHECK(owner->TryWrite(input.data(), 257, 88.0));
        std::vector<float> output(input.size());
        CHECK(peer->TryRead(output.data(), 257) == 257);
        CheckEqual(input, output);
        owner->ProducerStop();
        peer->ConsumerStop();
    }
    peer.reset();
    xpc_release(shared);
}

void PluginBeforeHelper()
{
    const auto name = TestName("producer_first");
    twitch::audio::SharedAudioRing::Unlink(name);
    auto [producer, first] = twitch::audio::SharedAudioRing::Open(name);
    CHECK(first);
    if (!producer) {
        return;
    }
    CHECK(first.disposition == twitch::audio::OpenDisposition::Created);
    producer->ProducerStart(48000);
    const auto input = Frames(64, 0.25F);
    CHECK(producer->TryWrite(input.data(), 64, 99));

    auto [consumer, second] = twitch::audio::SharedAudioRing::Open(name);
    CHECK(second);
    if (!consumer) {
        return;
    }
    CHECK(consumer->ConsumerStart(true));
    CHECK(consumer->Snapshot().staleFramesDiscarded == 64);
    producer->ProducerStop();
    consumer->ConsumerStop();
    producer.reset();
    consumer.reset();
    CHECK(twitch::audio::SharedAudioRing::Unlink(name));
}

void ConsumerOwnershipAndStaleTakeover()
{
    const auto name = TestName("ownership");
    twitch::audio::SharedAudioRing::Unlink(name);
    auto [producer, producerResult] = twitch::audio::SharedAudioRing::Open(name);
    auto [first, firstResult] = twitch::audio::SharedAudioRing::Open(name);
    auto [second, secondResult] = twitch::audio::SharedAudioRing::Open(name);
    CHECK(producerResult && firstResult && secondResult);
    if (!producer || !first || !second) {
        return;
    }

    CHECK(first->ConsumerStart(false));
    CHECK(!second->ConsumerStart(false));
    CHECK(second->ConsumerStart(false, 0));

    const auto input = Frames(32, 0.75F);
    CHECK(producer->TryWrite(input.data(), 32, 10));
    std::vector<float> output(input.size());
    CHECK(first->TryRead(output.data(), 32) == 0);
    CHECK(second->TryRead(output.data(), 32) == 32);
    CheckEqual(input, output);

    first->ConsumerStop();
    CHECK(second->Snapshot().consumerActive == 1);
    second->ConsumerStop();
    CHECK(second->Snapshot().consumerActive == 0);
    producer.reset();
    first.reset();
    second.reset();
    CHECK(twitch::audio::SharedAudioRing::Unlink(name));
}

void ConcurrentIntegrity()
{
    const auto name = TestName("concurrent");
    twitch::audio::SharedAudioRing::Unlink(name);
    auto [producer, producerResult] = twitch::audio::SharedAudioRing::Open(name);
    auto [consumer, consumerResult] = twitch::audio::SharedAudioRing::Open(name);
    CHECK(producerResult && consumerResult);
    if (!producer || !consumer) {
        return;
    }
    CHECK(consumer->ConsumerStart(false));
    producer->ProducerStart(48000);

    constexpr std::uint32_t callbackFrames = 64;
    constexpr std::uint32_t callbackCount = 10000;
    constexpr std::uint64_t totalFrames =
        static_cast<std::uint64_t>(callbackFrames) * callbackCount;
    std::atomic<std::uint64_t> errors {0};
    std::atomic<bool> producerDone {false};
    auto* producerRing = producer.get();
    auto* consumerRing = consumer.get();

    std::thread writer([&] {
        std::vector<float> frames(callbackFrames * twitch::audio::kChannelCount);
        for (std::uint32_t callback = 0; callback < callbackCount; ++callback) {
            const auto base = static_cast<std::uint64_t>(callback) * callbackFrames;
            for (std::uint32_t frame = 0; frame < callbackFrames; ++frame) {
                for (std::uint32_t channel = 0;
                     channel < twitch::audio::kChannelCount; ++channel) {
                    frames[static_cast<std::size_t>(frame) *
                               twitch::audio::kChannelCount +
                        channel] = twitch::audio::SyntheticPatternSample(
                        base + frame, channel);
                }
            }
            while (!producerRing->TryWrite(frames.data(), callbackFrames,
                static_cast<double>(base))) {
                std::this_thread::yield();
            }
        }
        producerDone.store(true, std::memory_order_release);
    });

    std::thread reader([&] {
        std::vector<float> frames(256 * twitch::audio::kChannelCount);
        std::uint64_t sequence = 0;
        while (sequence < totalFrames ||
            !producerDone.load(std::memory_order_acquire)) {
            const auto count = consumerRing->TryRead(frames.data(), 256);
            if (count == 0) {
                std::this_thread::yield();
                continue;
            }
            for (std::uint32_t frame = 0; frame < count; ++frame) {
                for (std::uint32_t channel = 0;
                     channel < twitch::audio::kChannelCount; ++channel) {
                    const auto observed = frames[static_cast<std::size_t>(frame) *
                                                     twitch::audio::kChannelCount +
                        channel];
                    if (observed != twitch::audio::SyntheticPatternSample(
                            sequence + frame, channel)) {
                        errors.fetch_add(1, std::memory_order_relaxed);
                    }
                }
            }
            sequence += count;
        }
        if (sequence != totalFrames) {
            errors.fetch_add(1, std::memory_order_relaxed);
        }
    });

    writer.join();
    reader.join();
    producer->ProducerStop();
    consumer->ConsumerStop();
    const auto snapshot = producer->Snapshot();
    CHECK(errors.load(std::memory_order_relaxed) == 0);
    CHECK(snapshot.producerFrames == totalFrames);
    CHECK(snapshot.consumerFrames == totalFrames);
    CHECK(snapshot.FillFrames() == 0);
    // A scheduling-induced full-ring attempt is recorded even when the test
    // producer retries. Data integrity and eventual delivery remain required.
    CHECK(snapshot.droppedFrames % callbackFrames == 0);

    producer.reset();
    consumer.reset();
    CHECK(twitch::audio::SharedAudioRing::Unlink(name));
}

} // namespace

int main()
{
    BasicAndLifecycle();
    WrapAndOverrun();
    VersionMismatch();
    AnonymousXPCMapping();
    PluginBeforeHelper();
    ConsumerOwnershipAndStaleTakeover();
    ConcurrentIntegrity();
    if (gFailures != 0) {
        std::fprintf(stderr, "SharedAudioRingTests: %d failure(s)\n", gFailures);
        return 1;
    }
    std::puts("PASS: shared ring data, wrap, concurrency, ownership, restart, "
              "and mismatch");
    return 0;
}
