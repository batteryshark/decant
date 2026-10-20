// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "decant",
    platforms: [.macOS(.v15)],
    dependencies: [.package(path: "vendor/Whisky/WhiskyKit")],
    targets: [
        .executableTarget(
            name: "decant",
            dependencies: ["WhiskyKit"],
            // Our own bundle ID keys every WhiskyKit path, isolating us from a real Whisky install.
            linkerSettings: [.unsafeFlags([
                "-Xlinker", "-sectcreate", "-Xlinker", "__TEXT", "-Xlinker", "__info_plist", "-Xlinker", "Resources/Info.plist"
            ])]
        ),
        .executableTarget(name: "DecantApp"),
        .testTarget(name: "DecantTests", dependencies: ["decant"], path: "UnitTests")
    ],
    swiftLanguageModes: [.v6]
)
