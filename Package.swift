// swift-tools-version:6.2
import PackageDescription

// MacRest, a native front end for Backrest. Built with the Command Line Tools
// alone (no Xcode), which rules out `#Preview` and the `@State` macro (see
// `ViewState` in Theme.swift). Tools 6.2 because `.macOS(.v26)` needs it.
let package = Package(
    name: "MacRest",
    platforms: [.macOS(.v26)],
    targets: [
        // Decoding, config editing, the verdict: no AppKit, no I/O, all of it
        // under `swift test`.
        .target(name: "MacRestCore"),
        // The Backrest client and the SwiftUI app.
        .executableTarget(name: "MacRest", dependencies: ["MacRestCore"]),
        .testTarget(name: "MacRestCoreTests", dependencies: ["MacRestCore"]),
    ]
)
