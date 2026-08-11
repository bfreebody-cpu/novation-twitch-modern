// Novation Twitch Modern bidirectional mapping for Mixxx 2.5.6+.
//
// The USB transport and Core MIDI virtual endpoints are provided by twitch-m1a
// in m4-bridge mode. Output is restricted to documented Twitch basic-mode LEDs.

// eslint-disable-next-line no-var
var NovationTwitchModern = {};

NovationTwitchModern.inputHandlers = [];
NovationTwitchModern.outputConnections = [];
NovationTwitchModern.outputDefinitions = [];
NovationTwitchModern.momentaryOutputDefinitions = [];
NovationTwitchModern.pitchPressed = {1: false, 2: false};
NovationTwitchModern.browsePressed = false;
NovationTwitchModern.scratching = {1: false, 2: false};

NovationTwitchModern.init = function(id, debugging) {
    NovationTwitchModern.debugging = debugging;
    NovationTwitchModern.registerInputs();
    NovationTwitchModern.registerOutputs();
    NovationTwitchModern.log({
        action: "init",
        controllerId: id,
        inputOnly: false,
        registeredHandlers: NovationTwitchModern.inputHandlers.length,
        registeredOutputs: NovationTwitchModern.outputConnections.length
    });
};

NovationTwitchModern.shutdown = function() {
    Object.keys(NovationTwitchModern.scratching).forEach(function(deckText) {
        const deck = Number(deckText);
        if (NovationTwitchModern.scratching[deck]) {
            engine.scratchDisable(deck);
            NovationTwitchModern.scratching[deck] = false;
        }
    });
    NovationTwitchModern.inputHandlers.forEach(function(handler) {
        handler.disconnect();
    });
    NovationTwitchModern.inputHandlers = [];
    NovationTwitchModern.outputConnections.forEach(function(connection) {
        connection.disconnect();
    });
    NovationTwitchModern.outputConnections = [];
    // Clear only the individual documented LEDs owned by this mapping. Do not
    // use the global all-off command or change the Twitch operating mode.
    NovationTwitchModern.outputDefinitions.forEach(function(definition) {
        midi.sendShortMsg(definition.status, definition.note, 0);
    });
    NovationTwitchModern.momentaryOutputDefinitions.forEach(function(definition) {
        midi.sendShortMsg(definition.status, definition.note, 0);
    });
    NovationTwitchModern.log({action: "shutdown", inputOnly: false});
};

NovationTwitchModern.addOutput = function(group, key, status, note, activeVelocity, id) {
    const definition = {
        group: group,
        key: key,
        status: status,
        note: note,
        activeVelocity: activeVelocity,
        id: id
    };
    NovationTwitchModern.outputDefinitions.push(definition);
    const connection = engine.makeConnection(group, key, function(value) {
        const velocity = value > 0 ? activeVelocity : 0;
        midi.sendShortMsg(status, note, velocity);
        NovationTwitchModern.log({
            action: "output",
            id: id,
            group: group,
            key: key,
            value: value,
            midi: NovationTwitchModern.midiRecord(status, note, velocity)
        });
    });
    NovationTwitchModern.outputConnections.push(connection);
    connection.trigger();
};

NovationTwitchModern.registerOutputs = function() {
    NovationTwitchModern.outputDefinitions = [];
    NovationTwitchModern.momentaryOutputDefinitions = [];
    [
        {deck: 1, status: 0x97, shiftStatus: 0x99},
        {deck: 2, status: 0x98, shiftStatus: 0x9A}
    ].forEach(function(deckOutput) {
        const group = "[Channel" + deckOutput.deck + "]";
        const suffix = "deck-" + (deckOutput.deck === 1 ? "a" : "b");
        NovationTwitchModern.addOutput(group, "play_indicator", deckOutput.status,
            23, 0x7F, suffix + "-play-led");
        NovationTwitchModern.addOutput(group, "play_indicator", deckOutput.shiftStatus,
            23, 0x7F, suffix + "-shift-play-led");
        NovationTwitchModern.addOutput(group, "cue_indicator", deckOutput.status,
            22, 0x0F, suffix + "-cue-led");
        NovationTwitchModern.addOutput(group, "reverse", deckOutput.shiftStatus,
            22, 0x4F, suffix + "-shift-reverse-led");
        NovationTwitchModern.addOutput(group, "pfl", deckOutput.status,
            10, 0x7F, suffix + "-pfl-led");
        NovationTwitchModern.addOutput(group, "pfl", deckOutput.shiftStatus,
            10, 0x7F, suffix + "-shift-pfl-led");
        NovationTwitchModern.addOutput(
            "[QuickEffectRack1_" + group + "]", "enabled", deckOutput.status,
            13, 0x7F, suffix + "-fader-fx-led"
        );
        NovationTwitchModern.addOutput(
            "[QuickEffectRack1_" + group + "]", "enabled", deckOutput.shiftStatus,
            13, 0x7F, suffix + "-shift-fader-fx-led"
        );
        NovationTwitchModern.addOutput(group, "quantize", deckOutput.status,
            16, 0x7F, suffix + "-quantize-led");
        NovationTwitchModern.addOutput(group, "quantize", deckOutput.shiftStatus,
            16, 0x7F, suffix + "-shift-quantize-led");
        NovationTwitchModern.addOutput(group, "keylock", deckOutput.status,
            18, 0x7F, suffix + "-keylock-led");
        NovationTwitchModern.addOutput(group, "keylock", deckOutput.shiftStatus,
            18, 0x7F, suffix + "-shift-keylock-led");
        NovationTwitchModern.addOutput(group, "sync_enabled", deckOutput.status,
            19, 0x7F, suffix + "-sync-led");
        NovationTwitchModern.addOutput(group, "sync_enabled", deckOutput.shiftStatus,
            19, 0x7F, suffix + "-shift-sync-led");
        NovationTwitchModern.addOutput(group, "slip_enabled", deckOutput.shiftStatus,
            17, 0x7F, suffix + "-shift-slip-led");
        NovationTwitchModern.momentaryOutputDefinitions.push({
            status: deckOutput.status,
            note: 17,
            id: suffix + "-beatgrid-adjust-momentary-led"
        });
        NovationTwitchModern.addOutput(group, "loop_enabled", deckOutput.status,
            58, 0x7F, suffix + "-loop-mode-led");
        NovationTwitchModern.addOutput(group, "loop_enabled", deckOutput.shiftStatus,
            58, 0x7F, suffix + "-shift-loop-mode-led");
        for (let hotcue = 1; hotcue <= 8; hotcue += 1) {
            NovationTwitchModern.addOutput(group, "hotcue_" + hotcue + "_enabled",
                deckOutput.status, 95 + hotcue, 0x4F,
                suffix + "-hotcue-" + hotcue + "-led");
            NovationTwitchModern.addOutput(group, "hotcue_" + hotcue + "_enabled",
                deckOutput.shiftStatus, 95 + hotcue, 0x4F,
                suffix + "-shift-hotcue-" + hotcue + "-led");
        }
        const loopSizes = ["0.5", "1", "2", "4", "8", "16", "32", "64"];
        loopSizes.forEach(function(size, index) {
            NovationTwitchModern.addOutput(group, "beatloop_" + size + "_enabled",
                deckOutput.status, 112 + index, 0x7F,
                suffix + "-loop-" + size + "-led");
        });
        const shiftedLoopSizes = ["0.03125", "0.0625", "0.125", "0.25", "0.5", "1", "2", "4"];
        shiftedLoopSizes.forEach(function(size, index) {
            NovationTwitchModern.addOutput(group, "beatloop_" + size + "_enabled",
                deckOutput.shiftStatus, 112 + index, 0x7F,
                suffix + "-shift-loop-" + size + "-led");
        });
    });
    NovationTwitchModern.addOutput(
        "[EffectRack1_EffectUnit1]", "group_[Channel1]_enable",
        0x9B, 32, 0x10, "fx-unit-1-deck-a-led"
    );
    NovationTwitchModern.addOutput(
        "[EffectRack1_EffectUnit1]", "group_[Channel2]_enable",
        0x9B, 33, 0x10, "fx-unit-1-deck-b-led"
    );
    NovationTwitchModern.addOutput(
        "[EffectRack1_EffectUnit1]", "enabled",
        0x9B, 34, 0x10, "fx-unit-1-enabled-led"
    );
};

NovationTwitchModern.range = function(first, last) {
    const result = [];
    for (let value = first; value <= last; value += 1) {
        result.push(value);
    }
    return result;
};

NovationTwitchModern.unique = function(values) {
    return values.filter(function(value, index) {
        return values.indexOf(value) === index;
    });
};

NovationTwitchModern.register = function(status, controls) {
    NovationTwitchModern.unique(controls).forEach(function(control) {
        const connection = midi.makeInputHandler(status, control,
            function(channel, receivedControl, value, receivedStatus) {
                NovationTwitchModern.handleInput(
                    Number(channel),
                    Number(receivedControl),
                    Number(value),
                    Number(receivedStatus)
                );
            });
        NovationTwitchModern.inputHandlers.push(connection);
    });
};

NovationTwitchModern.registerInputs = function() {
    const deckNotes = [0, 3, 6, 10, 13, 16, 17, 18, 19, 22, 23, 56, 57, 58, 59, 71]
        .concat(NovationTwitchModern.range(96, 127));
    const deckCCs = [3, 6, 7, 8, 9, 52, 53, 70, 71, 72];

    [0x97, 0x98, 0x99, 0x9A].forEach(function(status) {
        NovationTwitchModern.register(status, deckNotes);
    });
    [0xB7, 0xB8, 0xB9, 0xBA].forEach(function(status) {
        NovationTwitchModern.register(status, deckCCs);
    });

    // Browse controls are normally channel 8. LOAD was also measured on
    // channel 10, so both statuses are accepted without changing its meaning.
    NovationTwitchModern.register(0x97, NovationTwitchModern.range(80, 86));
    NovationTwitchModern.register(0x99, [82, 83]);
    NovationTwitchModern.register(0xB7, [85]);

    NovationTwitchModern.register(0x9B,
        [5, 6, 9, 10, 13, 14, 17, 18].concat(NovationTwitchModern.range(28, 35)));
    NovationTwitchModern.register(0xBB, NovationTwitchModern.range(0, 19));
};

NovationTwitchModern.deckForStatus = function(status) {
    const channel = status & 0x0F;
    if (channel === 7 || channel === 9) {
        return 1;
    }
    if (channel === 8 || channel === 10) {
        return 2;
    }
    return 0;
};

NovationTwitchModern.isShiftLayer = function(status) {
    const channel = status & 0x0F;
    return channel === 9 || channel === 10;
};

NovationTwitchModern.relative = function(value) {
    return value > 64 ? value - 128 : value;
};

NovationTwitchModern.clamp = function(value, minimum, maximum) {
    return Math.max(minimum, Math.min(maximum, value));
};

NovationTwitchModern.log = function(record) {
    console.log("TWITCH_MODERN " + JSON.stringify(record));
};

NovationTwitchModern.recordValue = function(action, group, key, before, after, midiData) {
    NovationTwitchModern.log({
        action: action,
        group: group,
        key: key,
        before: before,
        after: after,
        midi: midiData
    });
};

NovationTwitchModern.midiRecord = function(status, control, value) {
    return {
        status: "0x" + status.toString(16).toUpperCase(),
        control: control,
        value: value
    };
};

NovationTwitchModern.setValue = function(action, group, key, value, midiData) {
    const before = engine.getValue(group, key);
    engine.setValue(group, key, value);
    const after = engine.getValue(group, key);
    NovationTwitchModern.recordValue(action, group, key, before, after, midiData);
};

NovationTwitchModern.setParameter = function(action, group, key, value, midiData) {
    const before = engine.getParameter(group, key);
    engine.setParameter(group, key, value);
    const after = engine.getParameter(group, key);
    NovationTwitchModern.recordValue(action, group, key, before, after, midiData);
};

NovationTwitchModern.toggle = function(action, group, key, midiData) {
    const before = engine.getValue(group, key);
    const after = before > 0 ? 0 : 1;
    engine.setValue(group, key, after);
    NovationTwitchModern.recordValue(action, group, key, before, engine.getValue(group, key), midiData);
};

NovationTwitchModern.pulse = function(action, group, key, midiData) {
    const before = engine.getValue(group, key);
    engine.setValue(group, key, 1);
    engine.setValue(group, key, 0);
    NovationTwitchModern.recordValue(action, group, key, before, engine.getValue(group, key), midiData);
};

NovationTwitchModern.sendMomentaryLED = function(status, note, pressed, id) {
    const velocity = pressed ? 0x7F : 0;
    midi.sendShortMsg(status, note, velocity);
    NovationTwitchModern.log({
        action: "momentary-output",
        id: id,
        midi: NovationTwitchModern.midiRecord(status, note, velocity)
    });
};

NovationTwitchModern.handleInput = function(channel, control, value, status) {
    const messageType = status & 0xF0;
    const midiData = NovationTwitchModern.midiRecord(status, control, value);

    if (status === 0x9B) {
        NovationTwitchModern.handleFxNote(control, value, midiData);
        return;
    }
    if (status === 0xBB) {
        NovationTwitchModern.handleFxCC(control, value, midiData);
        return;
    }
    if (((status === 0x97 || status === 0x99) && control >= 80 && control <= 86) ||
            (status === 0xB7 && control === 85)) {
        NovationTwitchModern.handleBrowse(control, value, messageType, midiData);
        return;
    }

    const deck = NovationTwitchModern.deckForStatus(status);
    if (deck === 0) {
        NovationTwitchModern.log({action: "unhandled-channel", midi: midiData});
        return;
    }
    if (messageType === 0x90) {
        NovationTwitchModern.handleDeckNote(deck, control, value, status, midiData);
    } else if (messageType === 0xB0) {
        NovationTwitchModern.handleDeckCC(deck, control, value, status, midiData);
    }
};

NovationTwitchModern.handleBrowse = function(control, value, messageType, midiData) {
    if (messageType === 0xB0 && control === 85) {
        const delta = NovationTwitchModern.relative(value) *
            (NovationTwitchModern.browsePressed ? 8 : 1);
        NovationTwitchModern.setValue("browse-tracks", "[Playlist]", "SelectTrackKnob", delta, midiData);
        return;
    }

    const pressed = value > 0;
    if (control === 85) {
        NovationTwitchModern.browsePressed = pressed;
        NovationTwitchModern.log({action: "browse-speed-modifier", pressed: pressed, midi: midiData});
    } else if (pressed && control === 80) {
        NovationTwitchModern.toggle("maximize-library", "[Skin]", "show_maximized_library", midiData);
    } else if (pressed && control === 82) {
        NovationTwitchModern.pulse("load-deck-a", "[Channel1]", "LoadSelectedTrack", midiData);
    } else if (pressed && control === 83) {
        NovationTwitchModern.pulse("load-deck-b", "[Channel2]", "LoadSelectedTrack", midiData);
    } else if (pressed && control === 84) {
        NovationTwitchModern.pulse("browse-sidebar-previous", "[Playlist]", "SelectPrevPlaylist", midiData);
    } else if (pressed && control === 86) {
        NovationTwitchModern.pulse("browse-sidebar-next", "[Playlist]", "SelectNextPlaylist", midiData);
    } else if (control === 81) {
        NovationTwitchModern.log({action: "view-button-observed", pressed: pressed, midi: midiData});
    }
};

NovationTwitchModern.handleDeckCC = function(deck, control, value, status, midiData) {
    const group = "[Channel" + deck + "]";
    const normalized = value / 127;
    const shifted = NovationTwitchModern.isShiftLayer(status);

    if (control === 8 && deck === 1 && !shifted) {
        NovationTwitchModern.setParameter("crossfader", "[Master]", "crossfader", normalized, midiData);
    } else if (control === 7) {
        NovationTwitchModern.setParameter("channel-volume", group, "volume", normalized, midiData);
    } else if (control === 9) {
        NovationTwitchModern.setParameter("gain", group, "pregain", normalized, midiData);
    } else if (control >= 70 && control <= 72) {
        const parameter = control - 69;
        const eqGroup = "[EqualizerRack1_" + group + "_Effect1]";
        NovationTwitchModern.setParameter("eq-" + parameter, eqGroup,
            "parameter" + parameter, normalized, midiData);
    } else if (control === 3) {
        const delta = NovationTwitchModern.relative(value);
        const before = engine.getValue(group, "rate");
        const step = NovationTwitchModern.pitchPressed[deck] ? 0.02 : 0.0025;
        const after = NovationTwitchModern.clamp(before + delta * step, -1, 1);
        engine.setValue(group, "rate", after);
        NovationTwitchModern.recordValue("pitch", group, "rate", before,
            engine.getValue(group, "rate"), midiData);
    } else if (control === 6) {
        const quickGroup = "[QuickEffectRack1_" + group + "]";
        const delta = NovationTwitchModern.relative(value);
        const before = engine.getParameter(quickGroup, "super1");
        const after = NovationTwitchModern.clamp(before + delta / 64, 0, 1);
        engine.setParameter(quickGroup, "super1", after);
        NovationTwitchModern.recordValue("deck-quick-effect", quickGroup, "super1",
            before, engine.getParameter(quickGroup, "super1"), midiData);
    } else if (control === 52 && !shifted) {
        NovationTwitchModern.setParameter("touchstrip-drop", group, "playposition", normalized, midiData);
    } else if (control === 53) {
        const delta = NovationTwitchModern.relative(value);
        if (shifted && NovationTwitchModern.scratching[deck]) {
            engine.scratchTick(deck, delta);
            NovationTwitchModern.log({action: "touchstrip-scratch", deck: deck, delta: delta, midi: midiData});
        } else {
            NovationTwitchModern.setValue("touchstrip-swipe", group, "jog", delta / 3, midiData);
        }
    }
};

NovationTwitchModern.handleDeckNote = function(deck, control, value, status, midiData) {
    const group = "[Channel" + deck + "]";
    const pressed = value > 0;
    const shifted = NovationTwitchModern.isShiftLayer(status);

    if (control === 0) {
        NovationTwitchModern.log({action: "hardware-deck-page", deck: deck, pressed: pressed, midi: midiData});
    } else if (control === 3) {
        NovationTwitchModern.pitchPressed[deck] = pressed;
        NovationTwitchModern.log({action: "pitch-coarse-modifier", deck: deck, pressed: pressed, midi: midiData});
    } else if (control === 6 && pressed) {
        NovationTwitchModern.toggle("deck-quick-effect-toggle",
            "[QuickEffectRack1_" + group + "]", "enabled", midiData);
    } else if (control === 10 && pressed) {
        NovationTwitchModern.toggle("pfl", group, "pfl", midiData);
    } else if (control === 13 && pressed) {
        NovationTwitchModern.toggle("filter", "[QuickEffectRack1_" + group + "]", "enabled", midiData);
    } else if (control === 16 && pressed) {
        NovationTwitchModern.toggle("quantize", group, "quantize", midiData);
    } else if (control === 17) {
        if (shifted) {
            if (pressed) {
                NovationTwitchModern.toggle("slip", group, "slip_enabled", midiData);
            }
        } else {
            NovationTwitchModern.sendMomentaryLED(
                status, control, pressed, "deck-" + deck + "-beatgrid-adjust-led"
            );
            if (pressed) {
                NovationTwitchModern.pulse("beatgrid-align", group,
                    "beats_translate_curpos", midiData);
            }
        }
    } else if (control === 18 && pressed) {
        NovationTwitchModern.toggle("keylock", group, "keylock", midiData);
    } else if (control === 19 && pressed) {
        NovationTwitchModern.toggle("sync", group, "sync_enabled", midiData);
    } else if (control === 22) {
        NovationTwitchModern.setValue(shifted ? "reverse" : "cue", group,
            shifted ? "reverse" : "cue_default", pressed ? 1 : 0, midiData);
    } else if (control === 23 && pressed) {
        NovationTwitchModern.toggle("play", group, "play", midiData);
    } else if (control >= 56 && control <= 59) {
        NovationTwitchModern.log({action: "performance-mode", deck: deck,
            modeNote: control, pressed: pressed, midi: midiData});
    } else if (control === 71) {
        NovationTwitchModern.handleTouch(deck, value, shifted, midiData);
    } else if (control >= 96 && control <= 103) {
        const hotcue = control - 95;
        if (shifted) {
            if (pressed) {
                NovationTwitchModern.pulse("hotcue-clear", group,
                    "hotcue_" + hotcue + "_clear", midiData);
            }
        } else {
            NovationTwitchModern.setValue("hotcue", group,
                "hotcue_" + hotcue + "_activate", pressed ? 1 : 0, midiData);
        }
    } else if (control >= 104 && control <= 111) {
        NovationTwitchModern.handlePerformanceFx(deck, control - 104, pressed, midiData);
    } else if (control >= 112 && control <= 119 && pressed) {
        const normalSizes = ["0.5", "1", "2", "4", "8", "16", "32", "64"];
        const shiftedSizes = ["0.03125", "0.0625", "0.125", "0.25", "0.5", "1", "2", "4"];
        const size = (shifted ? shiftedSizes : normalSizes)[control - 112];
        NovationTwitchModern.pulse("auto-loop", group, "beatloop_" + size + "_toggle", midiData);
    } else if (control >= 120 && control <= 127) {
        const normalSizes = ["0.03125", "0.0625", "0.125", "0.25", "0.5", "1", "2", "4"];
        const shiftedSizes = ["0.5", "1", "2", "4", "8", "16", "32", "64"];
        const size = (shifted ? shiftedSizes : normalSizes)[control - 120];
        NovationTwitchModern.setValue("loop-roll", group,
            "beatlooproll_" + size + "_activate", pressed ? 1 : 0, midiData);
    }
};

NovationTwitchModern.handleTouch = function(deck, value, shifted, midiData) {
    const pressed = value > 0;
    if (!shifted) {
        NovationTwitchModern.log({action: "touchstrip-touch", deck: deck,
            position: value, pressed: pressed, midi: midiData});
        return;
    }
    if (pressed && !NovationTwitchModern.scratching[deck]) {
        engine.scratchEnable(deck, 128, 33 + 1 / 3, 1 / 8, (1 / 8) / 32);
        NovationTwitchModern.scratching[deck] = true;
    } else if (!pressed && NovationTwitchModern.scratching[deck]) {
        engine.scratchDisable(deck);
        NovationTwitchModern.scratching[deck] = false;
    }
    NovationTwitchModern.log({action: "touchstrip-scratch-touch", deck: deck,
        pressed: pressed, midi: midiData});
};

NovationTwitchModern.handlePerformanceFx = function(deck, pad, pressed, midiData) {
    if (pad < 4) {
        NovationTwitchModern.setValue("performance-sampler", "[Sampler" + (pad + 1) + "]",
            "cue_preview", pressed ? 1 : 0, midiData);
    } else if (pad === 4) {
        engine.spinback(deck, pressed, 2.5);
        NovationTwitchModern.log({action: "performance-spinback", deck: deck, pressed: pressed, midi: midiData});
    } else if (pad === 5) {
        engine.brake(deck, pressed, 2.5);
        NovationTwitchModern.log({action: "performance-brake", deck: deck, pressed: pressed, midi: midiData});
    } else {
        NovationTwitchModern.log({action: "performance-fx-reserved", deck: deck,
            pad: pad + 1, pressed: pressed, midi: midiData});
    }
};

NovationTwitchModern.handleFxNote = function(control, value, midiData) {
    const pressed = value > 0;
    const unit = "[EffectRack1_EffectUnit1]";
    if (control >= 28 && control <= 31) {
        NovationTwitchModern.log({action: "fx-parameter-page", page: control - 27,
            pressed: pressed, midi: midiData});
    } else if (control === 32 && pressed) {
        NovationTwitchModern.toggle("fx-assign-deck-a", unit, "group_[Channel1]_enable", midiData);
    } else if (control === 33 && pressed) {
        NovationTwitchModern.toggle("fx-assign-deck-b", unit, "group_[Channel2]_enable", midiData);
    } else if (control === 34 && pressed) {
        NovationTwitchModern.toggle("fx-unit-toggle", unit, "enabled", midiData);
    } else if (control === 35) {
        NovationTwitchModern.setValue("microphone-talkover", "[Microphone]", "talkover",
            pressed ? 1 : 0, midiData);
    } else {
        NovationTwitchModern.log({action: "undocumented-fx-encoder-push",
            control: control, pressed: pressed, midi: midiData});
    }
};

NovationTwitchModern.handleFxCC = function(control, value, midiData) {
    const position = control % 4;
    const unit = "[EffectRack1_EffectUnit1]";
    if (position === 0) {
        NovationTwitchModern.setParameter("fx-mix", unit, "mix", value / 127, midiData);
    } else if (position === 1) {
        const delta = NovationTwitchModern.relative(value);
        const before = engine.getParameter(unit, "super1");
        const after = NovationTwitchModern.clamp(before + delta / 64, 0, 1);
        engine.setParameter(unit, "super1", after);
        NovationTwitchModern.recordValue("fx-super", unit, "super1", before,
            engine.getParameter(unit, "super1"), midiData);
    } else if (position === 2) {
        NovationTwitchModern.setValue("fx-chain-select", unit,
            "chain_preset_selector", NovationTwitchModern.relative(value), midiData);
    } else {
        NovationTwitchModern.setParameter("microphone-gain", "[Microphone]", "pregain",
            value / 127, midiData);
    }
};
