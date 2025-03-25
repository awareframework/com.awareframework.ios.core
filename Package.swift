// swift-tools-version: 5.10.0
// The swift-tools-version declares the minimum version of Swift required to build this package.

import PackageDescription

let package = Package(
    name: "com.awareframework.ios.core",
    platforms: [.iOS(.v13)],
    products: [
        // Products define the executables and libraries a package produces, making them visible to other packages.
        .library(
            name: "com.awareframework.ios.core",
            targets: ["com.awareframework.ios.core"]),
    ],
    dependencies: [
        .package(url: "https://github.com/SwiftyJSON/SwiftyJSON.git", from: "5.0.2"),
        .package(url: "https://github.com/groue/GRDB.swift.git", .upToNextMinor(from: "7.3.0")),
        .package(url: "https://github.com/ashleymills/Reachability.swift.git", from: "5.2.4")
    ],
    targets: [
        .target(
            name: "com.awareframework.ios.core",
            dependencies: [
                .product(name: "SwiftyJSON", package: "SwiftyJSON"),
                .product(name: "GRDB", package: "GRDB.swift"),
                .product(name: "Reachability", package: "Reachability.swift")
            ]
        ),
        .testTarget(
            name: "com.awareframework.ios.coreTests",
            dependencies: ["com.awareframework.ios.core"]
        )
    ]
)
