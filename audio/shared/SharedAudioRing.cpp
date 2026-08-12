// SPDX-License-Identifier: MIT

#include "SharedAudioRing.hpp"

#include <algorithm>
#include <cerrno>
#include <cstring>
#include <fcntl.h>
#include <new>
#include <sys/mman.h>
#include <sys/stat.h>
#include <time.h>
#include <unistd.h>

namespace twitch::audio {
namespace {

constexpr std::size_t kMemoryBytes = sizeof(SharedAudioMemory);
constexpr std::size_t kMacOSMaxNameSegmentLength = 31;

std::size_t MappedBytes()
{
    const auto page = static_cast<std::size_t>(getpagesize());
    return ((kMemoryBytes + page - 1) / page) * page;
}

bool ValidName(const std::string& name)
{
    return name.size() > 1 && name.size() - 1 <= kMacOSMaxNameSegmentLength &&
        name.front() == '/' &&
        name.find('/', 1) == std::string::npos;
}

std::uint64_t DoubleBits(double value) noexcept
{
    std::uint64_t bits = 0;
    static_assert(sizeof(bits) == sizeof(value));
    std::memcpy(&bits, &value, sizeof(bits));
    return bits;
}

double BitsDouble(std::uint64_t bits) noexcept
{
    double value = 0;
    static_assert(sizeof(bits) == sizeof(value));
    std::memcpy(&value, &bits, sizeof(value));
    return value;
}

void UpdateHighWater(std::atomic<std::uint64_t>& highWater,
    std::uint64_t candidate) noexcept
{
    auto observed = highWater.load(std::memory_order_relaxed);
    while (observed < candidate && !highWater.compare_exchange_weak(observed,
               candidate, std::memory_order_relaxed, std::memory_order_relaxed)) {
    }
}

} // namespace

std::uint64_t MonotonicTimeNs() noexcept
{
    timespec value {};
    if (clock_gettime(CLOCK_MONOTONIC_RAW, &value) != 0) {
        return 0;
    }
    return static_cast<std::uint64_t>(value.tv_sec) * 1000000000ULL +
        static_cast<std::uint64_t>(value.tv_nsec);
}

std::uint64_t RingSnapshot::FillFrames() const
{
    return writeFrame >= readFrame ? writeFrame - readFrame : 0;
}

SharedAudioRing::SharedAudioRing(
    std::string name, int descriptor, SharedAudioMemory* memory,
    std::size_t mappedBytes)
    : name_(std::move(name))
    , descriptor_(descriptor)
    , memory_(memory)
    , mappedBytes_(mappedBytes)
{
}

SharedAudioRing::~SharedAudioRing()
{
    Close();
}

SharedAudioRing::SharedAudioRing(SharedAudioRing&& other) noexcept
    : name_(std::move(other.name_))
    , descriptor_(other.descriptor_)
    , memory_(other.memory_)
    , mappedBytes_(other.mappedBytes_)
    , consumerGeneration_(other.consumerGeneration_)
{
    other.descriptor_ = -1;
    other.memory_ = nullptr;
    other.mappedBytes_ = 0;
    other.consumerGeneration_ = 0;
}

SharedAudioRing& SharedAudioRing::operator=(SharedAudioRing&& other) noexcept
{
    if (this != &other) {
        Close();
        name_ = std::move(other.name_);
        descriptor_ = other.descriptor_;
        memory_ = other.memory_;
        mappedBytes_ = other.mappedBytes_;
        consumerGeneration_ = other.consumerGeneration_;
        other.descriptor_ = -1;
        other.memory_ = nullptr;
        other.mappedBytes_ = 0;
        other.consumerGeneration_ = 0;
    }
    return *this;
}

std::pair<std::unique_ptr<SharedAudioRing>, OpenResult> SharedAudioRing::Open(
    const std::string& name, std::uint32_t expectedVersion)
{
    OpenResult result;
    if (!ValidName(name)) {
        result.error = OpenError::InvalidName;
        result.message =
            "POSIX shared-memory name must have one leading slash and a "
            "maximum 31-byte name segment on macOS";
        return {nullptr, result};
    }

    bool created = false;
    int descriptor = shm_open(name.c_str(), O_RDWR | O_CREAT | O_EXCL, 0600);
    if (descriptor >= 0) {
        created = true;
        result.disposition = OpenDisposition::Created;
    } else if (errno == EEXIST) {
        descriptor = shm_open(name.c_str(), O_RDWR, 0600);
    }
    if (descriptor < 0) {
        result.error = OpenError::System;
        result.systemError = errno;
        result.message = std::strerror(errno);
        return {nullptr, result};
    }

    auto fail = [&](OpenError error, const char* message) {
        result.error = error;
        result.message = message;
        close(descriptor);
        if (created) {
            shm_unlink(name.c_str());
        }
        return std::pair<std::unique_ptr<SharedAudioRing>, OpenResult> {
            nullptr, result};
    };

    const auto mappedBytes = MappedBytes();
    if (created && ftruncate(descriptor, static_cast<off_t>(mappedBytes)) != 0) {
        result.systemError = errno;
        return fail(OpenError::System, std::strerror(errno));
    }

    struct stat status {};
    // shm_open(O_EXCL) makes initialization single-writer. An opener that lost
    // the creation race may observe the object before ftruncate completes, so
    // wait briefly here. Open() is never called from the HAL real-time path.
    for (unsigned attempt = 0; attempt < 500; ++attempt) {
        if (fstat(descriptor, &status) != 0) {
            result.systemError = errno;
            return fail(OpenError::System, std::strerror(errno));
        }
        if (created || status.st_size != 0) {
            break;
        }
        usleep(1000);
    }
    if (status.st_size != static_cast<off_t>(mappedBytes)) {
        const auto message = "shared-memory size mismatch: expected " +
            std::to_string(mappedBytes) + " bytes, found " +
            std::to_string(status.st_size);
        return fail(OpenError::SizeMismatch, message.c_str());
    }

    void* address = mmap(nullptr, mappedBytes, PROT_READ | PROT_WRITE,
        MAP_SHARED, descriptor, 0);
    if (address == MAP_FAILED) {
        result.systemError = errno;
        return fail(OpenError::System, std::strerror(errno));
    }
    auto* memory = static_cast<SharedAudioMemory*>(address);

    if (created) {
        new (memory) SharedAudioMemory {};
        memory->header.headerBytes = sizeof(SharedAudioHeader);
        memory->header.totalBytes = static_cast<std::uint32_t>(kMemoryBytes);
        __atomic_store_n(&memory->header.magic, kSharedAudioMagic, __ATOMIC_RELEASE);
    } else {
        std::uint64_t magic = 0;
        for (unsigned attempt = 0; attempt < 500; ++attempt) {
            magic = __atomic_load_n(&memory->header.magic, __ATOMIC_ACQUIRE);
            if (magic != 0) {
                break;
            }
            usleep(1000);
        }
        if (magic != kSharedAudioMagic ||
            memory->header.version != expectedVersion ||
            memory->header.headerBytes != sizeof(SharedAudioHeader) ||
            memory->header.totalBytes != kMemoryBytes ||
            memory->header.channelCount != kChannelCount ||
            memory->header.capacityFrames != kRingCapacityFrames) {
            munmap(memory, mappedBytes);
            return fail(OpenError::ProtocolMismatch,
                "shared-memory protocol mismatch; refusing to reinterpret it");
        }
    }

    return {std::unique_ptr<SharedAudioRing>(
                new SharedAudioRing(name, descriptor, memory, mappedBytes)),
        result};
}

std::pair<std::unique_ptr<SharedAudioRing>, OpenResult>
SharedAudioRing::AllocateAnonymous()
{
    OpenResult result;
    result.disposition = OpenDisposition::Created;
    const auto mappedBytes = MappedBytes();
    void* address = mmap(nullptr, mappedBytes, PROT_READ | PROT_WRITE,
        MAP_SHARED | MAP_ANON, -1, 0);
    if (address == MAP_FAILED) {
        result.error = OpenError::System;
        result.systemError = errno;
        result.message = std::strerror(errno);
        return {nullptr, result};
    }
    auto* memory = static_cast<SharedAudioMemory*>(address);
    new (memory) SharedAudioMemory {};
    memory->header.headerBytes = sizeof(SharedAudioHeader);
    memory->header.totalBytes = static_cast<std::uint32_t>(kMemoryBytes);
    __atomic_store_n(&memory->header.magic, kSharedAudioMagic, __ATOMIC_RELEASE);
    return {std::unique_ptr<SharedAudioRing>(new SharedAudioRing(
                "anonymous-xpc", -1, memory, mappedBytes)),
        result};
}

std::pair<std::unique_ptr<SharedAudioRing>, OpenResult> SharedAudioRing::Attach(
    void* address, std::size_t mappedBytes, std::uint32_t expectedVersion)
{
    OpenResult result;
    if (address == nullptr || mappedBytes != MappedBytes()) {
        result.error = OpenError::SizeMismatch;
        result.message = "anonymous shared-memory size mismatch";
        return {nullptr, result};
    }
    auto* memory = static_cast<SharedAudioMemory*>(address);
    const auto magic =
        __atomic_load_n(&memory->header.magic, __ATOMIC_ACQUIRE);
    if (magic != kSharedAudioMagic ||
        memory->header.version != expectedVersion ||
        memory->header.headerBytes != sizeof(SharedAudioHeader) ||
        memory->header.totalBytes != kMemoryBytes ||
        memory->header.channelCount != kChannelCount ||
        memory->header.capacityFrames != kRingCapacityFrames) {
        result.error = OpenError::ProtocolMismatch;
        result.message =
            "anonymous shared-memory protocol mismatch; refusing mapping";
        return {nullptr, result};
    }
    return {std::unique_ptr<SharedAudioRing>(new SharedAudioRing(
                "anonymous-xpc", -1, memory, mappedBytes)),
        result};
}

bool SharedAudioRing::Unlink(const std::string& name, int* systemError)
{
    if (shm_unlink(name.c_str()) == 0 || errno == ENOENT) {
        return true;
    }
    if (systemError != nullptr) {
        *systemError = errno;
    }
    return false;
}

bool SharedAudioRing::TryWrite(const float* frames, std::uint32_t frameCount,
    double sampleTime) noexcept
{
    auto& header = memory_->header;
    header.producerCallbacks.fetch_add(1, std::memory_order_relaxed);
    header.producerHeartbeatNs.store(MonotonicTimeNs(), std::memory_order_relaxed);
    header.lastProducerSampleTimeBits.store(
        DoubleBits(sampleTime), std::memory_order_relaxed);

    if (frames == nullptr || frameCount == 0 || frameCount > kRingCapacityFrames) {
        if (frameCount > 0) {
            header.droppedFrames.fetch_add(frameCount, std::memory_order_relaxed);
            header.overrunCount.fetch_add(1, std::memory_order_relaxed);
        }
        return frameCount == 0;
    }

    const auto write = header.writeFrame.load(std::memory_order_relaxed);
    const auto read = header.readFrame.load(std::memory_order_acquire);
    const auto used = write >= read ? write - read : kRingCapacityFrames;
    if (used > kRingCapacityFrames || frameCount > kRingCapacityFrames - used) {
        header.droppedFrames.fetch_add(frameCount, std::memory_order_relaxed);
        header.overrunCount.fetch_add(1, std::memory_order_relaxed);
        return false;
    }

    const std::uint32_t firstFrame =
        static_cast<std::uint32_t>(write % kRingCapacityFrames);
    const std::uint32_t firstCount =
        std::min(frameCount, kRingCapacityFrames - firstFrame);
    std::memcpy(&memory_->samples[firstFrame * kChannelCount], frames,
        static_cast<std::size_t>(firstCount) * kChannelCount * sizeof(float));
    if (firstCount < frameCount) {
        std::memcpy(memory_->samples,
            frames + static_cast<std::size_t>(firstCount) * kChannelCount,
            static_cast<std::size_t>(frameCount - firstCount) * kChannelCount *
                sizeof(float));
    }

    const auto nextWrite = write + frameCount;
    header.producerFrames.fetch_add(frameCount, std::memory_order_relaxed);
    UpdateHighWater(header.highWaterFrames, used + frameCount);
    header.writeFrame.store(nextWrite, std::memory_order_release);
    return true;
}

std::uint32_t SharedAudioRing::TryRead(
    float* frames, std::uint32_t requestedFrames) noexcept
{
    auto& header = memory_->header;
    if (consumerGeneration_ == 0 ||
        header.consumerGeneration.load(std::memory_order_acquire) !=
            consumerGeneration_) {
        return 0;
    }
    header.consumerHeartbeatNs.store(MonotonicTimeNs(), std::memory_order_relaxed);
    if (frames == nullptr || requestedFrames == 0) {
        return 0;
    }

    const auto read = header.readFrame.load(std::memory_order_relaxed);
    const auto write = header.writeFrame.load(std::memory_order_acquire);
    const auto available = write >= read ? write - read : 0;
    const auto count = static_cast<std::uint32_t>(
        std::min<std::uint64_t>(requestedFrames, available));
    if (count == 0) {
        return 0;
    }

    const std::uint32_t firstFrame =
        static_cast<std::uint32_t>(read % kRingCapacityFrames);
    const std::uint32_t firstCount =
        std::min(count, kRingCapacityFrames - firstFrame);
    std::memcpy(frames, &memory_->samples[firstFrame * kChannelCount],
        static_cast<std::size_t>(firstCount) * kChannelCount * sizeof(float));
    if (firstCount < count) {
        std::memcpy(frames + static_cast<std::size_t>(firstCount) * kChannelCount,
            memory_->samples,
            static_cast<std::size_t>(count - firstCount) * kChannelCount *
                sizeof(float));
    }
    if (header.consumerGeneration.load(std::memory_order_acquire) !=
        consumerGeneration_) {
        return 0;
    }
    header.consumerFrames.fetch_add(count, std::memory_order_relaxed);
    header.readFrame.store(read + count, std::memory_order_release);
    return count;
}

void SharedAudioRing::ProducerStart(std::uint32_t sampleRate) noexcept
{
    auto& header = memory_->header;
    header.sampleRate.store(sampleRate, std::memory_order_release);
    header.producerGeneration.fetch_add(1, std::memory_order_relaxed);
    header.producerStarts.fetch_add(1, std::memory_order_relaxed);
    header.producerHeartbeatNs.store(MonotonicTimeNs(), std::memory_order_relaxed);
    header.producerActive.store(1, std::memory_order_release);
}

void SharedAudioRing::ProducerStop() noexcept
{
    auto& header = memory_->header;
    header.producerActive.store(0, std::memory_order_release);
    header.producerHeartbeatNs.store(MonotonicTimeNs(), std::memory_order_relaxed);
    header.producerStops.fetch_add(1, std::memory_order_relaxed);
}

bool SharedAudioRing::ConsumerStart(
    bool discardStaleFrames, std::uint64_t staleAfterNs) noexcept
{
    auto& header = memory_->header;
    const auto now = MonotonicTimeNs();
    std::uint32_t expected = 0;
    if (header.consumerActive.compare_exchange_strong(expected, 1,
            std::memory_order_acq_rel, std::memory_order_acquire)) {
        // Publish freshness immediately so a simultaneous second opener does
        // not mistake a just-claimed slot for an abandoned prior generation.
        header.consumerHeartbeatNs.store(now, std::memory_order_release);
    } else {
        const auto heartbeat =
            header.consumerHeartbeatNs.load(std::memory_order_acquire);
        if (heartbeat != 0 && now >= heartbeat &&
            now - heartbeat <= staleAfterNs) {
            return false;
        }
    }
    consumerGeneration_ =
        header.consumerGeneration.fetch_add(1, std::memory_order_acq_rel) + 1;
    if (discardStaleFrames) {
        const auto write = header.writeFrame.load(std::memory_order_acquire);
        const auto read = header.readFrame.load(std::memory_order_relaxed);
        if (write > read) {
            header.staleFramesDiscarded.fetch_add(
                write - read, std::memory_order_relaxed);
            header.readFrame.store(write, std::memory_order_release);
        }
    }
    header.consumerStarts.fetch_add(1, std::memory_order_relaxed);
    header.consumerHeartbeatNs.store(now, std::memory_order_release);
    header.consumerActive.store(1, std::memory_order_release);
    return true;
}

void SharedAudioRing::ConsumerStop() noexcept
{
    auto& header = memory_->header;
    if (consumerGeneration_ == 0 ||
        header.consumerGeneration.load(std::memory_order_acquire) !=
            consumerGeneration_) {
        consumerGeneration_ = 0;
        return;
    }
    header.consumerActive.store(0, std::memory_order_release);
    header.consumerHeartbeatNs.store(MonotonicTimeNs(), std::memory_order_relaxed);
    header.consumerStops.fetch_add(1, std::memory_order_relaxed);
    consumerGeneration_ = 0;
}

void SharedAudioRing::SetSampleRate(std::uint32_t sampleRate) noexcept
{
    memory_->header.sampleRate.store(sampleRate, std::memory_order_release);
}

void SharedAudioRing::RecordUnderrun() noexcept
{
    memory_->header.underrunCount.fetch_add(1, std::memory_order_relaxed);
}

RingSnapshot SharedAudioRing::Snapshot() const noexcept
{
    const auto& h = memory_->header;
    RingSnapshot s;
    s.writeFrame = h.writeFrame.load(std::memory_order_acquire);
    s.readFrame = h.readFrame.load(std::memory_order_acquire);
    s.producerCallbacks = h.producerCallbacks.load(std::memory_order_relaxed);
    s.producerFrames = h.producerFrames.load(std::memory_order_relaxed);
    s.consumerFrames = h.consumerFrames.load(std::memory_order_relaxed);
    s.droppedFrames = h.droppedFrames.load(std::memory_order_relaxed);
    s.overrunCount = h.overrunCount.load(std::memory_order_relaxed);
    s.underrunCount = h.underrunCount.load(std::memory_order_relaxed);
    s.highWaterFrames = h.highWaterFrames.load(std::memory_order_relaxed);
    s.producerStarts = h.producerStarts.load(std::memory_order_relaxed);
    s.producerStops = h.producerStops.load(std::memory_order_relaxed);
    s.consumerStarts = h.consumerStarts.load(std::memory_order_relaxed);
    s.consumerStops = h.consumerStops.load(std::memory_order_relaxed);
    s.producerHeartbeatNs = h.producerHeartbeatNs.load(std::memory_order_relaxed);
    s.consumerHeartbeatNs = h.consumerHeartbeatNs.load(std::memory_order_relaxed);
    s.lastProducerSampleTime = BitsDouble(
        h.lastProducerSampleTimeBits.load(std::memory_order_relaxed));
    s.sampleRate = h.sampleRate.load(std::memory_order_acquire);
    s.producerActive = h.producerActive.load(std::memory_order_acquire);
    s.consumerActive = h.consumerActive.load(std::memory_order_acquire);
    s.producerGeneration = h.producerGeneration.load(std::memory_order_relaxed);
    s.consumerGeneration = h.consumerGeneration.load(std::memory_order_relaxed);
    s.staleFramesDiscarded =
        h.staleFramesDiscarded.load(std::memory_order_relaxed);
    return s;
}

void SharedAudioRing::Close() noexcept
{
    if (memory_ != nullptr) {
        munmap(memory_, mappedBytes_);
        memory_ = nullptr;
        mappedBytes_ = 0;
    }
    if (descriptor_ >= 0) {
        close(descriptor_);
        descriptor_ = -1;
    }
}

} // namespace twitch::audio
