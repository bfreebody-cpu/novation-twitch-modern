#pragma once

#import <Foundation/Foundation.h>
#import <IOKit/IOKitLib.h>
#import <IOUSBHost/IOUSBHost.h>

NS_ASSUME_NONNULL_BEGIN

typedef struct __attribute__((packed)) TwitchA1FrameEvidenceV1 {
    uint64_t sequence;
    uint64_t requestedFrame;
    uint64_t controllerFrameAtSubmit;
    uint64_t frameTimestamp;
    uint64_t submittedMonotonicNanoseconds;
    uint64_t completedMonotonicNanoseconds;
    uint32_t requestCount;
    uint32_t completeCount;
    uint32_t queuedFramesAtSubmit;
    int32_t frameStatus;
    int32_t transferStatus;
} TwitchA1FrameEvidenceV1;

typedef struct __attribute__((packed)) TwitchA1PayloadSampleHeaderV1 {
    uint64_t sequence;
    uint32_t length;
} TwitchA1PayloadSampleHeaderV1;

/// Interface-0-only transport used by the bounded A1 experiment.
@interface TwitchA1USBSession : NSObject

- (nullable instancetype)initWithInterfaceService:(io_service_t)service
                                             error:(NSError **)error;

@property(nonatomic, readonly) uint8_t alternateSetting;
@property(nonatomic, readonly) NSData *deviceDescriptorData;
@property(nonatomic, readonly) NSData *configurationDescriptorData;
@property(nonatomic, readonly) uint64_t currentFrameNumber;
@property(nonatomic, readonly) uint64_t currentFrameHostTime;

- (BOOL)selectAlternateSetting:(uint8_t)alternate error:(NSError **)error;
- (NSDictionary<NSString *, id> *)setSampleRate48000:(NSError **)error;
- (NSDictionary<NSString *, id> *)setSampleRate:(NSUInteger)sampleRate error:(NSError **)error;
- (NSDictionary<NSString *, id> *)getSampleRate:(NSError **)error;

/// Monitors the existing async-signal-safe self-pipe outside Swift concurrency.
- (void)startSignalMonitorWithFileDescriptor:(int)fileDescriptor;
- (void)stopSignalMonitor;

/// Runs a fixed number of full-capacity IN observations. Result dictionaries are
/// per USB frame and contain request/actual counts, timestamps and NSData payload.
- (nullable NSArray<NSDictionary<NSString *, id> *> *)observeInputEndpoint82ForFrames:(NSUInteger)frameCount
                                                                         requestBytes:(NSUInteger)requestBytes
                                                                           leadFrames:(NSUInteger)leadFrames
                                                                                 error:(NSError **)error;

/// Each NSData object is exactly one USB frame's OUT payload.
- (nullable NSArray<NSDictionary<NSString *, id> *> *)sendOutputEndpoint01Packets:(NSArray<NSData *> *)packets
                                                                        leadFrames:(NSUInteger)leadFrames
                                                                              error:(NSError **)error;

/// Continuous evidence path. The scheduler uses a fixed bounded outstanding
/// window and never retries a stale frame. `recordFileDescriptor` receives packed
/// TwitchA1FrameEvidenceV1 records. The input method also writes selected raw
/// payloads as TwitchA1PayloadSampleHeaderV1 + payload bytes.
- (nullable NSDictionary<NSString *, id> *)runSustainedInputEndpoint82ForFrames:(NSUInteger)frameCount
                                                           recordFileDescriptor:(int)recordFileDescriptor
                                                           sampleFileDescriptor:(int)sampleFileDescriptor
                                                                          error:(NSError **)error;
/// Characterization overload. When enabled, every bounded IN payload is copied
/// to the sample file instead of the normal sparse evidence windows.
- (nullable NSDictionary<NSString *, id> *)runSustainedInputEndpoint82ForFrames:(NSUInteger)frameCount
                                                           recordFileDescriptor:(int)recordFileDescriptor
                                                           sampleFileDescriptor:(int)sampleFileDescriptor
                                                              sampleEveryPayload:(BOOL)sampleEveryPayload
                                                                          error:(NSError **)error;
- (nullable NSDictionary<NSString *, id> *)runSustainedSilenceEndpoint01AtSampleRate:(NSUInteger)sampleRate
                                                                           frames:(NSUInteger)frameCount
                                                             recordFileDescriptor:(int)recordFileDescriptor
                                                                            error:(NSError **)error;

/// Idempotently stops scheduling and synchronously aborts any active pipes once.
- (void)cancel;

/// Aborts pending requests, restores alternate 0 if possible, and destroys ownership.
- (NSDictionary<NSString *, id> *)shutdown;

@end

NS_ASSUME_NONNULL_END
