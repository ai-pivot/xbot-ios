// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "XbotCore",
    platforms: [.macOS(.v13), .iOS(.v17)],
    products: [.library(name: "XbotCore", targets: ["XbotCore"])],
    targets: [
        .target(name: "XbotCore"),
        .testTarget(name: "XbotCoreTests", dependencies: ["XbotCore"])
    ]
)
