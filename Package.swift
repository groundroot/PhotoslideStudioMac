// swift-tools-version: 6.2

import PackageDescription

let package = Package(
    name: "DreamMediaSlideshowStudio",
    platforms: [
        .macOS(.v13)
    ],
    products: [
        .executable(
            name: "DreamMediaSlideshowStudio",
            targets: ["DreamMediaSlideshowStudio"]
        )
    ],
    targets: [
        .executableTarget(
            name: "DreamMediaSlideshowStudio",
            resources: [
                .process("Resources")
            ]
        ),
        .testTarget(
            name: "DreamMediaSlideshowStudioTests",
            dependencies: ["DreamMediaSlideshowStudio"]
        )
    ]
)
