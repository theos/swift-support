// swift-tools-version:5.0

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
        )
    ],
    dependencies: [
        .package(path: "orion")
    ],
    targets: [
        .target(name: "SwiftcOutputParser"),
        .testTarget(
            name: "SwiftcOutputParserTests",
            dependencies: ["SwiftcOutputParser"]
        ),
        .target(name: "FileMapGenerator"),
    ]
)
