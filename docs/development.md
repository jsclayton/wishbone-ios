# Development

## Prerequisites

- A Mac with the Xcode version that the project pins: Xcode 27.2, with Swift 6.4.
- [mise](https://mise.jdx.dev), activated in your shell. `mise.toml` pins Node, pnpm, just, Go, actionlint, and shellcheck.
- Go builds the Wishbone server that the tests run against. You don't need to clone the server: the tests fetch and build it themselves.

## First run

```bash
mise trust
mise install
pnpm install     # installs the git hooks (lefthook and commitlint)
```

Then open `Wishbone.xcodeproj` in Xcode, pick a simulator, and run. A simulator build needs no signing team.

To use the app, you need a Wishbone server and a login link. The quickest way is a server on your Mac: follow the server's [development guide](https://github.com/jsclayton/wishbone/blob/main/docs/development.md), make the first user, then make a login link and paste it into the app. The app accepts a plain-HTTP address such as `http://localhost:8080`.

## Signing and build settings

Every target takes its build settings from `Config/Shared.xcconfig`, which is in git. Its last line is `#include? "Local.xcconfig"`, so `Config/Local.xcconfig` overrides it. Git ignores `Config/Local.xcconfig`.

| Setting | In `Shared.xcconfig` | What it does |
|---|---|---|
| `DEVELOPMENT_TEAM` | The maintainer's team | The team that signs the app |
| `WISHBONE_BUNDLE_PREFIX` | `com.codemonkeylabs.wishbone` | Every identifier comes from it (see below) |
| `CODE_SIGN_STYLE` | `Automatic` | |
| `WISHBONE_SENTRY_DSN` | Empty | Where diagnostics go. Empty means that diagnostics never start |
| `WISHBONE_SOURCE_URL` | This repo | The "Source code" row in Settings |
| `WISHBONE_PRIVACY_URL` | This repo's `PRIVACY.md` on GitHub | The privacy policy link on the Share diagnostics screen |
| `WISHBONE_SUPPORT_URL` | The maintainer's Buy Me a Coffee page | The support row in Settings. Empty means no row |
| `CURRENT_PROJECT_VERSION` | `1` | Local builds are build 1, so diagnostics can tell them from release builds |

The identifiers that come from `WISHBONE_BUNDLE_PREFIX`:

| What | Identifier |
|---|---|
| The app | `$(WISHBONE_BUNDLE_PREFIX)` |
| The share extension | `$(WISHBONE_BUNDLE_PREFIX).share` |
| The widget extension | `$(WISHBONE_BUNDLE_PREFIX).widget` |
| The app group | `group.$(WISHBONE_BUNDLE_PREFIX)` |
| The Keychain access group | `$(AppIdentifierPrefix)$(WISHBONE_BUNDLE_PREFIX)` |

The settings reach the code through `Info.plist` keys, such as `WishboneSentryDSN = $(WISHBONE_SENTRY_DSN)`.

### Build for your own device

The maintainer's team has registered every identifier under `com.codemonkeylabs.wishbone`, so another team can't sign with them. To run the app on your own iPhone or iPad:

1. Create `Config/Local.xcconfig`.
2. Put your team and your own prefix in it:

   ```xcconfig
   DEVELOPMENT_TEAM = ABCDE12345
   WISHBONE_BUNDLE_PREFIX = com.example.wishbone
   ```

3. Build and run on your device.

Don't set `WISHBONE_SENTRY_DSN`: keep it empty, so your build sends no diagnostics. To give a build to other people, also read [`TRADEMARKS.md`](../TRADEMARKS.md).

An xcconfig file treats `//` as the start of a comment. To write a URL in one, split the slashes: `https:/$()/example.com`.

## Recipes

`just --list` shows every recipe. The main ones:

| Recipe | What it does |
|---|---|
| `just gate` | Every check that a pull request must pass, in order (see [The gate](#the-gate)) |
| `just build` | Builds the app and both extensions for the simulator, with zero warnings, and adds new strings to the String Catalog |
| `just server` | Fetches and builds the pinned Wishbone server that the tests run against, or reuses the built one |
| `just test` | The package tests on macOS, with `swift test`. It runs `just server` first |
| `just lint` | `swift-format lint --strict`, actionlint and shellcheck, the docs check, and the tests of the gate's own scripts |
| `just fmt` | Formats the Swift files with swift-format |

To run one package test:

```bash
swift test --package-path WishboneKit --filter TestName
```

## Repo layout

```
Wishbone/           The app target
ShareExtension/     The share extension
WidgetExtension/    The widget extension: the countdown widget and the Add item control
WishboneKit/        The local Swift package: the modules (see architecture.md) and their tests
Config/             Shared.xcconfig, and your own Local.xcconfig
AppStore/           The App Store listing, as files
scripts/            The scripts that the recipes run
docs/               The spec, the ADRs, and the guides
```

[`architecture.md`](architecture.md) says what each module holds and where each rule lives.

## Formatting and lint

- swift-format comes with Xcode. `.swift-format` holds its settings: 2-space indents, 120 columns, ordered imports, `///` doc comments, trailing commas in multi-line collections, and at most one blank line.
- `just fmt` formats in place. `just lint` reports and changes nothing.
- The pre-commit hook runs `swift-format lint --strict` on the staged Swift files. It reports, and never rewrites them.
- There is no SwiftLint. A rule that swift-format can't hold is a fitness test (see [Fitness tests](architecture.md#fitness-tests)).

## Tests and the gate

### What to test, and where

- **The session model is the one seam for behavior.** A test calls its public actions (sign in, add, move, mark bought, sync, sign out), and checks what it publishes: the rows that screens read, the reminders that it hands to the notification center, and the widget's file.
- The API is on the far side, at the network edge, so the client's encoding and decoding are tested too.
- Pure parts with their own interface, such as the reminder plan and the shift rule, are tested directly.
- Don't test the API client on its own (beyond the contract test), private helpers, or screens.
- Where a test goes:
  - A test that needs only the package goes in the package, and runs under `swift test` on macOS, with a database in memory and the injected clock.
  - A test that needs iOS goes in the hosted test bundle: the session keychain item and its access group, the widget's file in the shared container, and `WishboneUI` pieces with logic, such as the person palette and the words for each error code.
  - A test of the whole app is a journey (see below).
- There is one test target for each module, and one for the fitness tests.

### A real server

- The session model's tests run against a real Wishbone server, built from a pinned commit (see [ADR 0007](adr/0007-the-tests-run-against-a-real-wishbone-server-built-from-a-pinned-commit.md)).
- One file holds the pinned commit, beside the copy of the server's OpenAPI document and the app's minimum server version. All three change together, in one commit. The file's name starts with `server-pin`: CI finds it by that name.
  - `WishboneKit/Server/server-pin.json` is the pin: the server's release tag, and that tag's commit.
  - `WishboneKit/Server/openapi.json` is the copy.
  - `minimumServerVersion` in `WishboneAPI` is the minimum server version.
- A script fetches the pinned commit over HTTPS, builds it with `-tags e2e`, and stamps its version. An unstamped build reports `dev`, which the app's version check refuses. Go's version comes from that commit's `go.mod`, through mise. The built server is reused until the pin moves.
  - `just server` runs the script. `just test` and the gate run it first.
  - The fetch fails if the tag is no longer at the pin's commit.
  - The script uses none of your git settings, so the fetch never needs an SSH key.
- A test that needs the server fails, never skips, when Go or the server is missing. A test that you run with `swift test`, or in Xcode, needs `just server` first.
- The contract test holds the three together: the copy is the document that the pinned server serves, and the pinned server reports the minimum server version.

To move the pin:

1. Put the new release tag and its commit in the pin file.
2. Run `just server-openapi`. It builds the server, and takes the copy again.
3. Set `minimumServerVersion`, and the number in [the spec](spec.md#the-minimum-server-version) and in the README.
4. Commit all of it together.

### Servers in parallel

- Each test process shares one server, because each test seeds its own family. A test that needs its own instance (an empty one, sign-in from setup, an LLM fixture, a low rate limit) starts a private server.
- Every test server gets a free port, and a fresh data folder under the run's own temporary root. Nothing is fixed, so two checkouts and CI never collide.
- Every test server runs with `TZ=UTC`, a high `WISHBONE_RATE_LIMIT_REDEEM`, `WISHBONE_E2E_HOOKS=true`, and `WISHBONE_EXTRACT_ALLOW_PRIVATE=true`.
- The package tests run in parallel. The simulator tests run one at a time.

### Temporary folders: ScratchDirectory

- `ScratchDirectory` in `TestSupport` is the one place where a test names a temporary folder. A fitness test bans `temporaryDirectory`, `NSTemporaryDirectory(`, and `mkdtemp(` everywhere else.
- Each test process has one root. A folder is removed when its last holder goes, and the root is removed when the process exits. At the next start, the roots of dead processes are removed.
- Each server's data folder is under that root, with its process ID beside it. A server stops when its holder goes, and when its test process exits. The sweep at start-up stops a server whose test process is dead before it removes the root, so a crashed run cleans up too.
- The built server and its source live in the checkout's build folder, under `build/server/`, one for each pin. Moving the pin deletes the old one.

### What a real server can't do: the network conditioner

- Use the real server wherever it can do the job: a 401 (revoke the session), a 403 `user_deactivated`, a 422 `store_blocked`, `found: false`, the LLM through a fixture endpoint, the hourly 429, and a late refusal.
- For the rest, the network conditioner in `TestSupport` passes every request through to the real server, unless a test tells it otherwise. A test can make it:
  - drop everything (offline)
  - hold a matching request until the test releases it (an answer in flight that races a pull)
  - answer a matching route with a canned response (a 5xx, a 410 `api_version_removed`, or a `/health` below the minimum version)
- The conditioner is a small HTTP server on your Mac, in front of the test server. A test gives the conditioner's address to the code under test as its instance address, so the code needs no seam of its own.
- A hold is at the answer by default: the request reaches the server at once, and the answer waits. A hold at the request keeps the request from the server until the release. A test waits for the hold to catch a request, never for a length of time.

### Fixtures: the standard family

- The fixture builder in `TestSupport` seeds only through the API, as the admin. The admin makes the users and a login link for each. What only a user can do, such as making a list or claiming an item, the builder does through that user's own session.
- One call seeds the **standard family**: a parent with an active child and a deactivated child (with lists, a list shared with another recipient, a pending invitation, and a given gift), the admin, a user seen only through the admin's access, nested groups, a shared occasion on groups and one marked Everyone, and a blocked store. Deletion requests join it when the pinned server has them.
- Names are unique for each test, and come back as typed handles. Each person can sign in as their own bearer session.
- Small builder calls add anything special. A test that needs less seeds less. Reveal goes through the server's test hook.
- There is no checked-in database, and no snapshot of server state.

### The simulator tier

- The simulator tests run one at a time, on the gate's own simulator: the hosted test bundle, then a few XCUITest journeys against a real test server.
- A journey launches with a login link passed in as if pasted. The journeys are: sign in, add an item, claim and mark bought as a giver, move an item between lists, add from the share extension, and sign out.
- Journeys check that things work, not how they look. **There are no snapshot comparisons.** Each journey attaches screenshots as evidence for a person to look at, never as pass or fail.
- Journeys never swipe or drag, except one drag test. Every action goes through its button or menu item, which proves that the route exists.

### Accessibility checks

- Every journey runs `performAccessibilityAudit` on each screen it reaches, in four settings: the default, the largest accessibility text size, dark mode, and Increase Contrast. Any issue fails. An exception is allowed one at a time, in code, with a reason.
- A unit test checks the accent color and every person color against their backgrounds, in light, dark, and Increase Contrast: 4.5:1 for text, and 3:1 for large text and controls.
- A test can't show whether VoiceOver and Voice Control make the common tasks possible. A person checks that on a device before each release that claims an accessibility label.

### Strings

- A fitness scan bans `Text(verbatim:)`, `String(format:)`, and text joined into UI strings, outside a short allow list.
- The String Catalog has no stale entry and no key without English.
- Each build adds new strings from the code to the catalog. So the gate fails if the build changed any `.xcstrings` file: build, and commit the catalog.

### The secrecy suite

- One suite, at the session model's seam. Its fixture user is both a recipient (others have claimed items on their lists) and a giver (open gifts with notes and from labels).
- It builds every system surface's payload from the synced copy: the widget's file, the reminders, an item dragged out, and the share extension's target lists.
- The fields of each payload must **equal an allow list exactly**. A new field fails until someone adds it on purpose.
- A second net: no payload's text holds a value from the fixture's gifts (IDs, notes, from labels, and the names of givers on claims).
- A new system surface joins the suite when it is built.

### The gate

`just gate` runs every check that a pull request must pass. Each step has a time limit, and the first failure stops the gate:

1. **Lint:** `swift-format lint --strict`, and the rest of `just lint`.
2. **Server:** builds the pinned test server, or reuses the built one.
3. **Package:** `swift test` on macOS, in parallel: the contract test, the fitness tests, the session model, the secrecy suite, and the pure units.
4. **Build:** the app, the share extension, and the widget for the simulator, with zero warnings. Then the check that the String Catalog didn't change.
5. **Simulator:** the hosted test bundle and the journeys, one at a time, on the gate's own simulator. The result bundles stay inside the checkout.

The gate reads its own results:

- It counts the tests from Swift Testing's summary for each test target, from XCTest's summary for an XCTest test in the package, and from each result bundle.
- It fails on any failure or recorded issue, on a bundle with 0 tests, and on a skip that is not on a short named list.
- A known issue is a recorded issue, so it fails too.
- An issue recorded with the severity `.warning` (`Issue.record(_:severity:)`) is not a failure, so the gate passes it. Swift Testing leaves a warning out of the event stream that the gate reads.
- A test that cancels itself with `Test.cancel`, or that has a case cancelled, is a skip. So is an XCTest test that throws `XCTSkip`.
- It fails when a count falls below the **floor**: the counts (package, hosted, and UI) in a small file in git, `scripts/gate/floor.json`. A change that adds tests can raise the floor. A commit that lowers it must say why.
- The named list of skips is `allowedSkips` in `scripts/gate/main.mjs`. Each entry has a comment that says why.
- It ends with one line, for example `GATE PASS package=412 hosted=38 ui=7 · 4m12s`, or `GATE FAIL step 3 (package): 2 failed`, then the names of the failed tests. A pull request quotes that line.
- A gate that passes names each step that it skipped in that line.

What "zero warnings" means in the build step:

- The compiler treats every warning as an error, in the targets and in the package (`SWIFT_TREAT_WARNINGS_AS_ERRORS`). So a warning from the compiler fails every build until it is fixed.
- The build's log must have no other `warning:` line. These come from what the compiler doesn't own: the linker, the asset catalogs, and the project.
- One line is left out: `Metadata extraction skipped`, from Xcode's App Intents step. It is that step's own log for a target with no App Intents, not a warning about the code.
- Xcode prints a warning from the linker, the asset catalogs, or the project only when it runs that part of the build again. So a build that reuses earlier work can pass where a build from nothing fails. CI always builds from nothing, so CI is the full check. To make the same check locally, run `just clean` before the gate.

Time and load:

- Each step is stopped, with all its child processes, when it passes its time limit. A step past its limit is a hang, not a flake.
- A process that a step leaves behind when it ends is stopped too.
- A gate that is killed, even with `kill -9`, stops its running step. The slot is free only when that step's processes have stopped.
- Each run logs its step times to a file that git ignores, `build/gate/times.jsonl`, so a slowdown shows as a trend. The last run's logs are beside it, in `build/gate/run/`.
- **The budget is 5 minutes**, warm, on the maintainer's laptop. A gate over budget passes with a warning. If it stays over, open an issue to fix it. CI starts cold, so the gate gives no warning there.
- The build and simulator steps take a machine-wide slot, so that gates from several checkouts don't overload the machine. A gate waits for its turn, and the wait is not part of its time. The slot's lock folder is `WISHBONE_GATE_SLOT_DIR`, which has a default under your user's cache folder: `~/Library/Caches/wishbone-gate`.

While you work, run only the suites you touch. Run the full gate once at the end, after your last rebase.

### Rules for writing tests

- Write the test first, and see it fail.
- A test never decides a race by the clock on the wall. Timeouts, the 60-second sync timer, reminder dates, and background refresh run on the injected clock. Every suite has a `.timeLimit`.
- Red is red. There is no retry, except for a flake named below with its signature.
- Test behavior through public interfaces. Nothing private is opened for a test.

### Named flakes

None.

### CI

- GitHub Actions runs the same `just gate`, on a macOS runner with the pinned Xcode, for every pull request and on `main`. The runner is GitHub's `xcode-27` image.
- CI builds unsigned, with no secrets, so a fork's pull request runs the whole gate.
- CI caches the built server, Go's caches, and SwiftPM's, keyed on the pin and `Package.resolved`. The workflow finds the pin file by its name (`server-pin`, in any folder) and caches `build/server/`. A pin file with another name, or a server built in another folder, gets no cache and no error.
- The built server's key also holds Go's version and the build script, so a change of either builds the server again.
- The workflows and the required checks are in [`workflow.md`](workflow.md#ci).

## Releases

TestFlight and App Store builds are made outside CI, on the maintainer's machine.

- A release build reads the real DSN from the maintainer's `Config/Local.xcconfig`.
- Sentry's environment tag tells TestFlight builds from App Store builds.
- The release step uploads the build's dSYMs to Sentry with a pinned `sentry-cli`. The upload never fails the build. Its auth token is kept where the release is built, never in the repo.
- `AppStore/` holds the App Store listing as files. The folder is the source, and App Store Connect is the copy.
