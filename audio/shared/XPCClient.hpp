// SPDX-License-Identifier: MIT

#pragma once

#include "SharedAudioRing.hpp"

#include <memory>
#include <string>

namespace twitch::audio {

struct XPCConnectResult {
    std::string message;
    explicit operator bool() const { return message.empty(); }
};

std::pair<std::unique_ptr<SharedAudioRing>, XPCConnectResult>
ConnectToXPCService();

} // namespace twitch::audio
