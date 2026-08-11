#import "USBHostShim.h"
#include <errno.h>
#include <fcntl.h>
#include <signal.h>
#include <unistd.h>

static int signalPipe[2] = { -1, -1 };

static void TwitchSignalHandler(int signalNumber)
{
    uint8_t value = (uint8_t)signalNumber;
    if (signalPipe[1] >= 0) {
        (void)write(signalPipe[1], &value, sizeof(value));
    }
}

IOReturn TwitchAbortPipeSynchronously(IOUSBHostPipe *pipe)
{
    NSError *error = nil;
    if ([pipe abortWithOption:IOUSBHostAbortOptionSynchronous error:&error]) {
        return kIOReturnSuccess;
    }
    return error ? (IOReturn)error.code : kIOReturnError;
}

int TwitchInstallSignalPipe(void)
{
    if (pipe(signalPipe) != 0) {
        return errno;
    }
    (void)fcntl(signalPipe[0], F_SETFL, O_NONBLOCK);
    (void)fcntl(signalPipe[1], F_SETFL, O_NONBLOCK);
    (void)fcntl(signalPipe[0], F_SETFD, FD_CLOEXEC);
    (void)fcntl(signalPipe[1], F_SETFD, FD_CLOEXEC);
    struct sigaction action = { 0 };
    action.sa_handler = TwitchSignalHandler;
    sigemptyset(&action.sa_mask);
    action.sa_flags = SA_RESTART;
    if (sigaction(SIGINT, &action, NULL) != 0 || sigaction(SIGTERM, &action, NULL) != 0) {
        int result = errno;
        TwitchCloseSignalPipe();
        return result;
    }
    return 0;
}

int TwitchSignalReadFileDescriptor(void)
{
    return signalPipe[0];
}

int TwitchReadPendingSignal(void)
{
    uint8_t value = 0;
    ssize_t count = read(signalPipe[0], &value, sizeof(value));
    return count == sizeof(value) ? value : 0;
}

void TwitchCloseSignalPipe(void)
{
    struct sigaction action = { 0 };
    action.sa_handler = SIG_DFL;
    sigemptyset(&action.sa_mask);
    (void)sigaction(SIGINT, &action, NULL);
    (void)sigaction(SIGTERM, &action, NULL);
    if (signalPipe[0] >= 0) close(signalPipe[0]);
    if (signalPipe[1] >= 0) close(signalPipe[1]);
    signalPipe[0] = signalPipe[1] = -1;
}
