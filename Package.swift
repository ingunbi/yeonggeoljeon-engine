// swift-tools-version: 5.9
// SPDX-License-Identifier: GPL-3.0-only
import PackageDescription

let package = Package(
    name: "YeonggeoljeonEngine",
    platforms: [.macOS(.v13)],
    products: [.executable(name: "yeonggeoljeon-engine", targets: ["YeonggeoljeonEngine"])],
    targets: [
        .executableTarget(name: "YeonggeoljeonEngine", linkerSettings: [.linkedFramework("AppKit")])
    ]
)
