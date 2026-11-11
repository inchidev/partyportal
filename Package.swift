// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "partyportal",
    platforms: [.macOS(.v14)],
    targets: [
        .executableTarget(name: "partyportal", path: "Sources/partyportal"),
        .executableTarget(name: "partyportal-testwin", path: "Sources/testwin"),
        .testTarget(name: "partyportalTests", dependencies: ["partyportal"], path: "Tests/partyportalTests"),
    ]
)
