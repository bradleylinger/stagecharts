// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "ChordProKit",
    platforms: [.macOS(.v13), .iOS(.v15)],
    products: [
        .library(name: "ChordProKit", targets: ["ChordProKit"]),
        .library(name: "StageMIDI", targets: ["StageMIDI"]),
        .library(name: "AbletonLink", targets: ["AbletonLink"]),
        .executable(name: "chordpro", targets: ["chordpro"]),
    ],
    targets: [
        .target(name: "ChordProKit"),
        .target(name: "StageMIDI"),
        // Ableton Link (GPL-2.0-or-later, https://github.com/Ableton/link) through its C API, abl_link.
        .target(
            name: "AbletonLink",
            path: "Vendor/link",
            sources: ["extensions/abl_link/src/abl_link.cpp"],
            publicHeadersPath: "extensions/abl_link/include",
            cxxSettings: [
                .headerSearchPath("include"),
                .headerSearchPath("modules/asio-standalone/include"),
                .define("LINK_PLATFORM_MACOSX", to: "1"),
                .unsafeFlags(["-Wno-everything"]),
            ]
        ),
        .testTarget(name: "StageMIDITests", dependencies: ["StageMIDI"]),
        .executableTarget(name: "chordpro", dependencies: ["ChordProKit"]),
        .testTarget(name: "ChordProKitTests", dependencies: ["ChordProKit"]),
    ],
    cxxLanguageStandard: .cxx17
)
