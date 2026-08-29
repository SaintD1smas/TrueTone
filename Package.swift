// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "TrueTone",
    platforms: [.macOS(.v14)],
    targets: [
        .executableTarget(
            name: "ttprobe",
            linkerSettings: [
                .linkedFramework("IOKit"),
                .linkedFramework("CoreGraphics"),
                .linkedFramework("Foundation"),
            ]
        )
    ]
)
