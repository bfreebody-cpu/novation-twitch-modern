#import "TwitchA1USB.h"
#import <IOKit/usb/USB.h>
#import <mach/mach_time.h>
#import <unistd.h>

static NSString *A1StatusText(IOReturn status)
{
    const char *text = mach_error_string(status);
    return text ? [NSString stringWithUTF8String:text] : @"unknown";
}

static BOOL A1WriteAll(int fd, const void *bytes, size_t length)
{
    const uint8_t *cursor = bytes;
    while (length > 0) {
        ssize_t written = write(fd, cursor, length);
        if (written < 0) {
            if (errno == EINTR) continue;
            return NO;
        }
        cursor += written;
        length -= (size_t)written;
    }
    return YES;
}

static NSUInteger A1SamplesForUSBFrame(NSUInteger sampleRate, NSUInteger sequence)
{
    uint64_t before = ((uint64_t)sequence * sampleRate) / 1000;
    uint64_t after = ((uint64_t)(sequence + 1) * sampleRate) / 1000;
    return (NSUInteger)(after - before);
}

@interface TwitchA1Batch : NSObject
@property(nonatomic) NSUInteger firstSequence;
@property(nonatomic) uint64_t firstFrame;
@property(nonatomic) NSUInteger count;
@property(nonatomic) uint64_t submittedAt;
@property(nonatomic) uint64_t controllerFrameAtSubmit;
@property(nonatomic) uint32_t queuedFramesAtSubmit;
@property(nonatomic, strong) NSMutableData *data;
@property(nonatomic) IOUSBHostIsochronousTransaction *transactions;
@end

@implementation TwitchA1Batch
- (void)dealloc { free(_transactions); }
@end

@class TwitchA1USBSession;

@interface TwitchA1RunState : NSObject
@property(nonatomic, weak) TwitchA1USBSession *owner;
@property(nonatomic, strong) IOUSBHostPipe *pipe;
@property(nonatomic, strong, nullable) NSArray<NSData *> *outputPackets;
@property(nonatomic) BOOL outputMode;
@property(nonatomic) NSUInteger outputSampleRate;
@property(nonatomic) NSUInteger inputRequestBytes;
@property(nonatomic) NSUInteger totalFrames;
@property(nonatomic) NSUInteger nextSequence;
@property(nonatomic) uint64_t nextFrame;
@property(nonatomic) NSUInteger activeCount;
@property(nonatomic) BOOL stopping;
@property(nonatomic) BOOL signalled;
@property(nonatomic, strong, nullable) NSMutableArray<NSDictionary<NSString *, id> *> *results;
@property(nonatomic, strong, nullable) NSError *failure;
@property(nonatomic) dispatch_semaphore_t done;
@property(nonatomic) NSUInteger batchFrameCount;
@property(nonatomic) NSUInteger maximumActiveBatches;
@property(nonatomic) int recordFileDescriptor;
@property(nonatomic) int sampleFileDescriptor;
@property(nonatomic) BOOL sampleEveryPayload;
@property(nonatomic) uint64_t completedFrames;
@property(nonatomic) uint64_t completedBytes;
@property(nonatomic) uint64_t lateSubmissionCount;
@property(nonatomic) uint64_t minimumLead;
@property(nonatomic) uint64_t maximumLead;
@property(nonatomic) uint64_t minimumTimestampDelta;
@property(nonatomic) uint64_t maximumTimestampDelta;
@property(nonatomic) uint64_t previousTimestamp;
@property(nonatomic, strong) NSMutableDictionary<NSNumber *, NSNumber *> *lengthHistogram;
- (BOOL)submitNext:(NSError **)error;
- (void)completeBatch:(TwitchA1Batch *)batch status:(IOReturn)status;
- (void)cancelWithStatus:(IOReturn)status description:(NSString *)description;
@end

@interface TwitchA1USBSession ()
@property(nonatomic, strong) dispatch_queue_t queue;
@property(nonatomic, strong) IOUSBHostInterface *interface;
@property(nonatomic, strong, nullable) IOUSBHostPipe *inputPipe;
@property(nonatomic, strong, nullable) IOUSBHostPipe *outputPipe;
@property(nonatomic, strong) NSMutableArray<TwitchA1RunState *> *activeRuns;
@property(nonatomic) BOOL cancelled;
@property(nonatomic) BOOL shutDown;
@property(nonatomic, strong, nullable) dispatch_source_t signalSource;
@end

@implementation TwitchA1RunState

- (BOOL)submitNext:(NSError **)error
{
    @synchronized (self) {
        if (self.stopping || self.nextSequence >= self.totalFrames) return YES;
        const NSUInteger configuredBatch = self.batchFrameCount ?: 4;
        const NSUInteger batchFrames = MIN(configuredBatch, self.totalFrames - self.nextSequence);
        TwitchA1Batch *batch = [TwitchA1Batch new];
        batch.firstSequence = self.nextSequence;
        batch.firstFrame = self.nextFrame;
        batch.count = batchFrames;
        batch.submittedAt = clock_gettime_nsec_np(CLOCK_UPTIME_RAW);
        batch.controllerFrameAtSubmit = self.owner.currentFrameNumber;
        if (batch.firstFrame <= batch.controllerFrameAtSubmit) {
            self.lateSubmissionCount++;
            if (error) *error = [NSError errorWithDomain:NSOSStatusErrorDomain
                code:kIOReturnIsoTooOld userInfo:@{NSLocalizedDescriptionKey:
                [NSString stringWithFormat:@"refusing stale frame %llu at current frame %llu",
                 batch.firstFrame, batch.controllerFrameAtSubmit]}];
            return NO;
        }
        batch.queuedFramesAtSubmit = (uint32_t)MIN(UINT32_MAX,
            batch.firstFrame + batchFrames - batch.controllerFrameAtSubmit);
        batch.transactions = calloc(batchFrames, sizeof(IOUSBHostIsochronousTransaction));
        if (!batch.transactions) {
            if (error) *error = [NSError errorWithDomain:NSPOSIXErrorDomain code:ENOMEM userInfo:nil];
            return NO;
        }

        NSUInteger totalBytes = 0;
        for (NSUInteger i = 0; i < batchFrames; i++) {
            NSUInteger request;
            if (self.outputPackets) {
                request = self.outputPackets[self.nextSequence + i].length;
            } else if (self.outputMode) {
                request = A1SamplesForUSBFrame(self.outputSampleRate, self.nextSequence + i) * 12;
            } else {
                request = self.inputRequestBytes;
            }
            if (request > UINT32_MAX || totalBytes + request > UINT32_MAX) {
                if (error) *error = [NSError errorWithDomain:NSPOSIXErrorDomain code:EOVERFLOW userInfo:nil];
                return NO;
            }
            batch.transactions[i].status = kIOReturnInvalid;
            batch.transactions[i].requestCount = (uint32_t)request;
            batch.transactions[i].offset = (uint32_t)totalBytes;
            batch.transactions[i].completeCount = 0;
            batch.transactions[i].timeStamp = 0;
            batch.transactions[i].options = IOUSBHostIsochronousTransactionOptionsNone;
            totalBytes += request;
        }
        batch.data = [NSMutableData dataWithLength:totalBytes];
        if (self.outputPackets) {
            for (NSUInteger i = 0; i < batchFrames; i++) {
                NSData *packet = self.outputPackets[self.nextSequence + i];
                [batch.data replaceBytesInRange:NSMakeRange(batch.transactions[i].offset, packet.length)
                                      withBytes:packet.bytes];
            }
        }

        self.nextSequence += batchFrames;
        self.nextFrame += batchFrames;
        self.activeCount++;
        NSError *enqueueError = nil;
        __weak typeof(self) weakSelf = self;
        BOOL queued = [self.pipe enqueueIORequestWithData:batch.data
                                         transactionList:batch.transactions
                                    transactionListCount:batchFrames
                                      firstFrameNumber:batch.firstFrame
                                                options:IOUSBHostIsochronousTransferOptionsNone
                                                  error:&enqueueError
                                      completionHandler:^(IOReturn status, IOUSBHostIsochronousTransaction *transactions) {
            (void)transactions;
            [weakSelf completeBatch:batch status:status];
        }];
        if (!queued) {
            self.activeCount--;
            self.nextSequence -= batchFrames;
            self.nextFrame -= batchFrames;
            if (error) *error = enqueueError ?: [NSError errorWithDomain:NSOSStatusErrorDomain code:kIOReturnError userInfo:nil];
            return NO;
        }
        return YES;
    }
}

- (void)completeBatch:(TwitchA1Batch *)batch status:(IOReturn)status
{
    const uint64_t completedAt = clock_gettime_nsec_np(CLOCK_UPTIME_RAW);
    BOOL shouldSignal = NO;
    @synchronized (self) {
        const uint8_t *bytes = batch.data.bytes;
        for (NSUInteger i = 0; i < batch.count; i++) {
            IOUSBHostIsochronousTransaction transaction = batch.transactions[i];
            NSUInteger complete = MIN((NSUInteger)transaction.completeCount,
                                      (NSUInteger)transaction.requestCount);
            uint64_t sequence = batch.firstSequence + i;
            if (self.results) {
                NSData *payload = complete == 0 ? [NSData data]
                    : [NSData dataWithBytes:bytes + transaction.offset length:complete];
                [self.results addObject:@{
                    @"sequence": @(sequence), @"requestedFrame": @(batch.firstFrame + i),
                    @"requestCount": @(transaction.requestCount),
                    @"completeCount": @(transaction.completeCount),
                    @"frameStatus": @(transaction.status),
                    @"frameStatusText": A1StatusText(transaction.status),
                    @"transferStatus": @(status), @"transferStatusText": A1StatusText(status),
                    @"frameTimestamp": @(transaction.timeStamp),
                    @"submittedMonotonicNanoseconds": @(batch.submittedAt),
                    @"controllerFrameAtSubmit": @(batch.controllerFrameAtSubmit),
                    @"completedMonotonicNanoseconds": @(completedAt), @"payload": payload,
                }];
            }
            uint64_t lead = batch.firstFrame + i - batch.controllerFrameAtSubmit;
            self.minimumLead = MIN(self.minimumLead, lead);
            self.maximumLead = MAX(self.maximumLead, lead);
            self.completedFrames++;
            self.completedBytes += transaction.completeCount;
            NSNumber *lengthKey = @(transaction.completeCount);
            self.lengthHistogram[lengthKey] = @([self.lengthHistogram[lengthKey] unsignedLongLongValue] + 1);
            if (self.recordFileDescriptor >= 0) {
                TwitchA1FrameEvidenceV1 record = {
                    .sequence = sequence, .requestedFrame = batch.firstFrame + i,
                    .controllerFrameAtSubmit = batch.controllerFrameAtSubmit,
                    .frameTimestamp = transaction.timeStamp,
                    .submittedMonotonicNanoseconds = batch.submittedAt,
                    .completedMonotonicNanoseconds = completedAt,
                    .requestCount = transaction.requestCount,
                    .completeCount = transaction.completeCount,
                    .queuedFramesAtSubmit = batch.queuedFramesAtSubmit,
                    .frameStatus = transaction.status, .transferStatus = status,
                };
                if (!A1WriteAll(self.recordFileDescriptor, &record, sizeof(record)) && !self.failure) {
                    self.failure = [NSError errorWithDomain:NSPOSIXErrorDomain code:errno
                        userInfo:@{NSLocalizedDescriptionKey: @"failed writing sustained frame evidence"}];
                    self.stopping = YES;
                }
            }
            BOOL samplePayload = self.sampleFileDescriptor >= 0 &&
                (self.sampleEveryPayload || sequence < 1000 || sequence % 60000 < 1000);
            if (samplePayload) {
                TwitchA1PayloadSampleHeaderV1 header = { .sequence = sequence, .length = (uint32_t)complete };
                if (!A1WriteAll(self.sampleFileDescriptor, &header, sizeof(header)) ||
                    (complete && !A1WriteAll(self.sampleFileDescriptor, bytes + transaction.offset, complete))) {
                    if (!self.failure) self.failure = [NSError errorWithDomain:NSPOSIXErrorDomain code:errno
                        userInfo:@{NSLocalizedDescriptionKey: @"failed writing sustained payload sample"}];
                    self.stopping = YES;
                }
            }
            BOOL shortOutput = self.outputMode && transaction.completeCount != transaction.requestCount;
            if (status != kIOReturnSuccess || transaction.status != kIOReturnSuccess || shortOutput) {
                self.stopping = YES;
                if (!self.failure) {
                    IOReturn failureStatus = status != kIOReturnSuccess ? status : transaction.status;
                    NSString *message = [NSString stringWithFormat:
                        @"isochronous frame %lu failed: transfer %@, frame %@, completed %u/%u",
                        (unsigned long)(batch.firstSequence + i), A1StatusText(status),
                        A1StatusText(transaction.status), transaction.completeCount,
                        transaction.requestCount];
                    self.failure = [NSError errorWithDomain:NSOSStatusErrorDomain
                                                       code:failureStatus
                                                   userInfo:@{NSLocalizedDescriptionKey: message}];
                }
            }
        }
        self.activeCount--;
        NSUInteger maximumActive = self.maximumActiveBatches ?: 3;
        while (!self.stopping && self.activeCount < maximumActive && self.nextSequence < self.totalFrames) {
            NSError *submitError = nil;
            if (![self submitNext:&submitError]) {
                self.stopping = YES;
                self.failure = submitError;
                break;
            }
        }
        if (self.activeCount == 0 && (self.stopping || self.nextSequence >= self.totalFrames)) {
            if (!self.signalled) { self.signalled = YES; shouldSignal = YES; }
        }
    }
    if (shouldSignal) dispatch_semaphore_signal(self.done);
}

- (void)cancelWithStatus:(IOReturn)status description:(NSString *)description
{
    BOOL shouldSignal = NO;
    @synchronized (self) {
        self.stopping = YES;
        if (!self.failure) {
            self.failure = [NSError errorWithDomain:NSOSStatusErrorDomain code:status
                                           userInfo:@{NSLocalizedDescriptionKey: description}];
        }
        if (self.activeCount == 0 && !self.signalled) { self.signalled = YES; shouldSignal = YES; }
    }
    if (shouldSignal) dispatch_semaphore_signal(self.done);
}

@end

@implementation TwitchA1USBSession

- (nullable instancetype)initWithInterfaceService:(io_service_t)service error:(NSError **)error
{
    self = [super init];
    if (!self) return nil;
    _queue = dispatch_queue_create("org.twitch-modern.a1.usb", DISPATCH_QUEUE_SERIAL);
    _interface = [[IOUSBHostInterface alloc] initWithIOService:service
                                                       options:IOUSBHostObjectInitOptionsNone
                                                         queue:_queue
                                                         error:error
                                               interestHandler:nil];
    if (!_interface) return nil;
    _activeRuns = [NSMutableArray array];
    const IOUSBInterfaceDescriptor *descriptor = _interface.interfaceDescriptor;
    if (!descriptor || descriptor->bInterfaceNumber != 0) {
        if (error) *error = [NSError errorWithDomain:NSPOSIXErrorDomain code:EINVAL
                                            userInfo:@{NSLocalizedDescriptionKey: @"refusing nonzero USB interface"}];
        [_interface destroy];
        _interface = nil;
        return nil;
    }
    return self;
}

- (void)dealloc { if (!_shutDown) (void)[self shutdown]; }
- (uint8_t)alternateSetting { return self.interface.interfaceDescriptor->bAlternateSetting; }

- (NSData *)deviceDescriptorData
{
    const IOUSBDeviceDescriptor *descriptor = self.interface.deviceDescriptor;
    return descriptor ? [NSData dataWithBytes:descriptor length:descriptor->bLength] : [NSData data];
}

- (NSData *)configurationDescriptorData
{
    const IOUSBConfigurationDescriptor *descriptor = self.interface.configurationDescriptor;
    if (!descriptor) return [NSData data];
    NSUInteger length = OSSwapLittleToHostInt16(descriptor->wTotalLength);
    return [NSData dataWithBytes:descriptor length:length];
}

- (uint64_t)currentFrameNumber
{
    IOUSBHostTime time = 0;
    return [self.interface frameNumberWithTime:&time];
}

- (uint64_t)currentFrameHostTime
{
    IOUSBHostTime time = 0;
    (void)[self.interface frameNumberWithTime:&time];
    return time;
}

- (BOOL)selectAlternateSetting:(uint8_t)alternate error:(NSError **)error
{
    if (alternate > 1) {
        if (error) *error = [NSError errorWithDomain:NSPOSIXErrorDomain code:EINVAL userInfo:nil];
        return NO;
    }
    return [self.interface selectAlternateSetting:alternate error:error];
}

- (NSDictionary<NSString *, id> *)setSampleRate48000:(NSError **)error
{
    return [self setSampleRate:48000 error:error];
}

- (NSDictionary<NSString *, id> *)setSampleRate:(NSUInteger)sampleRate error:(NSError **)error
{
    if (sampleRate != 44100 && sampleRate != 48000) {
        if (error) *error = [NSError errorWithDomain:NSPOSIXErrorDomain code:EINVAL userInfo:nil];
        return @{ @"success": @NO, @"bytesTransferred": @0, @"data": [NSData data] };
    }
    uint8_t rate[3] = {
        (uint8_t)(sampleRate & 0xff), (uint8_t)((sampleRate >> 8) & 0xff),
        (uint8_t)((sampleRate >> 16) & 0xff)
    };
    NSMutableData *data = [NSMutableData dataWithBytes:rate length:3];
    IOUSBDeviceRequest request = { .bmRequestType = 0x22, .bRequest = 0x01,
        .wValue = OSSwapHostToLittleInt16(0x0100), .wIndex = OSSwapHostToLittleInt16(0x0001),
        .wLength = OSSwapHostToLittleInt16(3) };
    NSUInteger transferred = 0;
    BOOL success = [self.interface sendDeviceRequest:request data:data bytesTransferred:&transferred
                                    completionTimeout:1.0 error:error];
    return @{ @"success": @(success), @"bytesTransferred": @(transferred), @"data": data,
              @"bmRequestType": @0x22, @"bRequest": @0x01, @"wValue": @0x0100,
              @"wIndex": @0x0001, @"wLength": @3 };
}

- (NSDictionary<NSString *, id> *)getSampleRate:(NSError **)error
{
    NSMutableData *data = [NSMutableData dataWithLength:3];
    IOUSBDeviceRequest request = { .bmRequestType = 0xa2, .bRequest = 0x81,
        .wValue = OSSwapHostToLittleInt16(0x0100), .wIndex = OSSwapHostToLittleInt16(0x0001),
        .wLength = OSSwapHostToLittleInt16(3) };
    NSUInteger transferred = 0;
    BOOL success = [self.interface sendDeviceRequest:request data:data bytesTransferred:&transferred
                                    completionTimeout:1.0 error:error];
    return @{ @"success": @(success), @"bytesTransferred": @(transferred), @"data": data,
              @"bmRequestType": @0xa2, @"bRequest": @0x81, @"wValue": @0x0100,
              @"wIndex": @0x0001, @"wLength": @3 };
}

- (void)startSignalMonitorWithFileDescriptor:(int)fileDescriptor
{
    if (self.signalSource || fileDescriptor < 0) return;
    dispatch_source_t source = dispatch_source_create(DISPATCH_SOURCE_TYPE_READ,
        (uintptr_t)fileDescriptor, 0, dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0));
    __weak typeof(self) weakSelf = self;
    dispatch_source_set_event_handler(source, ^{
        uint8_t signalNumber = 0;
        (void)read(fileDescriptor, &signalNumber, sizeof(signalNumber));
        [weakSelf cancel];
    });
    self.signalSource = source;
    dispatch_resume(source);
}

- (void)stopSignalMonitor
{
    if (!self.signalSource) return;
    dispatch_source_cancel(self.signalSource);
    self.signalSource = nil;
}

- (nullable NSArray<NSDictionary<NSString *, id> *> *)observeInputEndpoint82ForFrames:(NSUInteger)frameCount
                                                                         requestBytes:(NSUInteger)requestBytes
                                                                           leadFrames:(NSUInteger)leadFrames
                                                                                 error:(NSError **)error
{
    if (requestBytes != 294 || frameCount == 0 || frameCount > 60000 || leadFrames < 8 || leadFrames > 64) {
        if (error) *error = [NSError errorWithDomain:NSPOSIXErrorDomain code:EINVAL
                                            userInfo:@{NSLocalizedDescriptionKey: @"unsafe endpoint-0x82 bounds"}];
        return nil;
    }
    if (!self.inputPipe) self.inputPipe = [self.interface copyPipeWithAddress:0x82 error:error];
    if (!self.inputPipe) return nil;
    return [self runPipe:self.inputPipe outputPackets:nil inputBytes:requestBytes
              frameCount:frameCount leadFrames:leadFrames error:error];
}

- (nullable NSArray<NSDictionary<NSString *, id> *> *)sendOutputEndpoint01Packets:(NSArray<NSData *> *)packets
                                                                        leadFrames:(NSUInteger)leadFrames
                                                                              error:(NSError **)error
{
    if (packets.count == 0 || packets.count > 10000 || leadFrames < 8 || leadFrames > 64) {
        if (error) *error = [NSError errorWithDomain:NSPOSIXErrorDomain code:EINVAL
                                            userInfo:@{NSLocalizedDescriptionKey: @"unsafe endpoint-0x01 bounds"}];
        return nil;
    }
    for (NSData *packet in packets) {
        if (packet.length == 0 || packet.length > 588 || packet.length % 12 != 0) {
            if (error) *error = [NSError errorWithDomain:NSPOSIXErrorDomain code:EINVAL
                                                userInfo:@{NSLocalizedDescriptionKey: @"invalid four-channel packed-24 packet"}];
            return nil;
        }
    }
    if (!self.outputPipe) self.outputPipe = [self.interface copyPipeWithAddress:0x01 error:error];
    if (!self.outputPipe) return nil;
    return [self runPipe:self.outputPipe outputPackets:packets inputBytes:0
              frameCount:packets.count leadFrames:leadFrames error:error];
}

- (nullable NSArray<NSDictionary<NSString *, id> *> *)runPipe:(IOUSBHostPipe *)pipe
                                                 outputPackets:(nullable NSArray<NSData *> *)packets
                                                     inputBytes:(NSUInteger)inputBytes
                                                     frameCount:(NSUInteger)frameCount
                                                     leadFrames:(NSUInteger)leadFrames
                                                          error:(NSError **)error
{
    @synchronized (self) {
        if (self.cancelled) {
            if (error) *error = [NSError errorWithDomain:NSPOSIXErrorDomain code:ECANCELED userInfo:nil];
            return nil;
        }
        for (TwitchA1RunState *existing in self.activeRuns) {
            if (existing.pipe == pipe) {
                if (error) *error = [NSError errorWithDomain:NSPOSIXErrorDomain code:EBUSY userInfo:nil];
                return nil;
            }
        }
    }
    TwitchA1RunState *state = [TwitchA1RunState new];
    state.owner = self; state.pipe = pipe; state.outputPackets = packets;
    state.outputMode = packets != nil;
    state.inputRequestBytes = inputBytes; state.totalFrames = frameCount;
    state.nextSequence = 0; state.nextFrame = self.currentFrameNumber + leadFrames;
    state.results = [NSMutableArray arrayWithCapacity:frameCount];
    // Use the bounded horizon validated by A1.5. The earlier 3 x 4-frame queue
    // can drain during a host callback delay and produce an honest IsoTooOld.
    state.batchFrameCount = 8; state.maximumActiveBatches = 8;
    state.recordFileDescriptor = -1; state.sampleFileDescriptor = -1;
    state.minimumLead = UINT64_MAX;
    state.lengthHistogram = [NSMutableDictionary dictionary];
    state.done = dispatch_semaphore_create(0);
    @synchronized (self) { [self.activeRuns addObject:state]; }
    for (NSUInteger i = 0; i < state.maximumActiveBatches && state.nextSequence < frameCount; i++) {
        NSError *submitError = nil;
        if (![state submitNext:&submitError]) {
            [state cancelWithStatus:(IOReturn)submitError.code description:submitError.localizedDescription];
            break;
        }
    }
    NSTimeInterval timeoutSeconds = MAX(5.0, (double)frameCount / 1000.0 + 5.0);
    long wait = dispatch_semaphore_wait(state.done,
        dispatch_time(DISPATCH_TIME_NOW, (int64_t)(timeoutSeconds * NSEC_PER_SEC)));
    if (wait != 0) {
        [state cancelWithStatus:kIOReturnTimeout description:@"bounded isochronous run timed out"];
        [self cancel];
        (void)dispatch_semaphore_wait(state.done, dispatch_time(DISPATCH_TIME_NOW, 2 * NSEC_PER_SEC));
    }
    NSArray *results = [state.results sortedArrayUsingComparator:^NSComparisonResult(NSDictionary *a, NSDictionary *b) {
        return [a[@"sequence"] compare:b[@"sequence"]];
    }];
    NSError *failure = state.failure;
    @synchronized (self) { [self.activeRuns removeObjectIdenticalTo:state]; }
    if (failure) { if (error) *error = failure; return nil; }
    return results;
}

- (nullable NSDictionary<NSString *, id> *)runSustainedInputEndpoint82ForFrames:(NSUInteger)frameCount
                                                           recordFileDescriptor:(int)recordFileDescriptor
                                                           sampleFileDescriptor:(int)sampleFileDescriptor
                                                                          error:(NSError **)error
{
    return [self runSustainedInputEndpoint82ForFrames:frameCount
                                 recordFileDescriptor:recordFileDescriptor
                                 sampleFileDescriptor:sampleFileDescriptor
                                    sampleEveryPayload:NO
                                                error:error];
}

- (nullable NSDictionary<NSString *, id> *)runSustainedInputEndpoint82ForFrames:(NSUInteger)frameCount
                                                           recordFileDescriptor:(int)recordFileDescriptor
                                                           sampleFileDescriptor:(int)sampleFileDescriptor
                                                              sampleEveryPayload:(BOOL)sampleEveryPayload
                                                                          error:(NSError **)error
{
    if (frameCount == 0 || frameCount > 3600000 || recordFileDescriptor < 0 || sampleFileDescriptor < 0) {
        if (error) *error = [NSError errorWithDomain:NSPOSIXErrorDomain code:EINVAL
            userInfo:@{NSLocalizedDescriptionKey: @"unsafe sustained endpoint-0x82 bounds"}];
        return nil;
    }
    if (!self.inputPipe) self.inputPipe = [self.interface copyPipeWithAddress:0x82 error:error];
    if (!self.inputPipe) return nil;
    return [self runSustainedPipe:self.inputPipe outputSampleRate:0 frameCount:frameCount
             recordFileDescriptor:recordFileDescriptor sampleFileDescriptor:sampleFileDescriptor
             sampleEveryPayload:sampleEveryPayload error:error];
}

- (nullable NSDictionary<NSString *, id> *)runSustainedSilenceEndpoint01AtSampleRate:(NSUInteger)sampleRate
                                                                           frames:(NSUInteger)frameCount
                                                             recordFileDescriptor:(int)recordFileDescriptor
                                                                            error:(NSError **)error
{
    if ((sampleRate != 44100 && sampleRate != 48000) || frameCount == 0 ||
        frameCount > 3600000 || recordFileDescriptor < 0) {
        if (error) *error = [NSError errorWithDomain:NSPOSIXErrorDomain code:EINVAL
            userInfo:@{NSLocalizedDescriptionKey: @"unsafe sustained endpoint-0x01 bounds"}];
        return nil;
    }
    if (!self.outputPipe) self.outputPipe = [self.interface copyPipeWithAddress:0x01 error:error];
    if (!self.outputPipe) return nil;
    return [self runSustainedPipe:self.outputPipe outputSampleRate:sampleRate frameCount:frameCount
             recordFileDescriptor:recordFileDescriptor sampleFileDescriptor:-1
             sampleEveryPayload:NO error:error];
}

- (nullable NSDictionary<NSString *, id> *)runSustainedPipe:(IOUSBHostPipe *)pipe
                                             outputSampleRate:(NSUInteger)sampleRate
                                                    frameCount:(NSUInteger)frameCount
                                          recordFileDescriptor:(int)recordFileDescriptor
                                          sampleFileDescriptor:(int)sampleFileDescriptor
                                             sampleEveryPayload:(BOOL)sampleEveryPayload
                                                         error:(NSError **)error
{
    @synchronized (self) {
        if (self.cancelled) {
            if (error) *error = [NSError errorWithDomain:NSPOSIXErrorDomain code:ECANCELED userInfo:nil];
            return nil;
        }
        for (TwitchA1RunState *existing in self.activeRuns) {
            if (existing.pipe == pipe) {
                if (error) *error = [NSError errorWithDomain:NSPOSIXErrorDomain code:EBUSY userInfo:nil];
                return nil;
            }
        }
    }
    TwitchA1RunState *state = [TwitchA1RunState new];
    state.owner = self; state.pipe = pipe;
    state.outputMode = sampleRate != 0; state.outputSampleRate = sampleRate;
    state.inputRequestBytes = sampleRate == 0 ? 294 : 0;
    state.totalFrames = frameCount; state.nextSequence = 0;
    // The initial 16-frame horizon failed after 140.556 seconds when a measured
    // completion callback gap reached 18.108 ms.  Keep a bounded 64-frame
    // validation horizon while retaining incremental completion-driven refill.
    state.nextFrame = self.currentFrameNumber + 64;
    state.results = nil; state.batchFrameCount = 8; state.maximumActiveBatches = 8;
    state.recordFileDescriptor = recordFileDescriptor;
    state.sampleFileDescriptor = sampleFileDescriptor;
    state.sampleEveryPayload = sampleEveryPayload;
    state.minimumLead = UINT64_MAX; state.lengthHistogram = [NSMutableDictionary dictionary];
    state.done = dispatch_semaphore_create(0);
    @synchronized (self) { [self.activeRuns addObject:state]; }
    for (NSUInteger i = 0; i < state.maximumActiveBatches && state.nextSequence < frameCount; i++) {
        NSError *submitError = nil;
        if (![state submitNext:&submitError]) {
            [state cancelWithStatus:(IOReturn)submitError.code description:submitError.localizedDescription];
            break;
        }
    }
    NSTimeInterval timeoutSeconds = (double)frameCount / 1000.0 + 10.0;
    long wait = dispatch_semaphore_wait(state.done,
        dispatch_time(DISPATCH_TIME_NOW, (int64_t)(timeoutSeconds * NSEC_PER_SEC)));
    if (wait != 0) {
        [state cancelWithStatus:kIOReturnTimeout description:@"sustained isochronous run timed out"];
        [self cancel];
        (void)dispatch_semaphore_wait(state.done, dispatch_time(DISPATCH_TIME_NOW, 2 * NSEC_PER_SEC));
    }
    NSError *failure = state.failure;
    @synchronized (self) { [self.activeRuns removeObjectIdenticalTo:state]; }
    if (failure) { if (error) *error = failure; return nil; }
    NSMutableDictionary<NSString *, NSNumber *> *serializableHistogram = [NSMutableDictionary dictionary];
    for (NSNumber *packetLength in state.lengthHistogram) {
        serializableHistogram[packetLength.stringValue] = state.lengthHistogram[packetLength];
    }
    return @{
        @"requestedFrames": @(frameCount), @"completedFrames": @(state.completedFrames),
        @"completedBytes": @(state.completedBytes), @"lateSubmissionCount": @(state.lateSubmissionCount),
        @"minimumLeadFrames": @(state.minimumLead == UINT64_MAX ? 0 : state.minimumLead),
        @"maximumLeadFrames": @(state.maximumLead), @"batchFrames": @(state.batchFrameCount),
        @"maximumActiveBatches": @(state.maximumActiveBatches),
        @"lengthHistogram": serializableHistogram,
    };
}

- (void)cancel
{
    @synchronized (self) {
        if (self.cancelled) return;
        self.cancelled = YES;
        NSArray<TwitchA1RunState *> *runs = [self.activeRuns copy];
        for (TwitchA1RunState *run in runs) {
            [run cancelWithStatus:kIOReturnAborted description:@"A1 session cancelled"];
        }
        NSError *ignored = nil;
        if (self.inputPipe) [self.inputPipe abortWithOption:IOUSBHostAbortOptionSynchronous error:&ignored];
        ignored = nil;
        if (self.outputPipe) [self.outputPipe abortWithOption:IOUSBHostAbortOptionSynchronous error:&ignored];
    }
}

- (NSDictionary<NSString *, id> *)shutdown
{
    @synchronized (self) {
        if (self.shutDown) return @{ @"alreadyShutdown": @YES };
        [self stopSignalMonitor];
        [self cancel];
        NSMutableDictionary *result = [NSMutableDictionary dictionary];
        result[@"alternateBeforeRestore"] = @(self.alternateSetting);
        NSError *restoreError = nil;
        BOOL restored = self.alternateSetting == 0 || [self.interface selectAlternateSetting:0 error:&restoreError];
        result[@"restoredAlternate0"] = @(restored);
        result[@"alternateAfterRestore"] = @(self.alternateSetting);
        if (restoreError) result[@"restoreError"] = restoreError.localizedDescription;
        self.inputPipe = nil; self.outputPipe = nil;
        [self.interface destroy];
        self.interface = nil;
        self.shutDown = YES;
        return result;
    }
}

@end
