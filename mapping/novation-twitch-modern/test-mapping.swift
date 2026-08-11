#!/usr/bin/env swift

import Foundation
import JavaScriptCore

let context = JSContext()!
var exceptionText: String?
context.exceptionHandler = { _, exception in
    exceptionText = exception?.toString()
}

let mocks = #"""
var testHandlers = {};
var testValues = {};
var testParameters = {};
var testLogs = [];
var testOutputMessages = [];
var testConnections = [];
var console = { log: function(message) { testLogs.push(message); } };
var midi = {
    makeInputHandler: function(status, control, callback) {
        var handlerKey = status + ":" + control;
        testHandlers[handlerKey] = callback;
        return { disconnect: function() { delete testHandlers[handlerKey]; return true; } };
    },
    sendShortMsg: function(status, control, value) {
        testOutputMessages.push([status, control, value]);
    },
    send: function() { throw new Error("undocumented generic MIDI output used"); },
    sendSysexMsg: function() { throw new Error("SysEx output used"); }
};
function testKey(group, control) { return group + "|" + control; }
var engine = {
    getValue: function(group, control) { return testValues[testKey(group, control)] || 0; },
    setValue: function(group, control, value) {
        testValues[testKey(group, control)] = value;
        testConnections.forEach(function(connection) {
            if (connection.group === group && connection.control === control && connection.connected) {
                connection.callback(value, group, control);
            }
        });
    },
    getParameter: function(group, control) { return testParameters[testKey(group, control)] || 0; },
    setParameter: function(group, control, value) { testParameters[testKey(group, control)] = value; },
    scratchEnable: function() {},
    scratchDisable: function() {},
    scratchTick: function() {},
    spinback: function() {},
    brake: function() {},
    makeConnection: function(group, control, callback) {
        var connection = {
            group: group,
            control: control,
            callback: callback,
            connected: true,
            trigger: function() { callback(engine.getValue(group, control), group, control); },
            disconnect: function() { this.connected = false; return true; }
        };
        testConnections.push(connection);
        return connection;
    }
};
"""#

let testProgram = #"""
function testAssert(condition, message) {
    if (!condition) throw new Error(message);
}
function testSend(status, control, value) {
    var handler = testHandlers[status + ":" + control];
    if (!handler) throw new Error("missing handler " + status.toString(16) + ":" + control);
    handler(status & 0x0F, control, value, status);
}

NovationTwitchModern.init("Novation Twitch Modern", true);
testAssert(testConnections.length === 101, "expected 101 basic-mode output connections");
testAssert(testOutputMessages.length === 101, "initial output state was not triggered");
testOutputMessages = [];
testSend(0x97, 23, 127);
testAssert(testValues[testKey("[Channel1]", "play")] === 1, "deck A PLAY failed");
engine.setValue("[Channel1]", "play_indicator", 1);
testAssert(testOutputMessages.some(function(message) {
    return message[0] === 0x97 && message[1] === 23 && message[2] === 0x7F;
}), "deck A PLAY feedback failed");
[
    {key: "pfl", note: 10, label: "PFL"},
    {key: "quantize", note: 16, label: "quantize"},
    {key: "keylock", note: 18, label: "keylock"},
    {key: "sync_enabled", note: 19, label: "sync"}
].forEach(function(item) {
    engine.setValue("[Channel2]", item.key, 1);
    testAssert(testOutputMessages.some(function(message) {
        return message[0] === 0x98 && message[1] === item.note && message[2] === 0x7F;
    }), "deck B " + item.label + " feedback failed");
});
engine.setValue("[QuickEffectRack1_[Channel1]]", "enabled", 1);
testAssert(testOutputMessages.some(function(message) {
    return message[0] === 0x97 && message[1] === 13 && message[2] === 0x7F;
}), "deck A FADER FX feedback failed");
testAssert(testOutputMessages.some(function(message) {
    return message[0] === 0x99 && message[1] === 13 && message[2] === 0x7F;
}), "deck A shift-page FADER FX feedback failed");
testSend(0x98, 22, 127);
testSend(0x98, 22, 0);
testAssert(testValues[testKey("[Channel2]", "cue_default")] === 0, "deck B CUE failed");
testOutputMessages = [];
testSend(0x97, 17, 127);
testSend(0x97, 17, 0);
testAssert(testOutputMessages.some(function(message) {
    return message[0] === 0x97 && message[1] === 17 && message[2] === 0x7F;
}), "deck A BEAT GRID ADJUST press feedback failed");
testAssert(testOutputMessages.some(function(message) {
    return message[0] === 0x97 && message[1] === 17 && message[2] === 0;
}), "deck A BEAT GRID ADJUST release feedback failed");
testSend(0x99, 17, 127);
testAssert(testValues[testKey("[Channel1]", "slip_enabled")] === 1,
    "deck A SHIFT + ADJUST did not toggle slip mode");
testAssert(testOutputMessages.some(function(message) {
    return message[0] === 0x99 && message[1] === 17 && message[2] === 0x7F;
}), "deck A shift-page slip feedback failed");
testSend(0xB7, 8, 127);
testAssert(testParameters[testKey("[Master]", "crossfader")] === 1, "crossfader failed");
testSend(0xB8, 70, 64);
testAssert(testKey("[EqualizerRack1_[Channel2]_Effect1]", "parameter1") in testParameters,
    "current EQ control failed");
testSend(0xB7, 85, 1);
testAssert(testValues[testKey("[Playlist]", "SelectTrackKnob")] === 1, "browse failed");
testSend(0xB7, 53, 1);
testAssert(testValues[testKey("[Channel1]", "jog")] === 1 / 3,
    "measured touchstrip SWIPE direction failed");
testSend(0x99, 82, 127);
testAssert(testKey("[Channel1]", "LoadSelectedTrack") in testValues, "measured LOAD quirk failed");
testSend(0x97, 96, 127);
testAssert(testValues[testKey("[Channel1]", "hotcue_1_activate")] === 1, "hotcue failed");
engine.setValue("[Channel1]", "hotcue_1_enabled", 1);
testAssert(testOutputMessages.some(function(message) {
    return message[0] === 0x97 && message[1] === 96 && message[2] === 0x4F;
}), "hotcue amber feedback failed");
testAssert(testOutputMessages.some(function(message) {
    return message[0] === 0x99 && message[1] === 96 && message[2] === 0x4F;
}), "shift-page hotcue feedback failed");
engine.setValue("[Channel2]", "loop_enabled", 1);
testAssert(testOutputMessages.some(function(message) {
    return message[0] === 0x98 && message[1] === 58 && message[2] === 0x7F;
}), "loop-active feedback failed");
engine.setValue("[Channel1]", "beatloop_1_enabled", 1);
testAssert(testOutputMessages.some(function(message) {
    return message[0] === 0x97 && message[1] === 113 && message[2] === 0x7F;
}), "size-specific loop-pad feedback failed");
testAssert(testOutputMessages.some(function(message) {
    return message[0] === 0x99 && message[1] === 117 && message[2] === 0x7F;
}), "shift-page loop-pad feedback failed");
testSend(0x98, 112, 127);
testAssert(testKey("[Channel2]", "beatloop_0.5_toggle") in testValues, "auto loop failed");
testSend(0xBB, 2, 127);
testAssert(testValues[testKey("[EffectRack1_EffectUnit1]", "chain_preset_selector")] === -1,
    "FX selector failed");
testSend(0x9B, 29, 127);
testAssert(!(testKey("[EffectRack1_EffectUnit1_Effect2]", "enabled") in testValues),
    "basic-mode FX parameter-page button changed a Mixxx effect slot");
testSend(0x9B, 32, 127);
testAssert(testValues[testKey("[EffectRack1_EffectUnit1]", "group_[Channel1]_enable")] === 1,
    "Master FX left arrow assignment failed");
engine.setValue("[EffectRack1_EffectUnit1]", "enabled", 1);
testAssert(testOutputMessages.some(function(message) {
    return message[0] === 0x9B && message[1] === 34 && message[2] === 0x10;
}), "Master FX ON/OFF feedback failed");
testAssert(testOutputMessages.every(function(message) {
    const status = message[0];
    const note = message[1];
    const value = message[2];
    const deckAllowed = (status >= 0x97 && status <= 0x9A) &&
        (note === 10 || note === 13 || note === 16 || note === 17 || note === 18 ||
            note === 19 || note === 22 || note === 23 || note === 58 ||
            (note >= 96 && note <= 103) || (note >= 112 && note <= 119));
    const fxAllowed = status === 0x9B && (note === 32 || note === 33 || note === 34);
    return (deckAllowed || fxAllowed) && value >= 0 && value <= 127;
}), "mapping emitted output outside the M4 documented allowlist");
testAssert(testLogs.some(function(line) { return line.indexOf("TWITCH_MODERN ") === 0; }),
    "evidence logging failed");
NovationTwitchModern.shutdown();
testAssert(Object.keys(testHandlers).length === 0, "input handlers were not disconnected");
testAssert(testConnections.every(function(connection) { return !connection.connected; }),
    "output connections were not disconnected");
"passed";
"""#

let scriptURL = URL(fileURLWithPath: #filePath)
    .deletingLastPathComponent()
    .appendingPathComponent("Novation-Twitch-Modern-scripts.js")
let mapping = try String(contentsOf: scriptURL, encoding: .utf8)

context.evaluateScript(mocks)
context.evaluateScript(mapping, withSourceURL: scriptURL)
let result = context.evaluateScript(testProgram)

if let exceptionText {
    FileHandle.standardError.write(Data("Mapping test failed: \(exceptionText)\n".utf8))
    exit(EXIT_FAILURE)
}
guard result?.toString() == "passed" else {
    FileHandle.standardError.write(Data("Mapping test did not complete.\n".utf8))
    exit(EXIT_FAILURE)
}
print("Novation Twitch Modern deterministic mapping tests passed.")
