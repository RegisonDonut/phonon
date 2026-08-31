// swift-tools-version: 5.10
import PackageDescription

let package = Package(
    name: "Phonon",
    platforms: [
        .macOS(.v13)
    ],
    products: [
        .executable(name: "Phonon", targets: ["Phonon"])
    ],
    dependencies: [],
    targets: [
        .executableTarget(
            name: "Phonon",
            path: "Sources/Phonon",
            linkerSettings: [
                .linkedFramework("AppKit"),
                .linkedFramework("AVFoundation"),
                .linkedFramework("Carbon"),
                .linkedFramework("ApplicationServices")
            ]
        )
    ]
)
