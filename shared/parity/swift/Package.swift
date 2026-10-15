// swift-tools-version:6.0
import PackageDescription

let package = Package(
    name: "parity-swift",
    platforms: [.macOS(.v13)],
    dependencies: [
        .package(url: "https://github.com/swiftlang/swift-syntax.git", exact: "604.0.0"),
    ],
    targets: [
        .executableTarget(
            name: "parity-swift",
            dependencies: [
                .product(name: "SwiftSyntax", package: "swift-syntax"),
                .product(name: "SwiftParser", package: "swift-syntax"),
            ]
        ),
    ]
)
