// SPDX-License-Identifier: MIT
// USB-independent shared-memory transport for experimental Twitch audio.

#pragma once

#include <atomic>
#include <cstddef>
#include <cstdint>
#include <memory>
#include <string>

namespace twitch::audio {

constexpr const char* kDefaultSharedMemoryName = "/ntm_audio_v1";
constexpr std::uint64_t kSharedAudioMagic = 0x5457495443484131ULL; // TWITCHA1
constexpr std::uint32_t kSharedAudioVersion = 1;
constexpr std::uint32_t kChannelCount = 4;
constexpr std::uint32_t kRingCapacityFrames = 65536;

enum class OpenDisposition {
    Opened,
    Created,
};

enum class OpenError {
    None,
    System,
    SizeMismatch,
    ProtocolMismatch,
    InvalidName,
};

struct OpenResult {
    OpenDisposition disposition {OpenDisposition::Opened};
    OpenError error {OpenError::None};
    int systemError {0};
    std::string message;

    explicit operator bool() const { return error == OpenError::None; }
};

struct alignas(64) SharedAudioHeader {
    std::uint64_t magic {0};
    std::uint32_t version {kSharedAudioVersion};
    std::uint32_t headerBytes {0};
    std::uint32_t totalBytes {0};
    std::uint32_t channelCount {kChannelCount};
    std::uint32_t capacityFrames {kRingCapacityFrames};
    std::uint32_t reserved0 {0};

    alignas(64) std::atomic<std::uint64_t> writeFrame {0};
    std::atomic<std::uint64_t> readFrame {0};
    std::atomic<std::uint64_t> producerCallbacks {0};
    std::atomic<std::uint64_t> producerFrames {0};
    std::atomic<std::uint64_t> consumerFrames {0};
    std::atomic<std::uint64_t> droppedFrames {0};
    std::atomic<std::uint64_t> overrunCount {0};
    std::atomic<std::uint64_t> underrunCount {0};
    std::atomic<std::uint64_t> highWaterFrames {0};

    alignas(64) std::atomic<std::uint64_t> producerStarts {0};
    std::atomic<std::uint64_t> producerStops {0};
    std::atomic<std::uint64_t> consumerStarts {0};
    std::atomic<std::uint64_t> consumerStops {0};
    std::atomic<std::uint64_t> producerHeartbeatNs {0};
    std::atomic<std::uint64_t> consumerHeartbeatNs {0};
    std::atomic<std::uint64_t> lastProducerSampleTimeBits {0};
    std::atomic<std::uint32_t> sampleRate {48000};
    std::atomic<std::uint32_t> producerActive {0};
    std::atomic<std::uint32_t> consumerActive {0};
    std::atomic<std::uint32_t> producerGeneration {0};
    std::atomic<std::uint32_t> consumerGeneration {0};
    std::atomic<std::uint64_t> staleFramesDiscarded {0};
};

struct SharedAudioMemory {
    SharedAudioHeader header;
    alignas(64) float samples[kRingCapacityFrames * kChannelCount] {};
};

static_assert(std::atomic<std::uint64_t>::is_always_lock_free,
    "Shared ring requires lock-free 64-bit atomics");
static_assert(std::atomic<std::uint32_t>::is_always_lock_free,
    "Shared ring requires lock-free 32-bit atomics");

struct RingSnapshot {
    std::uint64_t writeFrame {0};
    std::uint64_t readFrame {0};
    std::uint64_t producerCallbacks {0};
    std::uint64_t producerFrames {0};
    std::uint64_t consumerFrames {0};
    std::uint64_t droppedFrames {0};
    std::uint64_t overrunCount {0};
    std::uint64_t underrunCount {0};
    std::uint64_t highWaterFrames {0};
    std::uint64_t producerStarts {0};
    std::uint64_t producerStops {0};
    std::uint64_t consumerStarts {0};
    std::uint64_t consumerStops {0};
    std::uint64_t producerHeartbeatNs {0};
    std::uint64_t consumerHeartbeatNs {0};
    double lastProducerSampleTime {0};
    std::uint32_t sampleRate {0};
    std::uint32_t producerActive {0};
    std::uint32_t consumerActive {0};
    std::uint32_t producerGeneration {0};
    std::uint32_t consumerGeneration {0};
    std::uint64_t staleFramesDiscarded {0};

    std::uint64_t FillFrames() const;
};

class SharedAudioRing {
public:
    ~SharedAudioRing();
    SharedAudioRing(SharedAudioRing&&) noexcept;
    SharedAudioRing& operator=(SharedAudioRing&&) noexcept;

    SharedAudioRing(const SharedAudioRing&) = delete;
    SharedAudioRing& operator=(const SharedAudioRing&) = delete;

    static std::pair<std::unique_ptr<SharedAudioRing>, OpenResult> Open(
        const std::string& name = kDefaultSharedMemoryName,
        std::uint32_t expectedVersion = kSharedAudioVersion);
    static bool Unlink(const std::string& name = kDefaultSharedMemoryName,
        int* systemError = nullptr);

    // Real-time safe after Open(): lock-free atomics plus bounded memcpy only.
    bool TryWrite(const float* interleavedFrames, std::uint32_t frameCount,
        double sampleTime) noexcept;
    std::uint32_t TryRead(float* interleavedFrames,
        std::uint32_t requestedFrames) noexcept;

    void ProducerStart(std::uint32_t sampleRate) noexcept;
    void ProducerStop() noexcept;
    bool ConsumerStart(bool discardStaleFrames = true,
        std::uint64_t staleAfterNs = 1000000000ULL) noexcept;
    void ConsumerStop() noexcept;
    void SetSampleRate(std::uint32_t sampleRate) noexcept;
    void RecordUnderrun() noexcept;

    RingSnapshot Snapshot() const noexcept;
    const std::string& Name() const noexcept { return name_; }

private:
    SharedAudioRing(std::string name, int descriptor, SharedAudioMemory* memory);
    void Close() noexcept;

    std::string name_;
    int descriptor_ {-1};
    SharedAudioMemory* memory_ {nullptr};
    std::uint32_t consumerGeneration_ {0};
};

std::uint64_t MonotonicTimeNs() noexcept;

inline float SyntheticPatternSample(
    std::uint64_t frameSequence, std::uint32_t channel) noexcept
{
    const auto value = ((frameSequence & 0x3fffULL) * kChannelCount + channel);
    return static_cast<float>(value) / 65536.0F - 0.5F;
}

} // namespace twitch::audio
