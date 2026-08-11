import Foundation
import IOKit
import IOUSBHost
import TwitchProbeCore

private final class OutputBuffer: @unchecked Sendable {
    let payload: [UInt8]
    let data: NSMutableData

    init(payload: [UInt8]) {
        self.payload = payload
        data = NSMutableData(bytes: payload, length: payload.count)
    }
}

enum USBControllerOutputError: Error, CustomStringConvertible {
    case closed
    case queueFull(requested: Int, available: Int)

    var description: String {
        switch self {
        case .closed: "controller output is closed"
        case let .queueFull(requested, available):
            "controller output queue full: requested \(requested) packet(s), \(available) slot(s) available"
        }
    }
}

/// Owns only output scheduling for the already-open controller interface.
/// One interrupt transfer is outstanding at a time; accepted packets are bounded,
/// ordered, never retried, and never sent to any endpoint other than 0x03.
final class USBControllerOutput: @unchecked Sendable {
    static let queueCapacity = 256

    private let pipe: IOUSBHostPipe
    private let endpoint: EndpointDescriptor
    private let runStart: UInt64
    private let recorder: RunRecorder
    private let failureHandler: @Sendable (String) -> Void
    private let stateQueue = DispatchQueue(label: "org.twitch-modern.m4.usb-output")
    private var packets = BoundedOutputQueue<[UInt8]>(capacity: queueCapacity)
    private var inFlight = false
    private var stopping = false
    private var sequence = 0
    private var rejectedPackets = 0

    init(
        pipe: IOUSBHostPipe, endpoint: EndpointDescriptor, runStart: UInt64,
        recorder: RunRecorder, failureHandler: @escaping @Sendable (String) -> Void
    ) {
        precondition(endpoint.address == 0x03)
        self.pipe = pipe
        self.endpoint = endpoint
        self.runStart = runStart
        self.recorder = recorder
        self.failureHandler = failureHandler
    }

    func enqueue(messages: [[UInt8]]) throws {
        for message in messages { try TwitchBasicOutputPolicy.validate(message) }
        let additions = try MIDIUSBPacketizer.packets(
            messages: messages,
            maximumPacketSize: Int(endpoint.maximumPacketPayloadBytes)
        )
        guard !additions.isEmpty else { return }
        try stateQueue.sync {
            guard !stopping else { throw USBControllerOutputError.closed }
            guard additions.count <= packets.remainingCapacity else {
                rejectedPackets += additions.count
                throw USBControllerOutputError.queueFull(
                    requested: additions.count, available: packets.remainingCapacity
                )
            }
            for packet in additions { precondition(packets.append(packet)) }
            submitNextIfNeeded()
        }
    }

    func stopAccepting() {
        stateQueue.sync {
            stopping = true
            rejectedPackets += packets.count
            packets.removeAll()
        }
    }

    func snapshot() -> (queued: Int, inFlight: Bool, rejected: Int) {
        stateQueue.sync { (packets.count, inFlight, rejectedPackets) }
    }

    private func submitNextIfNeeded() {
        dispatchPrecondition(condition: .onQueue(stateQueue))
        guard !stopping, !inFlight, let payload = packets.popFirst() else { return }
        inFlight = true
        sequence += 1
        let transferSequence = sequence
        let buffer = OutputBuffer(payload: payload)
        do {
            try pipe.enqueueIORequest(
                with: buffer.data, completionTimeout: 0
            ) { [weak self, buffer] status, count in
                self?.stateQueue.async { [weak self, buffer] in
                    self?.complete(
                        sequence: transferSequence, status: status,
                        count: count, buffer: buffer
                    )
                }
            }
        } catch {
            inFlight = false
            stopping = true
            rejectedPackets += packets.count
            packets.removeAll()
            failureHandler("controller OUT enqueue failed: \(error)")
        }
    }

    private func complete(
        sequence: Int, status: IOReturn, count: Int, buffer: OutputBuffer
    ) {
        dispatchPrecondition(condition: .onQueue(stateQueue))
        inFlight = false
        recorder.recordOutputTransfer(
            sequence: sequence, runStart: runStart, endpoint: endpoint.address,
            status: status, requestedPayload: buffer.payload, bytesTransferred: count
        )
        if status != kIOReturnSuccess {
            stopping = true
            rejectedPackets += packets.count
            packets.removeAll()
            failureHandler(
                String(format: "controller OUT transfer failed: 0x%08x", UInt32(bitPattern: status))
            )
            return
        }
        submitNextIfNeeded()
    }
}
