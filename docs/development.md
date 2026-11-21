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
| `WISHBONE_SENTRY_ENVIRONMENT` | `local` | The environment tag of diagnostics. A release build sets `testflight` or `appstore` |
| `WISHBONE_SOURCE_URL` | This repo | The "Source code" row in Settings |
| `WISHBONE_PRIVACY_URL` | This repo's `PRIVACY.md` on GitHub | The privacy policy link on the Share diagnostics screen |
| `WISHBONE_SUPPORT_URL` | The maintainer's Buy Me a Coffee page | The support row in Settings. Empty means no row |
| `WISHBONE_APP_STORE_URL` | Empty | The app's App Store page, which Update Wishbone opens. Empty means a search of the App Store for the app |
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

Don't set `WISHBONE_SENTRY_DSN`: keep it empty, so your build sends no diagnostics. With a DSN, a Debug build still sends nothing unless it is launched with the argument `-WishboneSendDiagnostics`. To give a build to other people, also read [`TRADEMARKS.md`](../TRADEMARKS.md).

An xcconfig file treats `//` as the start of a comment. To write a URL in one, split the slashes: `https:/$()/example.com`.

## Recipes

`just --list` shows every recipe. The main ones:

| Recipe | What it does |
|---|---|
| `just gate` | Every check that a pull request must pass, in order (see [The gate](#the-gate)) |
| `just build` | Builds the app, both extensions and the test bundles for the simulator, with zero warnings. Then it adds new strings to the String Catalog, and makes the Acknowledgements (see [What the build writes](#what-the-build-writes)) |
| `just server` | Fetches and builds the pinned Wishbone server that the tests run against, or reuses the built one |
| `just test` | The package tests on macOS, with `swift test`. It runs `just server` first |
| `just simulator` | The hosted tests and the journeys, on the gate's own simulator, in the gate slot (see [The simulator tier](#the-simulator-tier)). It runs `just server` first |
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
HostedTests/        The hosted test bundle: the tests that need iOS, inside the app
JourneyTests/       The journeys: XCUITests of the whole app
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

## What the build writes

`just build` writes two things that are in git. The gate fails when its build changed either one, so commit them with the change that caused it.

- **The String Catalog.** The build adds each new string from the code to `Localizable.xcstrings` in `WishboneUI`.
- **The Acknowledgements.** The build writes the name and the full license text of each package that the app ships to `Acknowledgements.json` in `WishboneUI`'s resources. It reads each text from the package that the build fetched, at the commit in `Package.resolved`. So a pull request that moves a pin shows the pin's license in its diff, and the texts never go out of date.

## Tests and the gate

### What to test, and where

- **The session model is the one seam for behavior.** A test calls its public actions (sign in, add, move, mark bought, sync, sign out), and checks what it publishes: the rows that screens read, the reminders that it hands to the notification center, and the widget's file.
- The API is on the far side, at the network edge, so the client's encoding and decoding are tested too.
- Pure parts with their own interface, such as the reminder plan and the shift rule, are tested directly.
- Don't test the API client on its own (beyond the contract test), private helpers, or screens.
- Where a test goes:
  - A test that needs only the package goes in the package, and runs under `swift test` on macOS, with a database in memory and the injected clock.
  - A test that needs iOS goes in the hosted test bundle: the session keychain item and its access group, the widget's file in the shared container, and `WishboneUI` pieces with logic, such as the person palette and the words for each error code. The bundle runs inside the app, and reaches the package's modules through the app. It links none of them itself, because a second copy would give the process two of each class.
  - A test of the whole app is a journey (see below).
- There is one test target for each module, and one for the fitness tests.

### A real server

- The session model's tests run against a real Wishbone server, built from a pinned commit (see [ADR 0007](adr/0007-the-tests-run-against-a-real-wishbone-server-built-from-a-pinned-commit.md)).
- One file holds the pinned commit, beside the copy of the server's OpenAPI document and the app's minimum server version. All three change together, in one commit. The file's name starts with `server-pin`: CI finds it by that name.
  - `WishboneKit/Server/server-pin.json` is the pin: the server's release tag, and that tag's commit.
  - `WishboneKit/Server/openapi.json` is the copy.
  - `minimumServerVersion` in `WishboneAPI` is the minimum server version.
- A script fetches the pinned commit over HTTPS, builds it with `-tags e2e`, and stamps its version. An unstamped build reports `dev`, which the app's version check can't read. The check passes such a version, so a test of the check against it would hold nothing. Go's version comes from that commit's `go.mod`, through mise. The built server is reused until the pin moves.
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
- A test that checks which requests a sync makes, or that compares the whole local copy with the instance, starts a private server too. On the shared one, a row for the whole instance that another test makes is one more thing for a sync to fetch.
- Every test server gets a free port, and a fresh data folder under the run's own temporary root. Nothing is fixed, so two checkouts and CI never collide.
- Every test server runs with `TZ=UTC`, `WISHBONE_LISTEN_ADDRESS=127.0.0.1` so that it is not on the local network, a high `WISHBONE_RATE_LIMIT_REDEEM`, `WISHBONE_E2E_HOOKS=true`, and `WISHBONE_EXTRACT_ALLOW_PRIVATE=true`.
- The package tests run in parallel. The simulator tests run one at a time.
- `TestHTTP` and the conditioner send each request to a test server on a new connection that no other request used. The test server resets a connection that has carried no request for 10 seconds, so a request that a client puts on an idle pooled connection at that moment is lost: `URLSession` sends a `GET` again, but fails a `POST`, `PATCH`, `PUT` or `DELETE` with `networkConnectionLost`. Each of these requests connects to `127.0.0.1`, not `localhost`, so it doesn't look the name up each time, and sends `Connection: close`, so the server closes first and no client port waits in `TIME_WAIT`.

### Temporary folders: ScratchDirectory

- `ScratchDirectory` in `TestSupport` is the one place where a test names a temporary folder. A fitness test bans `temporaryDirectory`, `NSTemporaryDirectory(`, and `mkdtemp(` in every other Swift file of the three targets, the package, the hosted tests, and the journeys.
- The hosted bundle links no `TestSupport`, so `ScratchDirectory` is not there. A hosted test makes a folder under `URL.cachesDirectory` with a UUID in its name, and removes it in a `defer`, as `HostedTests/SessionKeychainTests.swift` does. The fitness test doesn't ban `cachesDirectory`.
- Each test process has one root. A folder is removed when its last holder goes, and the root is removed when the process exits. At the next start, the roots of dead processes are removed.
- Each server's data folder is under that root, with its process ID beside it. A server stops when its holder goes, and when its test process exits. The sweep at start-up stops a server whose test process is dead before it removes the root, so a crashed run cleans up too.
- The built server and its source live in the checkout's build folder, under `build/server/`, one for each pin. Moving the pin deletes the old one.

### What a real server can't do: the network conditioner

- Use the real server wherever it can do the job: a 401 (revoke the session), a 403 `user_deactivated`, a 422 `store_blocked`, `found: false`, the LLM through a fixture endpoint, the hourly 429, and a late refusal.
- For the rest, the network conditioner in `TestSupport` passes every request through to the real server, unless a test tells it otherwise. A test can make it:
  - drop everything (offline)
  - hold a matching request until the test releases it (an answer in flight that races a pull)
  - answer a matching route with a canned response (a 5xx, a 410 `api_version_removed`, or a `/health` below the minimum version)
  - lose the connection of the next requests on a route, with no answer and before they reach the server, as a server or a proxy does to a kept connection that it has just closed (`loseConnection`). `URLSession` reports it as `networkConnectionLost`.
  - serve HTTPS with a self-signed certificate that no device trusts (`tls: .untrustedCertificate`). The conditioner makes the certificate with `openssl`, so this works only on macOS, in the package tests.
- The conditioner is a small HTTP server on your Mac, in front of the test server. A test gives the conditioner's address to the code under test as its instance address, so the code needs no seam of its own.
- A hold is at the answer by default: the request reaches the server at once, and the answer waits. A hold at the request keeps the request from the server until the release. A test waits for the hold to catch a request, never for a length of time.
- A request that a drop cuts off before it reached the server never reaches it, also after the network is back.
- What the conditioner is not:
  - A drop closes the connection with no answer. `URLSession` reports a `URLError` such as `networkConnectionLost` or `cannotConnectToHost`, never `notConnectedToInternet`. The client's rule for an unreachable instance must not depend on one code.
  - Every answer has `Connection: close`.
  - Response headers with one name come back joined into one header, and an answer has no `Content-Encoding`.

### Fixtures: the standard family

- The fixture builder in `TestSupport` seeds only through the API, as the admin. The admin makes the users and a login link for each. What only a user can do, such as making a list or claiming an item, the builder does through that user's own session.
- One call seeds the **standard family**: a parent with an active child and a deactivated child (with lists, a list shared with another recipient, a pending invitation, and a given gift), the admin, a user seen only through the admin's access, nested groups, a shared occasion on groups and one marked Everyone, and a blocked store. Deletion requests join it when the pinned server has them.
- Names are unique for each test, and come back as typed handles. Each person can sign in as their own bearer session.
- Some rows are for the whole instance: an occasion marked Everyone, a blocked store, and every user for the admin. On the shared server, a test sees those rows of other tests too. A test that compares a whole collection picks out its own rows, or starts a private server.
- Small builder calls add anything special. A test that needs less seeds less. Reveal goes through the server's test hook.
- There is no checked-in database, and no snapshot of server state.

### The simulator tier

- The simulator tests run one at a time, on the gate's own simulator: the hosted test bundle, then a few XCUITest journeys against a real test server. `just simulator` runs them. The simulator is named "Wishbone gate". The first run makes it, and each run shuts it down at its end.
- A journey starts the test server itself, from inside the simulator, as a package test does on your Mac.
- A journey launches with a login link passed in as if pasted: the link is in the launch environment, and the app signs in with it through the same call as the paste button. A journey can also ask the app to start signed out, because a simulator keeps the session keychain's item between runs. Only a Debug build reads these two variables.
- The journeys are: sign in (and sign in again as a user with no confirmed profile, through the profile gate), add an item, claim and mark bought as a giver, move an item between lists, add from the share extension, and sign out.
- Journeys check that things work, not how they look. **There are no snapshot comparisons.** Each journey attaches screenshots as evidence for a person to look at, never as pass or fail.
- Journeys never swipe or drag, except one drag test. Every action goes through its button or menu item, which proves that the route exists.

### Accessibility checks

- Each screen that a run's journeys reach is audited with `performAccessibilityAudit` in four settings, once in that run: the default, the largest accessibility text size, dark mode, and Increase Contrast. Any issue fails. An exception is allowed one at a time, in code, with a reason.
- The key of a screen is its name in `Audit.run`. The first journey in a run that reaches a screen audits it, and a later journey that reaches it again doesn't. So the run's time grows with the number of different screens, not with the number of journeys. Two screens with one name are one screen to the audit, so each screen gets its own name.
- The settings are the simulator's own, as a person sets them in the Settings app. A test can set dark mode from inside the simulator, but not the text size or Increase Contrast. So `just simulator` runs a small settings helper on your Mac, an HTTP server on the loopback, and gives its address to the journeys. On each screen, a journey asks the helper for each setting in turn, and the helper sets it with `simctl`. So a journey runs its actions once, and audits in all four settings. Before it audits a screen, a journey asks the helper whether the screen is new in the run. The run in the four settings has its own helper, so the screens it remembers are that run's.
- Between two settings, the simulator goes back to the default, so each change is of one setting. The helper remembers what it set, so each change is one `simctl` call. Each call has a limit of 30 seconds. A call past its limit is hung, which is the named flake [a `simctl ui` call hangs on a CI runner](#named-flakes). After a hang, the helper waits 5 seconds and reads the setting back. If the setting has the value, the hung call did its work. If not, the helper runs the call again. It does this while the change has time left: it never starts a call that could end more than 3 minutes after the change started. A call that still hangs then fails, and the helper answers the journey with an error that names the setting, the `simctl` call, and how many times it hung. So a hung `simctl` shows as itself, not as a request that timed out. The helper answers within 3 minutes, and a journey waits longer than that. The helper changes one setting at a time: a request that comes while a change runs waits for it. After the journeys in the four settings, `just simulator` says how many calls the helper made, their time, and how many of them hung. Then `just simulator` checks the result bundle of that run: it must have the screenshot of each screen in each of the four settings, once, and its screens must be exactly the screens that the helper said were new. So a screenshot whose name the check can't read, or a setting's label in `Audit.swift` that differs from the gate's, fails, and doesn't pass as a run that audited fewer screens. Every journey reaches at least the signed-out screen, so a run in which the helper audited no screen fails too: the journeys didn't reach the helper. It says how many screens the journeys audited. After each change, the journey waits until the screen differs from what it was before the change, and two screenshots in a row are the same. So the audit never reads a screen that is on its way from one setting to the next. `just simulator` holds the status bar's clock still, so that a still screen gives the same pixels.
- A journey that you run in Xcode has no helper. It audits once, in the settings that your simulator has.
- A second run is in the double-length pseudo-language, in which iOS shows each string of the String Catalog twice. There, the audit finds text that is cut short. A journey finds a control by its words, twice over, so text that is not in the String Catalog fails the journey.
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
4. **Build:** the app, the share extension, the widget, and the test bundles for the simulator, with zero warnings. It is the simulator step's build too. Then the check that the build changed nothing that is in git (see [What the build writes](#what-the-build-writes)).
5. **Simulator:** `just simulator`: the hosted test bundle, then the journeys twice, one at a time, on the gate's own simulator: once with the audit in the four settings, and once in the double-length pseudo-language. It doesn't build: it runs the tests from step 4's `.xctestrun` file. `just simulator` by itself builds first, with the same arguments as `just build`. The result bundles stay inside the checkout, in `build/gate/run/simulator/`, with the log of each run.

The gate reads its own results:

- It counts the tests from Swift Testing's summary for each test target, from XCTest's summary for each test target with an XCTest test, and from each result bundle. XCTest runs before Swift Testing, so only the XCTest part of the log gives the XCTest count.
- The journeys' result bundles hold the same tests, once for each run. So the UI count is the count of one of them, and a bundle that holds other tests than the first fails.
- It fails on any failure or recorded issue, on a bundle with 0 tests, and on a skip that is not on a short named list.
- A known issue is a recorded issue, so it fails too: in Swift Testing (`withKnownIssue`) and in XCTest (`XCTExpectFailure`).
- An issue recorded with the severity `.warning` (`Issue.record(_:severity:)`) is not a failure, so the gate passes it. Swift Testing leaves a warning out of the event stream that the gate reads.
- A test that cancels itself with `Test.cancel`, or that has a case cancelled, is a skip. So is an XCTest test that throws `XCTSkip`.
- It fails when a count falls below the **floor**: the counts (package, hosted, and UI) in a small file in git, `scripts/gate/floor.json`. A change that adds tests can raise the floor. A commit that lowers it must say why.
- The named list of skips is `allowedSkips` in `scripts/gate/main.mjs`. Each entry has a comment that says why.
- It ends with one line, for example `GATE PASS package=412 hosted=38 ui=7 · 4m12s`, or `GATE FAIL step 3 (package): 2 failed`, then the names of the failed tests. A pull request quotes that line.
- A gate that passes names each step that it skipped in that line.

What "zero warnings" means in the build step:

- The compiler treats every warning as an error, in the project's targets (`SWIFT_TREAT_WARNINGS_AS_ERRORS` in the project) and in the package's own targets (`treatAllWarnings` in `Package.swift`). So a warning from the compiler fails every build until it is fixed, also in Xcode and under `swift test`. The setting is not on the build's command line, because Xcode builds a remote package such as GRDB with its warnings suppressed, and the two clash.
- The build's log must have no other `warning:` line. These come from what the compiler doesn't own: the linker, the asset catalogs, and the project.
- One line is left out: `Metadata extraction skipped`, from Xcode's App Intents step. It is that step's own log for a target with no App Intents, not a warning about the code.
- Xcode prints a warning from the linker, the asset catalogs, or the project only when it runs that part of the build again. So a build that reuses earlier work can pass where a build from nothing fails. CI always builds from nothing, so CI is the full check. To make the same check locally, run `just clean` before the gate.

Time and load:

- Each step is stopped, with all its child processes, when it passes its time limit. A step past its limit is a hang, not a flake.
- A process that a step leaves behind when it ends is stopped too.
- The gate shuts its own simulator down when the simulator step ends, however it ends. The simulator belongs to the system, so stopping the step's processes leaves it running.
- The simulator step's limit is 30 minutes, for the six journeys. On a new CI runner, the simulator's first boot starts hundreds of its own processes, and takes up to about 6 minutes before the first test. That work uses the whole runner, so it can't run beside the other steps. Then the time goes with the screens that the journeys audit: on CI, each screen takes about 1 minute in the four settings, once in the run. The double-length pseudo-language has no helper, so it audits each time that a journey reaches a screen, and pays its 15 seconds or so on each reach. The step's fixed part, its start and the hosted tests, takes about 5m40s to 8 minutes. With both runs, a screen takes about 1m15s, so the step holds about 17 to 19 audited screens. Just after that boot, a call that changes a setting can wait minutes, so the calls that put the simulator in the default settings at the step's start have a limit of 5 minutes. The step's other calls at its start, the wait for the boot and the status bar's override, have no limit of their own: the step's limit holds them. The step prints a line for each part of the simulator's start, and the time that each run's tests took, so a slower part shows. The Gate job's `timeout-minutes` in `ci.yml` stays above the sum of the steps' limits, and a gate test holds it there.
- A gate that is killed, even with `kill -9`, stops its running step. The slot is free only when that step's processes have stopped.
- Each run logs its step times to a file that git ignores, `build/gate/times.jsonl`, so a slowdown shows as a trend. The last run's logs are beside it, in `build/gate/run/`.
- **The budget is 5 minutes**, warm, on the maintainer's laptop. A gate over budget passes with a warning. If it stays over, open an issue to fix it. CI starts cold, so the gate gives no warning there.
- The build and simulator steps take a machine-wide slot, so that gates from several checkouts don't overload the machine. A gate waits for its turn, and the wait is not part of its time. The slot's lock folder is `WISHBONE_GATE_SLOT_DIR`, which has a default under your user's cache folder: `~/Library/Caches/wishbone-gate`.
- `just simulator` by itself takes the slot too, so it waits for another checkout's gate, and never breaks it. Under the gate, which holds the slot already, it doesn't take it again: the gate sets `WISHBONE_GATE_SLOT_HELD=1` for each step in the slot.

While you work, run only the suites you touch. Run the full gate once at the end, after your last rebase.

### Rules for writing tests

- Write the test first, and see it fail.
- A test never decides a race by the clock on the wall. Timeouts, the 60-second sync timer, reminder dates, and background refresh run on the injected clock. Every suite has a `.timeLimit`.
- Red is red. There is no retry, except for a flake named below with its signature.
- Test behavior through public interfaces. Nothing private is opened for a test.

### Named flakes

A flake that the gate retries is named here, with its signature. Each other failure is red.

**A `simctl ui` call hangs on a CI runner.** Signature: in the journeys in the four settings, the line after the run says `` …, and <N> of them hung (the named flake "a `simctl ui` call hangs on a CI runner"). `` When a call hangs until the change has no time left, the journey fails with `simctl ui <device> <option> <value> didn't return within 30s, <N> times in <time>, so the simulator isn't in <setting>`. Seen on 2026-11-21 in four of about thirty CI runs (runs 44908018537 attempt 1, 44909770001 attempt 3, 44912050447 attempt 1, and 44915070644 attempt 1). Each time, it was in the first journey, on any of the three options. The call hung, and the same call run again at once hung too. Then the simulator answered again within about two minutes: the next journey's calls passed. The cause wasn't found in the helper: it runs one call at a time, a journey doesn't audit while a call runs, and a call stopped at its limit leaves no `simctl` process behind.

- What the gate does: the settings helper waits 5 seconds, reads the setting back, and runs the call again, until the change has used its 3 minutes. See [Accessibility checks](#accessibility-checks).
- What shows: the line after the journeys in the four settings says how many calls hung, and names this flake. A call that hangs for the whole 3 minutes still fails the journey, with the call and how many times it hung.

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
