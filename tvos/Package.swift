// swift-tools-version: 5.9
// Copyright (C) 2026 Pilipala. SPDX-License-Identifier: GPL-3.0-only

import Foundation
import PackageDescription

let packageDir = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
let jsHostExists = FileManager.default.fileExists(
    atPath: packageDir
        .appendingPathComponent("Sources/MarcoTVCore/Resources/js-host")
        .path
)

let coreResources: [Resource] = jsHostExists
    ? [.copy("Resources/js-host")]
    : []

let package = Package(
    name: "MarcoMovieTV",
    platforms: [
        .macOS(.v13),
        .tvOS(.v16),
    ],
    products: [
        .library(
            name: "MarcoTVCore",
            targets: ["MarcoTVCore"]
        ),
        .executable(
            name: "MarcoMovieTV",
            targets: ["MarcoMovieTV"]
        ),
    ],
    targets: [
        .target(
            name: "CQuickJS",
            path: "Sources/CQuickJS",
            publicHeadersPath: "include",
            cSettings: [
                .headerSearchPath("."),
                .headerSearchPath("include"),
                .define("_GNU_SOURCE"),
                .define("CONFIG_VERSION", to: "\"ng-0.14.0\""),
                .define("NDEBUG", .when(configuration: .release)),
            ]
        ),
        .target(
            name: "MarcoTVCore",
            dependencies: ["CQuickJS"],
            path: "Sources/MarcoTVCore",
            exclude: [
                "Resources/README.md",
            ],
            resources: coreResources
        ),
        .executableTarget(
            name: "MarcoMovieTV",
            dependencies: ["MarcoTVCore"],
            path: "Sources/MarcoMovieTV"
        ),
        .testTarget(
            name: "MarcoTVCoreTests",
            dependencies: ["MarcoTVCore"],
            path: "Tests/MarcoTVCoreTests"
        ),
    ],
    cLanguageStandard: .gnu11,
    cxxLanguageStandard: .cxx17
)
