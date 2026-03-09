// swift-tools-version: 5.9

import PackageDescription

let package = Package(
    name: "simpleocr",
    platforms: [.macOS(.v13)],
    targets: [
        .executableTarget(
            name: "simpleocr",
            path: "Sources/simpleocr"
        ),
        .testTarget(
            name: "simpleocrTests",
            dependencies: ["simpleocr"]
        )
    ]
)
