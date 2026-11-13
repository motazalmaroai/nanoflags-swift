// swift-tools-version:5.9
//
// NanoFlags SDK for Apple platforms (iOS, macOS, tvOS, watchOS). The core also builds on Linux,
// where the engine parity suite, signature verification and the transports are tested.
//
// Products:
//   NanoFlags        the client (local evaluation, verified bundles, live updates, persistence,
//                    lifecycle, telemetry) plus SwiftUI helpers on Apple platforms
//   NanoFlagsEngine  the evaluation engine alone (a port of @nanoflags/engine)
//
// The OpenFeature provider is a separate package in OpenFeature/ (product NanoFlagsOpenFeature):
// the OpenFeature Swift SDK requires iOS 15 / tvOS 15 / watchOS 8 and Combine, while this package
// supports iOS 14 and Linux. See README.md.
import PackageDescription

let package = Package(
    name: "NanoFlags",
    platforms: [
        .iOS(.v14),
        .macOS(.v12),
        .tvOS(.v14),
        .watchOS(.v7),
    ],
    products: [
        .library(name: "NanoFlags", targets: ["NanoFlags"]),
        .library(name: "NanoFlagsEngine", targets: ["NanoFlagsEngine"]),
    ],
    dependencies: [
        // Ed25519 + SHA-256 off Apple platforms. On Apple platforms CryptoKit is used instead and this
        // package is never linked (see the condition below).
        .package(url: "https://github.com/apple/swift-crypto.git", "3.0.0"..<"6.0.0"),
    ],
    targets: [
        .target(name: "NanoFlagsEngine"),
        .target(
            name: "NanoFlags",
            dependencies: [
                "NanoFlagsEngine",
                .product(name: "Crypto", package: "swift-crypto", condition: .when(platforms: [.linux, .android, .windows])),
            ]
        ),
        .testTarget(name: "NanoFlagsEngineTests", dependencies: ["NanoFlagsEngine"]),
        .testTarget(
            name: "NanoFlagsTests",
            dependencies: [
                "NanoFlags",
                .product(name: "Crypto", package: "swift-crypto", condition: .when(platforms: [.linux, .android, .windows])),
            ],
            resources: [.copy("Resources")]
        ),
    ]
)
