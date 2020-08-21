// swift-tools-version:5.2
// The swift-tools-version declares the minimum version of Swift required to build this package.

import PackageDescription

let package = Package(
    name: "SwiftSupport",
    products: [
        .executable(
            name: "parse-swiftc-output",
            targets: ["SwiftcOutputParser"]
        ),
        .executable(
            name: "generate-output-file-map",
            targets: ["FileMapGenerator"]
        ),
    ],
    dependencies: [],
    targets: [
        .target(name: "SwiftcOutputParser"),
        .testTarget(
            name: "SwiftcOutputParserTests",
            dependencies: ["SwiftcOutputParser"]
        ),
        .target(name: "FileMapGenerator"),
    ]
)
