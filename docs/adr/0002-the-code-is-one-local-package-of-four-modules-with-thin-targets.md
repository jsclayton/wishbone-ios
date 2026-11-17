---
status: accepted
---

# The code is one local package of four modules, with thin targets

The repo has one Xcode project and one local Swift package beside it. The package holds the models, the API client, the session model, and the shared UI, in four modules: `WishboneAPI`, `WishboneSession`, `WishboneUI`, and `WishboneDiagnostics`, plus `TestSupport` for tests only. The three targets (the app, the share extension, and the widget extension) are thin: an entry point, an `Info.plist`, entitlements, an asset catalog, and only what needs the app itself, such as `UIApplication.shared`.

Two extensions share code with the app, and the logic must test with `swift test` on macOS, without a simulator. A module boundary is also where a fitness test can hold what each target links.

## Considered Options

- **One app target with no package**, as the open source apps hermex and ruddarr do. Rejected. The extensions then compile the app's files one by one, and every test needs a simulator.
- **Many small modules**, as a much larger app has. Rejected. That many modules come from cutting a much larger codebase, and here they add only build settings to keep in step. A new module here is cut only when a target's link list or a macOS build needs it.

## Consequences

- Every package module builds with extension-only API.
- `WishboneAPI` and `WishboneSession` build on macOS and iOS, so their tests run under `swift test`. `WishboneUI` and `WishboneDiagnostics` are iOS only.
- Every string in the package names its bundle (`bundle: #bundle`). Without it, SwiftUI looks in the main bundle and fails with no error. A fitness test holds it.
- A fitness test holds each target's link list. Only the app links `WishboneDiagnostics`.
- The package's libraries are static, so each extension carries its own copy.
