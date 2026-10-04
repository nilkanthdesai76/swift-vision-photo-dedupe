// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "VisionPhotoDedupe",
    platforms: [
        .iOS(.v15),
        .macOS(.v12)
    ],
    products: [
        .library(
            name: "VisionPhotoDedupe",
            targets: ["VisionPhotoDedupe"]
        )
    ],
    targets: [
        .target(
            name: "VisionPhotoDedupe",
            dependencies: []
        ),
        .testTarget(
            name: "VisionPhotoDedupeTests",
            dependencies: ["VisionPhotoDedupe"]
        )
    ]
)
