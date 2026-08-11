// swift-tools-version: 6.2

import PackageDescription

let package = Package(
    name: "NovationTwitchModern",
    platforms: [.macOS(.v15)],
    products: [
        .library(name: "TwitchProbeCore", targets: ["TwitchProbeCore"]),
        .library(name: "TwitchAudioCore", targets: ["TwitchAudioCore"]),
        .executable(name: "twitch-usb-probe", targets: ["TwitchUSBProbe"]),
        .executable(name: "twitch-parser-tests", targets: ["TwitchParserTests"]),
        .executable(name: "twitch-m1a", targets: ["TwitchM1A"]),
        .executable(name: "twitch-m1b", targets: ["TwitchM1A"]),
        .executable(name: "twitch-m2", targets: ["TwitchM1A"]),
        .executable(name: "twitch-m4", targets: ["TwitchM1A"]),
        .executable(name: "twitch-midi-monitor", targets: ["TwitchMIDIMonitor"]),
        .executable(name: "coremidi-synthetic-publisher", targets: ["CoreMIDISyntheticPublisher"]),
        .executable(name: "twitch-a1", targets: ["TwitchA1"]),
        .executable(name: "twitch-a1-tests", targets: ["TwitchA1Tests"]),
        .executable(name: "twitch-a1-5", targets: ["TwitchA15"]),
        .executable(name: "twitch-a3-tests", targets: ["TwitchA3Tests"]),
    ],
    targets: [
        .target(name: "TwitchProbeCore"),
        .target(name: "TwitchAudioCore"),
        .executableTarget(
            name: "TwitchUSBProbe",
            dependencies: ["TwitchProbeCore"],
            linkerSettings: [
                .linkedFramework("IOKit"),
                .linkedFramework("IOUSBHost"),
            ]
        ),
        .executableTarget(name: "TwitchParserTests", dependencies: ["TwitchProbeCore"]),
        .executableTarget(
            name: "TwitchMIDIMonitor",
            dependencies: ["TwitchProbeCore"],
            linkerSettings: [.linkedFramework("CoreMIDI")]
        ),
        .executableTarget(
            name: "CoreMIDISyntheticPublisher",
            dependencies: ["TwitchProbeCore"],
            linkerSettings: [
                .linkedFramework("CoreAudio"),
                .linkedFramework("CoreMIDI"),
            ]
        ),
        .target(
            name: "USBHostShim",
            publicHeadersPath: "include",
            linkerSettings: [.linkedFramework("IOUSBHost")]
        ),
        .target(
            name: "TwitchA1USB",
            publicHeadersPath: "include",
            linkerSettings: [
                .linkedFramework("IOKit"),
                .linkedFramework("IOUSBHost"),
            ]
        ),
        .executableTarget(
            name: "TwitchA1",
            dependencies: ["TwitchProbeCore", "TwitchAudioCore", "TwitchA1USB", "USBHostShim"],
            linkerSettings: [
                .linkedFramework("IOKit"),
                .linkedFramework("IOUSBHost"),
            ]
        ),
        .executableTarget(name: "TwitchA1Tests", dependencies: ["TwitchAudioCore"]),
        .target(name: "TwitchA3Core", publicHeadersPath: "include"),
        .executableTarget(name: "TwitchA3Tests", dependencies: ["TwitchA3Core"]),
        .executableTarget(
            name: "TwitchA15",
            dependencies: ["TwitchProbeCore", "TwitchAudioCore", "TwitchA1USB", "USBHostShim"],
            linkerSettings: [
                .linkedFramework("IOKit"),
                .linkedFramework("IOUSBHost"),
            ]
        ),
        .executableTarget(
            name: "TwitchM1A",
            dependencies: ["TwitchProbeCore", "USBHostShim"],
            linkerSettings: [
                .linkedFramework("IOKit"),
                .linkedFramework("IOUSBHost"),
                .linkedFramework("CoreAudio"),
                .linkedFramework("CoreMIDI"),
            ]
        ),
    ]
)
