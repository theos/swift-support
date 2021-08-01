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
        ),
        .executable(
            name: "swift-jobserver",
            targets: ["Jobserver"]
        )
    ],
    targets: [
        .target(name: "JobserverCommon"),
        .target(
            name: "SwiftcOutputParser",
            dependencies: ["JobserverCommon"]
        ),
        .testTarget(
            name: "SwiftcOutputParserTests",
            dependencies: ["SwiftcOutputParser"]
        ),
        .target(name: "FileMapGenerator"),
        .target(
            name: "Jobserver",
            dependencies: ["JobserverCommon"]
        )
    ]
)
