// swift-tools-version: 6.0
import PackageDescription

// One Core, two apps. The macOS app and the Windows app are separate executables over the
// same KeyLayoutCore, and neither one's sources can be compiled by the other's host — AppKit
// doesn't exist on Windows, WinSDK doesn't exist on macOS. SwiftPM has no per-target platform
// filter that skips compilation, so the manifest picks the app by host OS instead. The manifest
// itself runs on the host, which is what makes `#if os(...)` work here.
#if os(Windows)
let appProduct = Product.executable(name: "Wend", targets: ["WendWin"])
let appTargets: [Target] = [
    // The Windows spell-check API is COM-only. Driving a COM vtable from Swift is possible but
    // brittle; C behind a flat interface is the smaller, more legible surface.
    .target(name: "CWinSpell"),
    // UI Automation is COM-only for the same reason, and gets the same treatment: it answers
    // whether the focused element is a password field, which the Win32 style bit cannot do for
    // a browser or an Electron app.
    .target(name: "CWinUIA"),
    // Windows tray app: platform shims (GetKeyboardLayoutList/ToUnicodeEx, ISpellChecker,
    // IUIAutomation, clipboard, low-level keyboard hook) + UI.
    .executableTarget(
        name: "WendWin",
        dependencies: ["KeyLayoutCore", "CWinSpell", "CWinUIA"],
        linkerSettings: [
            .linkedLibrary("User32"),
            .linkedLibrary("Shell32"),
            .linkedLibrary("Ole32"),
            .linkedLibrary("Advapi32"),
            // A tray app has no console. /SUBSYSTEM:WINDOWS suppresses the console window a
            // SwiftPM executable would otherwise pop on every launch; mainCRTStartup keeps the
            // ordinary `main` entry point that main.swift compiles to. `--dump-layouts` gets a
            // console back by reattaching to the parent at runtime — see main.swift.
            .unsafeFlags(["-Xlinker", "/SUBSYSTEM:WINDOWS", "-Xlinker", "/ENTRY:mainCRTStartup"]),
        ]
    ),
]
#else
let appProduct = Product.executable(name: "Wend", targets: ["Wend"])
let appTargets: [Target] = [
    // macOS menu-bar app: platform shims (TIS/UCKeyTranslate, NSSpellChecker,
    // clipboard, hotkey, accessibility) + UI.
    .executableTarget(
        name: "Wend",
        dependencies: ["KeyLayoutCore"]
    ),
]
#endif

let package = Package(
    name: "Wend",
    platforms: [
        .macOS(.v13)
    ],
    products: [
        .library(name: "KeyLayoutCore", targets: ["KeyLayoutCore"]),
        appProduct,
    ],
    targets: [
        // Pure-Swift, platform-agnostic conversion + detection logic.
        // No AppKit / no Foundation-platform deps -> shared by both apps.
        .target(
            name: "KeyLayoutCore"
        ),
        .testTarget(
            name: "KeyLayoutCoreTests",
            dependencies: ["KeyLayoutCore"]
        ),
    ] + appTargets,
    swiftLanguageModes: [.v5]
)
