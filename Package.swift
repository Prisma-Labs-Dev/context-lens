// swift-tools-version: 6.2
import PackageDescription

let package = Package(
    name: "ContextLens",
    platforms: [.macOS(.v15)],
    products: [
        .library(name: "ContextLensCore", targets: ["ContextLensCore"]),
        .executable(name: "context-lens", targets: ["context-lens"]),
    ],
    dependencies: [
        .package(url: "https://github.com/LebJe/TOMLKit.git", exact: "0.6.0"),
    ],
    targets: [
        .target(name: "ContextLensCore", dependencies: ["TOMLKit"]),
        .executableTarget(name: "context-lens", dependencies: ["ContextLensCore"]),
        .testTarget(name: "ContextLensCoreTests", dependencies: ["ContextLensCore"]),
    ]
)
