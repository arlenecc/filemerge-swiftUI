// swift-tools-version:6.0
import PackageDescription

let swiftV5: [SwiftSetting] = [.swiftLanguageMode(.v5)]

let package = Package(
    name: "FileMerge",
    platforms: [.macOS(.v13)],
    products: [
        .executable(name: "FileMergeApp", targets: ["FileMergeApp"]),
        .library(name: "FileMergeCore", targets: ["FileMergeCore"]),
        .library(name: "FileMergeUI", targets: ["FileMergeUI"]),
    ],
    targets: [
        .target(name: "FileMergeCore", swiftSettings: swiftV5),
        .target(name: "FileMergeUI", dependencies: ["FileMergeCore"], swiftSettings: swiftV5),
        .executableTarget(name: "FileMergeApp", dependencies: ["FileMergeUI"], swiftSettings: swiftV5),
        .testTarget(name: "FileMergeCoreTests", dependencies: ["FileMergeCore"], swiftSettings: swiftV5),
        .testTarget(name: "FileMergeUITests", dependencies: ["FileMergeUI"], swiftSettings: swiftV5),
    ]
)
