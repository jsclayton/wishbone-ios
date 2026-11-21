// swift-tools-version: 6.4

import PackageDescription

/// What `SWIFT_APPROACHABLE_CONCURRENCY` turns on in the three targets, in Swift 6 language mode.
/// `Package.swift` has no single switch for it, so every module names the same upcoming features.
let approachableConcurrency: [SwiftSetting] = [
  .enableUpcomingFeature("InferIsolatedConformances"),
  .enableUpcomingFeature("NonisolatedNonsendingByDefault"),
]

/// The settings of a module that an app or an extension links. Every one builds with extension-only API, so a
/// call that an extension can't make, such as `UIApplication.shared`, doesn't compile.
let moduleSettings: [SwiftSetting] = approachableConcurrency + [.unsafeFlags(["-application-extension"])]

let package = Package(
  name: "WishboneKit",
  defaultLocalization: "en",
  platforms: [
    .macOS(.v27),
    .iOS(.v27),
  ],
  products: [
    .library(name: "WishboneAPI", targets: ["WishboneAPI"]),
    .library(name: "WishboneSession", targets: ["WishboneSession"]),
    .library(name: "WishboneUI", targets: ["WishboneUI"]),
    .library(name: "WishboneDiagnostics", targets: ["WishboneDiagnostics"]),
  ],
  targets: [
    .target(
      name: "WishboneAPI",
      swiftSettings: moduleSettings
    ),
    .target(
      name: "WishboneSession",
      swiftSettings: moduleSettings
    ),
    .target(
      name: "WishboneUI",
      resources: [.process("Resources")],
      swiftSettings: moduleSettings + [.defaultIsolation(MainActor.self)]
    ),
    .target(
      name: "WishboneDiagnostics",
      swiftSettings: moduleSettings
    ),
    .target(
      name: "TestSupport",
      swiftSettings: approachableConcurrency
    ),
    .testTarget(
      name: "WishboneAPITests",
      dependencies: ["WishboneAPI", "TestSupport"],
      swiftSettings: approachableConcurrency
    ),
    .testTarget(
      name: "TestSupportTests",
      dependencies: ["TestSupport"],
      swiftSettings: approachableConcurrency
    ),
    .testTarget(
      name: "FitnessTests",
      swiftSettings: approachableConcurrency
    ),
  ],
  swiftLanguageModes: [.v6]
)
