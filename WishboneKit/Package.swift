// swift-tools-version: 6.4

import PackageDescription

/// What `SWIFT_APPROACHABLE_CONCURRENCY` turns on in the three targets, in Swift 6 language mode.
/// `Package.swift` has no single switch for it, so every module names the same upcoming features.
let approachableConcurrency: [SwiftSetting] = [
  .enableUpcomingFeature("InferIsolatedConformances"),
  .enableUpcomingFeature("NonisolatedNonsendingByDefault"),
]

/// The settings of every target of the package. A warning from the compiler is an error, as it is in the three
/// targets of the project (`SWIFT_TREAT_WARNINGS_AS_ERRORS`). The setting is here, and not on the command line of
/// a build, because Xcode builds a remote package such as GRDB with its warnings suppressed, and the two clash.
let everyTarget: [SwiftSetting] = approachableConcurrency + [.treatAllWarnings(as: .error)]

/// The settings of a module that an app or an extension links. Every one builds with extension-only API, so a
/// call that an extension can't make, such as `UIApplication.shared`, doesn't compile.
let moduleSettings: [SwiftSetting] = everyTarget + [.unsafeFlags(["-application-extension"])]

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
    // For the project's test bundles only. No target that ships links it: a fitness test holds each link list.
    .library(name: "TestSupport", targets: ["TestSupport"]),
  ],
  dependencies: [
    // The local database. It is pinned to an exact version, and moves only in a reviewed pull request. See ADR 0005.
    .package(url: "https://github.com/groue/GRDB.swift.git", exact: "7.12.0"),
    // Diagnostics. It is pinned to an exact version, and moves only in a reviewed pull request. See ADR 0008.
    .package(url: "https://github.com/getsentry/sentry-cocoa.git", exact: "9.34.0"),
  ],
  targets: [
    .target(
      name: "WishboneAPI",
      swiftSettings: moduleSettings
    ),
    .target(
      name: "WishboneSession",
      dependencies: ["WishboneAPI", .product(name: "GRDB", package: "GRDB.swift")],
      swiftSettings: moduleSettings
    ),
    .target(
      name: "WishboneUI",
      dependencies: ["WishboneAPI", "WishboneSession"],
      resources: [.process("Resources")],
      swiftSettings: moduleSettings + [.defaultIsolation(MainActor.self)]
    ),
    .target(
      name: "WishboneDiagnostics",
      dependencies: [.product(name: "Sentry", package: "sentry-cocoa")],
      swiftSettings: moduleSettings
    ),
    .target(
      name: "TestSupport",
      dependencies: ["WishboneAPI"],
      swiftSettings: everyTarget
    ),
    .testTarget(
      name: "WishboneAPITests",
      dependencies: ["WishboneAPI", "TestSupport"],
      swiftSettings: everyTarget
    ),
    .testTarget(
      name: "WishboneSessionTests",
      dependencies: ["WishboneAPI", "WishboneSession", "TestSupport"],
      swiftSettings: everyTarget
    ),
    .testTarget(
      name: "TestSupportTests",
      dependencies: ["TestSupport"],
      swiftSettings: everyTarget
    ),
    .testTarget(
      name: "FitnessTests",
      swiftSettings: everyTarget
    ),
  ],
  swiftLanguageModes: [.v6]
)
