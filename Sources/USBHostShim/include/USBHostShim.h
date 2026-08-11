#pragma once

#import <Foundation/Foundation.h>
#import <IOUSBHost/IOUSBHost.h>

// Swift's macOS 26 overlay does not expose the synchronous abort option cleanly.
// This wrapper calls only IOUSBHostPipe's documented abort API.
IOReturn TwitchAbortPipeSynchronously(IOUSBHostPipe *pipe);

// Async-signal-safe self-pipe bridge for Swift DispatchSource handling.
int TwitchInstallSignalPipe(void);
int TwitchSignalReadFileDescriptor(void);
int TwitchReadPendingSignal(void);
void TwitchCloseSignalPipe(void);
