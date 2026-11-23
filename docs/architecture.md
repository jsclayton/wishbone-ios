# Architecture

Where each rule lives in the code, and the rules that hold the code together. What the app does is in the [spec](spec.md). Why the big choices were made is in the [ADRs](adr/README.md).

## The project

- One Xcode project and one local Swift package beside it (see [ADR 0002](adr/0002-the-code-is-one-local-package-of-four-modules-with-thin-targets.md)).
- The project uses synchronized folders, so a new file needs no edit to the project file. Shared schemes are in git.
- The three targets (the app, the share extension, and the widget extension) are thin: an entry point, an `Info.plist`, entitlements, an asset catalog, and only what needs the app itself.
- Every target takes its build settings from `Config/Shared.xcconfig`. The project file holds no signing values. See [Signing and build settings](development.md#signing-and-build-settings).

## Modules

| Module | Holds | Builds on | Linked by |
|---|---|---|---|
| `WishboneAPI` | The Codable models, the API client, the error codes, the session keychain and the install marker, the version check against `GET /health`, the one `Logger` file, and the diagnostics vocabulary with its reporter protocol | macOS and iOS | the app, the share extension, the widget |
| `WishboneSession` | The session model, the local database (GRDB) with the unsent changes and the sync, the server's shift rule for a move, and the reminder plan | macOS and iOS | the app, the share extension |
| `WishboneUI` | Every screen and component (the add form included), the one String Catalog, the person palette, the words for each error code, and the markdown renderer | iOS | the app, the share extension |
| `WishboneDiagnostics` | The one file that imports Sentry, the switch, the reporter, and the scrubber | iOS | the app only |
| `TestSupport` | The server harness, `ScratchDirectory`, the network conditioner, the fixture builder, and fakes | macOS and iOS | test targets only |

- Every package module builds with extension-only API. Anything that needs `UIApplication.shared` stays in the app target.
- The widget extension links only `WishboneAPI`. It never links `WishboneSession` or GRDB, and `WishboneUI` imports `WishboneSession`.
- A fitness test holds each target's link list, and each test bundle's.
- A new module is cut only when a target's link list, or a macOS build, needs it.

## Where the other pieces live

| Piece | Lives in | Notes |
|---|---|---|
| The reminder plan | `WishboneSession` | Pure: occasions, settings, and a clock in, and requests out. The notification center is behind a protocol: the app gives `UNUserNotificationCenter`'s, and every other device gets one that never schedules. The session model rebuilds the set after each sync that succeeded and after the profile gate, and the device removes every reminder when it has no session. The words come from the String Catalog in `WishboneUI`, which the app gives. The session keeps its reminder settings in a file of their own in its folder, outside the copy's tables, so a drop of the copy keeps them and sign-out removes them. |
| Background refresh and scheduling | The app target | Only the app registers `.backgroundTask(.appRefresh)`, permits its identifier, and has the `fetch` background mode. The extensions never schedule. When to ask is in `WishboneSession`: the session model asks for the next run when the app goes to the background and at the end of each run, and the device cancels it at sign-out and at the API's own 401. iOS's scheduler is behind a protocol: the app gives `BGTaskScheduler`'s, and every other device gets one that never schedules. A run is one Sync now, and the end of a run that iOS cuts short cancels it. |
| The journal of unsent changes | `WishboneSession` (`Journal.swift`, `UnsentChanges.swift`) | In the session's database, beside the copy, in tables of its own with their own migrator, which never erases the database. The copy's schema number never drops them. The snapshot applies each unsent change over its row, so screens show it at once and a pull doesn't undo it. A sync sends the changes first, one at a time and in order, then pulls. A refusal leaves the journal for a table of late refusals, which the next window to come to the foreground shows once. |
| When a sync starts | `WishboneSession` | The session model's Sync now runs one sync at a time, and every way that a sync starts calls it. A write that waits for the server and puts its answer into the copy while a sync runs asks for one more sync after it, because that sync may have asked before the write and can undo it in the copy (`syncAgainIfSyncing()`). The 60-second timer runs on its own injected clock. The network's changes are behind a protocol: the app gives the system's, and every other device gets one that never changes. |
| Each window's foreground, and pull to refresh | `WishboneUI` | The window's root tells the session model when its scene comes to the foreground and leaves it. The tab frame attaches pull to refresh once, for every screen that scrolls. |
| The device owner check, and the login link's Copy (this device only, 10 minutes) | `WishboneUI` | Reached only from the app's screens. |
| The drag type | `WishboneUI` | The in-app reference carries the session's instance and user, so a drop from another session is refused. Other apps get a URL and a title. |
| The window closing confirmation, and Open in New Window | The app target | They need the window scene. The restore of each window's place (`@SceneStorage`) is in `WishboneUI`'s root. |
| The storefront check for the support row | The app target's UI | The one file that imports StoreKit. Never in an extension. |
| The widget's file | `WishboneSession` writes it, the widget reads it | A JSON file of occasions only, in the shared container. |
| The image cache | `WishboneSession` (`ImageCache`), shown by `WishboneUI`'s `SessionImage` | One for each session model, in memory and in a folder for the instance and user under the app's own Caches folder, never the shared container. The API client loads its images, with the token and no redirect, and never reports a failed load. The session model fetches ahead after each sync that succeeded, and asks the network's protocol whether it is expensive or constrained. The device removes the folder where it removes the database. |
| The accent color | Each thin target's `AccentColor` | A test holds the three equal. |
| The pinned test server | `WishboneKit/Server/` | The pin file and the copy of the server's OpenAPI document. The contract test holds them against `minimumServerVersion` in `WishboneAPI`. See [A real server](development.md#a-real-server). |
| Permission strings | Each target's `InfoPlist.xcstrings` | |
| The license texts of Acknowledgements | `WishboneUI`'s resources, as `Acknowledgements.json` | `just build` makes the file from the pinned packages, and the file is in git. See [What the build writes](development.md#what-the-build-writes). |

## State: the session model

See [ADR 0003](adr/0003-one-session-model-is-shared-by-every-window-with-no-view-models.md), [ADR 0005](adr/0005-grdb-is-the-local-database-and-screens-read-only-it.md), and [ADR 0006](adr/0006-writes-are-a-journal-of-unsent-changes-the-server-decides-and-claims-are-online-only.md).

- There are no view models. A screen keeps its own `@State`.
- One `Device` for the app, `@Observable` and `@MainActor`. It holds one session at most: it signs in with a login link, publishes what the signed-out screen shows, and holds the session model while it is signed in. The app's composition root builds it once, and puts it in the environment of every window scene.
- One `SessionModel` for each signed-in session, `@Observable` and `@MainActor`. The `Device` builds it at sign-in, and at launch from the session keychain. Every window reads the same one.
- The session model owns the local database. Screens read only the database, through the session model, and never call the API client.
- Every write goes through the session model: it records the change, applies it to the copy, and sends it. A claim and a raise of a gift's quantity wait for the server instead.
- Sign-out, or the API's own 401, discards the session model, the database, and its unsent changes.
- The share extension builds its own session model, with a database in memory.
- "Store" means a shop, as in the server's **store link** and **blocked store**. It never names state in code or docs.

## The API client

See [ADR 0004](adr/0004-the-api-client-is-written-by-hand-and-checked-against-a-pinned-copy-of-the-servers-openapi-document.md).

- One `APIClient` on `URLSession`, not `@MainActor`, built from the session's instance address and token.
- Every request goes through one private load: the user agent, the redaction of logs, the strict test for the API's own 401 and 410, the one resend of a write that is safe to repeat after a lost connection, and the rule for an unreachable instance.
- Endpoints are typed values (method, path template, query, and body), so a test can list every route the app calls.
- Models ignore unknown keys. Every enum has an `unknown(String)` case. A field that can be hidden keeps "absent" apart from `null` where it matters.
- Error codes are one open enum, with `unknown(String)`.
- Collections always follow `next_cursor`.
- A resource comes with its version: the `ETag` of its own `GET`, or its `version` as a row of a collection. Only `GET /versions` sends `If-None-Match`, and its request never has a query.
- The token goes only to the instance address, and only on a route that needs a session. The client follows no redirect. A store's image loads with no token.
- Family content in a log line (names, titles, notes, addresses) is always `.private`.

## Concurrency

- Swift 6 language mode, with complete strict concurrency.
- Approachable concurrency: `SWIFT_APPROACHABLE_CONCURRENCY` in the targets. `Package.swift` has no single switch, so the package modules turn on the same upcoming features one by one.
- Default isolation: `MainActor` in the three targets and `WishboneUI`. `nonisolated` in `WishboneAPI` and `WishboneSession`, where `SessionModel` is marked `@MainActor` and the API client is not.

The checklist:

- The client's sign-in state is all `let`, so its methods are `nonisolated`.
- JSON goes through one `@concurrent` helper, never on the main actor.
- Every model is `Sendable`.
- Use `Mutex`, not `@unchecked Sendable`. Each `@unchecked Sendable` that remains says why it is safe.
- Use `.task`, not `Task {}` in `.onAppear`.
- Every timeout goes through one helper, on an injected clock.

## Dependencies

- The shipped app has two third-party dependencies: sentry-cocoa and GRDB. Each is pinned to an exact version, and moves only in a reviewed pull request. `Package.resolved` is in git.
- Any other dependency needs an ADR that says why Apple's frameworks can't do the job.
- Apple's frameworks do the rest: the session's own image cache on the API client's `URLSession` for the instance's images, `AsyncImage` with the system's default cache for a store's image, Security for the Keychain, VisionKit for scanning QR codes, Core Image for making them, and the app's own small renderer for the web's markdown subset.

## Strings

- Every UI string is in the one String Catalog in `WishboneUI`, or in a target's `InfoPlist.xcstrings`.
- Every string in the package names its bundle (`bundle: #bundle`). Without it, SwiftUI looks in the main bundle and fails with no error.
- The rules for writing strings are in [`CONTRIBUTING.md`](../CONTRIBUTING.md#strings).

## Diagnostics

See [ADR 0008](adr/0008-diagnostics-go-to-sentry-on-by-default-with-notice-and-send-only-what-the-app-names.md) and the [spec](spec.md#11-diagnostics).

- One file imports Sentry, in `WishboneDiagnostics`. Only the app target links it.
- Everything sent is a case of one event type, from a closed vocabulary. No free-form strings, and an error goes as its domain and code, never its message.
- The vocabulary is in `WishboneAPI` (`DiagnosticsVocabulary.swift`): the one event type `Fault`, the typed `Breadcrumb`, and the `DiagnosticsReporter` protocol. It is there because the modules that the extensions link name a fault where it happens. Only `WishboneDiagnostics` turns a value into what leaves the device.
- The app gives its `Device` the reporter of `WishboneDiagnostics`, and the windows get it from the environment. An extension gives none (`.none`), so it sends nothing. The reporter records nothing while the SDK doesn't run.
- **Every new error type picks its side:** captured, a breadcrumb, or never. An error type of the app conforms to `Diagnosed`, whose `diagnosticSide` writes the choice where the type is defined. A fitness test holds this. Add the case to the vocabulary if it is captured.
- The API client reports in its one load: a breadcrumb for each request, and each error as its side asks. The local database captures a file that will not open, and a copy that the schema number drops.
- A request is reported by method and path template only, from an allow list (`Breadcrumb.pathTemplates`). A fitness test holds every route to it.
- Every event is tagged with the instance's Wishbone version, from the last `GET /health`. The reporter keeps it in the app's own defaults, so the next launch tags its events before it reads `/health` again. Sign-out clears it.
- The scrubber runs in `beforeSend` and `beforeBreadcrumb`, and is tested at the envelope. It holds each event and breadcrumb to the vocabulary first, and drops the runtime's free text (an exception's value, a thread's name, the extra). Then it strips tokens, login links, hosts, and addresses from every string that is left.
- The app's privacy manifest declares the collected data types. A fitness test holds them to exactly what `DiagnosticsReport` can send.

## Secrecy

See the [spec](spec.md#7-secrecy-on-the-device).

- **Every new system surface joins the secrecy suite.** The suite builds each system surface's payload from the synced copy, and checks that its fields equal an allow list exactly.
- Nothing that holds claim state goes into the app group's shared container.
- Nothing sets an app icon badge. A fitness scan holds this.

## Fitness tests

These tests hold the rules above. They run in `just gate`.

- Each target's link list, and the app as the only linker of `WishboneDiagnostics`.
- One import of Sentry, and one import of StoreKit.
- `bundle: #bundle` on every string in the package.
- The three `AccentColor` assets are equal.
- No `temporaryDirectory`, `NSTemporaryDirectory(`, or `mkdtemp(` outside `ScratchDirectory`.
- No app icon badge.
- The app icon is the layered icon in the app target, with a light and a dark fill.
- No `Text(verbatim:)`, `String(format:)`, or text joined into UI strings outside a short allow list. The String Catalog has no stale entry and no key without English.
- The app's privacy manifest against the diagnostics vocabulary, and every route's path template against the allow list.
- Every error type of the app's code conforms to `Diagnosed`, so it names its side.
- Every write to the local database goes through one function, which drops the kept `ETag` of `GET /versions` in the same change. A write only of the blocked stores keeps it, because `GET /versions` doesn't cover them.
- The local copy's schema number against what the copy keeps: its tables, its rows, and the values in them. A change to any of them fails until the number rises.
