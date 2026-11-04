// swift-tools-version: 5.10
import PackageDescription

// The harness is the app's behaviour with no UI import: the hold gesture (when a held key
// starts and stops a recording), recordings and their folder store, transcript text (titles,
// Copy all, keeping your edits through a re-transcribe), settings, and what the updater
// compares. It builds and tests on Linux, so every push checks it.
let package = Package(
    name: "Harness",
    platforms: [.macOS(.v14)],
    products: [
        .library(name: "Harness", targets: ["Harness"]),
    ],
    targets: [
        .target(name: "Harness"),
        .testTarget(name: "HarnessTests", dependencies: ["Harness"]),
    ]
)
