// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "ChordProKit",
    platforms: [.macOS(.v13), .iOS(.v15)],
    products: [
        .library(name: "ChordProKit", targets: ["ChordProKit"]),
        .library(name: "StageMIDI", targets: ["StageMIDI"]),
        .executable(name: "chordpro", targets: ["chordpro"]),
    ],
    targets: [
        .target(name: "ChordProKit"),
        .target(name: "StageMIDI"),
        .testTarget(name: "StageMIDITests", dependencies: ["StageMIDI"]),
        .executableTarget(name: "chordpro", dependencies: ["ChordProKit"]),
        .testTarget(name: "ChordProKitTests", dependencies: ["ChordProKit"]),
    ]
)
