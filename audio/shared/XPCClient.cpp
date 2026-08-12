// SPDX-License-Identifier: MIT

#include "XPCClient.hpp"
#include "XPCBridge.hpp"

#include <xpc/xpc.h>

#include <sys/mman.h>

namespace twitch::audio {

std::pair<std::unique_ptr<SharedAudioRing>, XPCConnectResult>
ConnectToXPCService()
{
    XPCConnectResult result;
    xpc_connection_t connection = xpc_connection_create_mach_service(
        kXPCServiceName, nullptr, 0);
    if (connection == nullptr) {
        result.message = "xpc_connection_create_mach_service failed";
        return {nullptr, result};
    }
    xpc_connection_set_event_handler(connection, ^(xpc_object_t) {});
    xpc_connection_activate(connection);

    xpc_object_t request = xpc_dictionary_create(nullptr, nullptr, 0);
    xpc_dictionary_set_string(
        request, kXPCOperationKey, kXPCAcquireOperation);
    xpc_object_t reply =
        xpc_connection_send_message_with_reply_sync(connection, request);
    xpc_release(request);

    if (reply == nullptr || xpc_get_type(reply) == XPC_TYPE_ERROR) {
        result.message = reply == XPC_ERROR_CONNECTION_INVALID
            ? "XPC bridge service is unavailable"
            : "XPC bridge request failed";
        if (reply != nullptr) {
            xpc_release(reply);
        }
        xpc_connection_cancel(connection);
        xpc_release(connection);
        return {nullptr, result};
    }

    const char* serviceError = xpc_dictionary_get_string(reply, kXPCErrorKey);
    if (serviceError != nullptr) {
        result.message = serviceError;
        xpc_release(reply);
        xpc_connection_cancel(connection);
        xpc_release(connection);
        return {nullptr, result};
    }
    if (xpc_dictionary_get_uint64(reply, kXPCProtocolVersionKey) !=
        kSharedAudioVersion) {
        result.message = "XPC bridge protocol version mismatch";
        xpc_release(reply);
        xpc_connection_cancel(connection);
        xpc_release(connection);
        return {nullptr, result};
    }

    xpc_object_t shared =
        xpc_dictionary_get_value(reply, kXPCSharedMemoryKey);
    void* address = nullptr;
    const auto mappedBytes = shared == nullptr ? 0 : xpc_shmem_map(shared, &address);
    xpc_release(reply);
    xpc_connection_cancel(connection);
    xpc_release(connection);
    if (mappedBytes == 0 || address == nullptr) {
        result.message = "XPC shared-memory mapping failed";
        return {nullptr, result};
    }

    auto [ring, attachResult] = SharedAudioRing::Attach(address, mappedBytes);
    if (!attachResult) {
        munmap(address, mappedBytes);
        result.message = attachResult.message;
        return {nullptr, result};
    }
    return {std::move(ring), result};
}

} // namespace twitch::audio
