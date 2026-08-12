// SPDX-License-Identifier: MIT

#pragma once

namespace twitch::audio {

constexpr const char* kXPCServiceName =
    "com.twitchmodern.NovationTwitchModernAudioExperimental.bridge";
constexpr const char* kXPCOperationKey = "operation";
constexpr const char* kXPCAcquireOperation = "acquire-audio-ring";
constexpr const char* kXPCSharedMemoryKey = "audio-ring";
constexpr const char* kXPCProtocolVersionKey = "protocol-version";
constexpr const char* kXPCErrorKey = "error";

} // namespace twitch::audio
