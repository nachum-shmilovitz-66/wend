// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "Wend",
    platforms: [
        .macOS(.v13)
    ],
    products: [
        .library(name: "KeyLayoutCore", targets: ["KeyLayoutCore"]),
        .executable(name: "Wend", targets: ["Wend"]),
    ],
    targets: [
        // Pure-Swift, platform-agnostic conversion + detection logic.
        // No AppKit / no Foundation-platform deps -> ports to Windows later.
        .target(
            name: "KeyLayoutCore"
        ),
        // macOS menu-bar app: platform shims (TIS/UCKeyTranslate, NSSpellChecker,
        // clipboard, hotkey, accessibility) + UI.
        .executableTarget(
            name: "Wend",
            dependencies: ["KeyLayoutCore"]
        ),
        .testTarget(
            name: "KeyLayoutCoreTests",
            dependencies: ["KeyLayoutCore"]
        ),
    ],
    swiftLanguageModes: [.v5]
)
