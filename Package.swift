// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "Umbra",
    platforms: [.macOS(.v14)],
    products: [
        .library(name: "UmbraCore", targets: ["UmbraCore"]),
        .executable(name: "umbra", targets: ["umbra"]),
        .executable(name: "umbra-tests", targets: ["UmbraTests"])
    ],
    targets: [
        .target(name: "UmbraCore"),
        .executableTarget(name: "umbra", dependencies: ["UmbraCore"]),
        // A plain executable rather than a test target: XCTest and
        // swift-testing both need a full Xcode install to run, and this tool
        // must stay verifiable on a machine with only the Command Line Tools.
        .executableTarget(name: "UmbraTests", dependencies: ["UmbraCore"])
    ]
)
