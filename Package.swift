// swift-tools-version: 6.0
// decant: run Windows programs on macOS through WhiskyKit + the Whisky runtime.
// GPL-3.0-or-later (links WhiskyKit).
import PackageDescription

let package = Package(
    name: "decant",
    platforms: [.macOS(.v15)],
    dependencies: [
        // WhiskyKit pinned by git submodule commit (see README "Bumping the pin").
        .package(path: "vendor/Whisky/WhiskyKit")
    ],
    targets: [
        .executableTarget(
            name: "decant",
            dependencies: [.product(name: "WhiskyKit", package: "WhiskyKit")],
            // Embed Info.plist so Bundle.main.bundleIdentifier (and every
            // WhiskyKit path keyed on it) is ours, not com.franke.Whisky.
            linkerSettings: [.unsafeFlags([
                "-Xlinker", "-sectcreate", "-Xlinker", "__TEXT",
                "-Xlinker", "__info_plist", "-Xlinker", "Resources/Info.plist"
            ])]
        )
    ],
    swiftLanguageModes: [.v6]
)
