// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "Amcu",
    platforms: [.macOS(.v14)],
    products: [
        .library(name: "AmcuCore", targets: ["AmcuCore"]),
        .executable(name: "amcu", targets: ["amcu"]),
        .executable(name: "amcu-tests", targets: ["AmcuTests"])
    ],
    targets: [
        .target(name: "AmcuCore"),
        .executableTarget(name: "amcu", dependencies: ["AmcuCore"]),
        // A plain executable rather than a test target: XCTest and
        // swift-testing both need a full Xcode install to run, and this tool
        // must stay verifiable on a machine with only the Command Line Tools.
        .executableTarget(name: "AmcuTests", dependencies: ["AmcuCore"])
    ]
)
