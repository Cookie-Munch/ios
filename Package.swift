// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "CookieMunch",
    platforms: [.iOS(.v15), .macOS(.v12), .tvOS(.v15), .watchOS(.v8)],
    products: [
        .library(name: "CookieMunch", targets: ["CookieMunch"])
    ],
    targets: [
        .target(name: "CookieMunch", path: "Sources/CookieMunch"),
        .testTarget(
            name: "CookieMunchTests",
            dependencies: ["CookieMunch"],
            path: "Tests/CookieMunchTests"
        )
    ]
)
