# Development

## Prerequisites

- A Mac with the Xcode version that the project pins: Xcode 27.2, with Swift 6.4.
- [mise](https://mise.jdx.dev), activated in your shell. `mise.toml` pins Node, pnpm, just, Go, actionlint, and shellcheck.
- Go builds the Wishbone server that the tests run against. You don't need to clone the server: the tests fetch and build it themselves.

## First run

```bash
mise trust
mise install
pnpm install     # installs the git hooks (lefthook and commitlint), and the String Catalog's merge driver
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
| `WISHBONE_OPERATOR_DOCS_URL` | The server's `docs/operations.md` on GitHub | The "Running Wishbone" link in the For the admin footer of Settings. Empty means no link |
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
| `just cloud-build` | Starts a TestFlight or App Store build in Xcode Cloud (see [Releases](#releases)) |

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
ci_scripts/         The scripts that Xcode Cloud runs (see Releases)
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

- **The String Catalog.** The build adds each new string from the code to `Localizable.xcstrings` in `WishboneUI` (see [The String Catalog](#the-string-catalog)).
- **The Acknowledgements.** The build writes the name and the full license text of each package that the app ships to `Acknowledgements.json` in `WishboneUI`'s resources. It reads each text from the package that the build fetched, at the commit in `Package.resolved`. So a pull request that moves a pin shows the pin's license in its diff, and the texts never go out of date.

### The String Catalog

The catalog is one JSON file, and `xcstringstool` keeps its keys in order. So two branches that each add a string at the same place in that order conflict as text, though their keys don't. Git merges the catalog with a merge driver instead, key by key:

- `.gitattributes` names the driver for each `.xcstrings` file. `scripts/xcstrings-merge.mjs` is the driver, and `scripts/xcstrings.mjs` merges and writes the file.
- `pnpm install` registers the driver in the clone's git config, and so does each `just build`. All worktrees of a clone share it. To see it: `git config merge.xcstrings.driver`.
- The driver takes every key from both sides. Where one side added, removed or changed a key, that change stays. Where the two sides changed different parts of one key, both stay. It writes the file in the order and the format that `xcstringstool` writes, so a merge never reorders a key, and the next build doesn't change the file.
- Where both sides changed one value in different ways, such as the comment of one key, git reports a conflict. The file then has our side, and the driver names each value. Fix those by hand.
- A rebase, `git merge-tree`, and every other merge in your clone run the driver. **GitHub doesn't**: it shows a conflict in the catalog that your clone doesn't have. To clear it, rebase on `origin/main` (`git fetch origin && git rebase origin/main`). The catalog merges by itself, and you don't need to build to put your strings back.

## Tests and the gate

### What to test, and where

- **The session model is the one seam for behavior.** A test calls its public actions (sign in, add, move, mark bought, sync, sign out), and checks what it publishes: the rows that screens read, the reminders that it hands to the notification center, and the widget's file.
- **A test waits for what it reads.** A pull writes each thing when its answer arrives, and the session publishes each write as a change of its own, a moment after the write. So a sync, and a sign-in, can end before the session publishes the last write, and a wait for one write returns before the writes after it show. A test that reads published rows after a sync waits, with `until`, for those rows, or for the whole copy to be in step with the instance. Seen on CI on 2026-11-22: a test waited for Home's data and read a list (run 45004682219 attempt 4), and another waited for the primary list and read another list (run 45028988078 attempt 3).
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
- The package tests run in parallel, at most 8 at a time in each test process. The simulator tests run one at a time.
- A test's time limit counts only its own run, not its wait for one of the 8 places. Without the cap, Swift Testing starts every test of a process at once, so each test's limit counted the work of the whole process, and the tests that ended last failed on a slow runner. Seen on 2026-11-22 on CI (run 44998092929 attempt 1): the 190 session tests started together, a test whose own run takes 0.4 s ended after 42 s, and the five that ended last went past their 60 seconds, at 61 to 69 s. With 8 at a time, a test's own run took a median of 0.5 s and at most 11 s on the maintainer's Mac under a load of 186 (the test of a copy that can't be written, which waits out the database's 5-second busy timeout twice), and the session tests took 31 s in all. The cap is `--experimental-maximum-parallelization-width 8` in `just test`, so a plain `swift test` has no cap.
- `TestHTTP` and the conditioner send each request to a test server on a new connection that no other request used. The test server resets a connection that has carried no request for 10 seconds, so a request that a client puts on an idle pooled connection at that moment is lost: `URLSession` sends a `GET` again, but fails a `POST`, `PATCH`, `PUT` or `DELETE` with `networkConnectionLost`. Each of these requests connects to `127.0.0.1`, not `localhost`, so it doesn't look the name up each time, and sends `Connection: close`, so the server closes first and no client port waits in `TIME_WAIT`.
- At most 16 requests of `TestHTTP` are on their way at once, in each test process. A new connection waits in the server's listen queue until the server accepts it, and macOS caps that queue at 128 (`kern.ipc.somaxconn`). It resets one more connection, and `URLSession` fails the request with `networkConnectionLost` at once, a `GET` too. A test server on a busy machine accepts late, and a test can make 200 users at once for a group of more than one page. The conditioner's forwards take no slot, so a request that the harness sends through the conditioner never waits for its own forward.

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
- One call seeds the **standard family**: a parent with an active child and a deactivated child (with lists, a list shared with another recipient, a pending invitation, and a given gift), the admin, a user seen only through the admin's access, nested groups, a shared occasion on groups and one marked Everyone, and a blocked store.
- Names are unique for each test, and come back as typed handles. Each person can sign in as their own bearer session.
- Some rows are for the whole instance: an occasion marked Everyone, a blocked store, and every user for the admin. On the shared server, a test sees those rows of other tests too. A test that compares a whole collection picks out its own rows, or starts a private server.
- Small builder calls add anything special. A test that needs less seeds less. Reveal goes through the server's test hook.
- There is no checked-in database, and no snapshot of server state.

### The simulator tier

- The simulator tests run one at a time, on the gate's own simulator: the hosted test bundle, then a few XCUITest journeys against a real test server. `just simulator` runs them. The simulator is named "Wishbone gate". The first run makes it, and each run shuts it down at its end.
- A journey starts the test server itself, from inside the simulator, as a package test does on your Mac.
- A journey launches with a login link passed in as if pasted: the link is in the launch environment, and the app signs in with it through the same call as the paste button. A journey can also ask the app to start signed out, because a simulator keeps the session keychain's item between runs. Each journey launches on the US App Store storefront, because StoreKit gives the simulator's storefront late, or not at all, and Settings' Support Wishbone rows would then come and go from one run to the next. Only a Debug build reads these three variables.
- The journeys are: sign in (and sign in again as a user with no confirmed profile, through the profile gate, and sign in to a server of the journey's own that it then stops, for the line "Can't reach {address}" and the unreachable view), add an item, claim and mark bought as a giver, move an item between lists, add from the share extension, and sign out.
- Journeys check that things work, not how they look. **There are no snapshot comparisons.** Each journey attaches screenshots as evidence for a person to look at, never as pass or fail.
- Journeys never swipe or drag, except one drag test. Every action goes through its button or menu item, which proves that the route exists.

### Accessibility checks

- Each screen that a run's journeys reach is audited with `performAccessibilityAudit` in four settings, once in that run: the default, the largest accessibility text size, dark mode, and Increase Contrast. Any issue fails. An exception is allowed one at a time, in code, with a reason.
- XCTest gives each audit about 15 seconds, and a test can't change that. An audit that XCTest stops at that limit runs again from the start, at most twice, 2 seconds after the stop. That is the named flake [an accessibility audit doesn't complete in time on a CI runner](#named-flakes). Each try is a whole audit, and the issues of a try that was stopped are dropped, so a screen passes only when one audit read all of it.
- The key of a screen is its name in `Audit.run`. The first journey in a run that reaches a screen audits it, and a later journey that reaches it again doesn't. So the run's time grows with the number of different screens, not with the number of journeys. Two screens with one name are one screen to the audit, so each screen gets its own name.
- The settings are the simulator's own, as a person sets them in the Settings app. A test can set dark mode from inside the simulator, but not the text size or Increase Contrast. So `just simulator` runs a small settings helper on your Mac, an HTTP server on the loopback, and gives its address to the journeys. On each screen, a journey asks the helper for each setting in turn, and the helper sets it with `simctl`. So a journey runs its actions once, and audits in all four settings. Before it audits a screen, a journey asks the helper whether the screen is new in the run. The run in the four settings has its own helper, so the screens it remembers are that run's.
- Between two settings, the simulator goes back to the default, so each change is of one setting. The helper remembers what it set, so each change is one `simctl` call. Each call has a limit of 30 seconds. A call past its limit is hung, which is the named flake [a `simctl ui` call hangs on a CI runner](#named-flakes). After a hang, the helper waits 5 seconds and reads the setting back. If the setting has the value, the hung call did its work. If not, the helper runs the call again. It does this while the change has time left: it never starts a call that could end more than 3 minutes after the change started. A call that still hangs then fails, and the helper answers the journey with an error that names the setting, the `simctl` call, and how many times it hung. So a hung `simctl` shows as itself, not as a request that timed out. The helper answers within 3 minutes, and a journey waits longer than that. The helper changes one setting at a time: a request that comes while a change runs waits for it. After the journeys in the four settings, `just simulator` says how many calls the helper made, their time, and how many of them hung. Then `just simulator` checks the result bundle of that run: it must have the screenshot of each screen in each of the four settings, once, and its screens must be exactly the screens that the helper said were new. So a screenshot whose name the check can't read, or a setting's label in `Audit.swift` that differs from the gate's, fails, and doesn't pass as a run that audited fewer screens. Every journey reaches at least the signed-out screen, so a run in which the helper audited no screen fails too: the journeys didn't reach the helper. It says how many screens the journeys audited. After each change, the journey waits until the screen differs from what it was before the change, is in the setting's appearance, and two screenshots in a row are the same. The appearance is the screenshot's mean brightness: below 0.25 is dark, above 0.8 is light, and between them is neither, as in the fade from one to the other. Dark mode must be dark, and each other setting light. So the audit never reads a screen that is on its way from one setting to the next, or a screen that a late change of appearance hasn't reached yet. `just simulator` holds the status bar's clock still, so that a still screen gives the same pixels. When no screenshot has shown the change 15 seconds after the helper applied it (each was exactly as before the change, or not in the setting's appearance), the journey sends the change again, at most twice: the helper reads the three options back, then applies the setting before the change and the setting again. That is the named flake [a change of setting doesn't show in the app](#named-flakes). Each send gets 60 seconds to settle. The read and the two changes share the helper's 3 minutes.
- The journey reads an issue's element after the audit, to see whether an exception allows it. When XCUI can't place the element by then, the issue has no element, and no exception can tell what it was. An audit with such an issue, after the exceptions, runs again from the start, at most twice, 2 seconds after it ends. That is the named flake [an audit's issue has no element](#named-flakes). An issue with no element in each of the three audits fails.
- Each screenshot that a journey reads goes through `Screenshot.take`. When XCTest doesn't get a screenshot in time, the journey asks again, at most twice, 5 seconds after the time-out. That is the named flake [XCTest doesn't get a screenshot on a CI runner](#named-flakes). A wait for a still screen starts again after a time-out, with no screenshot before it, so the two screenshots in a row that it needs both come after the stall.
- At the largest text size, rows below the fold are not on the screen, so the Dynamic Type check can't measure them. A journey names those rows in `rowsToScrollTo`. In that setting, it scrolls each row on the screen in turn, under the top bar, and audits the screen again with the row on it, for Dynamic Type and clipped text only: a scrolled screen has rows under the top bar, which the system fades, and the audit before the scroll had the other checks. On a scrolled screen, a link inside a line of text that shows in part only, under a bar or off the screen's edge, gives Dynamic Type and clipped text issues with no element, because XCUI doesn't give a link's runs as elements. Those issues are not counted while such a link is on the screen. Every other issue on a scrolled screen counts. The screenshot of each scrolled audit has the row's words after the setting's, so it is not one of the screen's four.
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

`just gate` runs every check that a pull request must pass. You run it on your Mac before the pull request is ready, and quote its last line in the pull request. A pull request's CI runs only the fast checks (see [CI](#ci)), and the maintainer sets the `gate` status from your result (see [Review and the PR](workflow.md#review-and-the-pr)). Each step has a time limit, and the first failure stops the gate:

1. **Lint:** `swift-format lint --strict`, and the rest of `just lint`.
2. **Server:** builds the pinned test server, or reuses the built one.
3. **Package build:** `just build-package`: the package and its tests, for macOS.
4. **Package:** `just test --skip-build`: the tests that step 3 built, on macOS, in parallel: the contract test, the fitness tests, the session model, the secrecy suite, and the pure units.
5. **Build:** the app, the share extension, the widget, and the test bundles for the simulator, with zero warnings. It is the simulator step's build too. Then the check that the build changed nothing that is in git (see [What the build writes](#what-the-build-writes)).
6. **Simulator:** `just simulator`: the hosted test bundle, then the journeys twice, one at a time, on the gate's own simulator: once with the audit in the four settings, and once in the double-length pseudo-language. It doesn't build: it runs the tests from step 5's `.xctestrun` file. `just simulator` by itself builds first, with the same arguments as `just build`. The result bundles stay inside the checkout, in `build/gate/run/simulator/`, with the log of each run.

The gate reads its own results:

- It counts the tests from Swift Testing's summary for each test target, from XCTest's summary for each test target with an XCTest test, and from each result bundle. XCTest runs before Swift Testing, so only the XCTest part of the log gives the XCTest count.
- The journeys' result bundles hold the same tests, once for each run. So the UI count is the count of one of them, and a bundle that holds other tests than the first fails.
- It fails on any failure or recorded issue, on a bundle with 0 tests, and on a skip that is not on a short named list.
- A known issue is a recorded issue, so it fails too: in Swift Testing (`withKnownIssue`) and in XCTest (`XCTExpectFailure`).
- An issue recorded with the severity `.warning` (`Issue.record(_:severity:)`) is not a failure, so the gate passes it. Swift Testing leaves a warning out of the event stream that the gate reads.
- A test that cancels itself with `Test.cancel`, or that has a case cancelled, is a skip. So is an XCTest test that throws `XCTSkip`.
- It fails when a count falls below the **floor**: the counts (package, hosted, and UI) in a small file in git, `scripts/gate/floor.json`. A change that adds tests can raise the floor. A commit that lowers it must say why.
- The named list of skips is `allowedSkips` in `scripts/gate/main.mjs`. Each entry has a comment that says why.
- When the package step or the simulator step fails, the gate keeps the crash reports of its test processes. macOS writes a report to `~/Library/Logs/DiagnosticReports/` when a process crashes, on the Mac or in a simulator. The gate copies each report written since the step started into `build/gate/run/`, so CI's `gate-results` artifact has it. It waits up to 5 seconds for a report that is still to come. The failure line then says where the first process crashed: its name, its signal, and the crashed thread's top frames in the test's own code, for example `GATE FAIL step 4 (package): exit 1 (log: …) · swiftpm-testing-helper crashed (SIGABRT) at NetworkConditioner.Core.forward(_:) (NetworkConditioner.swift:520) ← … (report: build/gate/run/<name>.ips)`. A report names a file in the user's folder without its path, so the gate knows a report by its process and its test binary's name (`crashes` in `scripts/gate/main.mjs`). On a shared machine, a crash of the same tests in another checkout at the same time is kept too.
- It ends with one line, for example `GATE PASS package=412 hosted=38 ui=7 · 4m12s`, or `GATE FAIL step 4 (package): 2 failed`, then the names of the failed tests. A pull request quotes that line.
- A gate that passes names each step that it skipped in that line.

What "zero warnings" means in the build step:

- The compiler treats every warning as an error, in the project's targets (`SWIFT_TREAT_WARNINGS_AS_ERRORS` in the project) and in the package's own targets (`treatAllWarnings` in `Package.swift`). So a warning from the compiler fails every build until it is fixed, also in Xcode and under `swift test`. The setting is not on the build's command line, because Xcode builds a remote package such as GRDB with its warnings suppressed, and the two clash.
- The build's log must have no other `warning:` line. These come from what the compiler doesn't own: the linker, the asset catalogs, and the project.
- One line is left out: `Metadata extraction skipped`, from Xcode's App Intents step. It is that step's own log for a target with no App Intents, not a warning about the code.
- Xcode prints a warning from the linker, the asset catalogs, or the project only when it runs that part of the build again. So a build that reuses earlier work can pass where a build from nothing fails. CI always builds from nothing, so CI is the full check. To make the same check locally, run `just clean` before the gate.

Time and load:

- Each step is stopped, with all its child processes, when it passes its time limit. A step past its limit is a hang, not a flake.
- The package build's limit is 8 minutes. On CI, SwiftPM first resolves the packages, and unpacks sentry-cocoa's frameworks from its cache (about 1m10s), then builds (60 to 151 seconds). On 2026-11-23 the two took 1m49s to 3m58s in 13 runs.
- The package step's limit is 12 minutes, for the tests alone. On CI on 2026-11-23, with 394 to 403 tests, they took 2m42s to 5m40s in 12 green runs, and more than 6m18s in one run that the old limit stopped, when the build and the tests shared one step of 10 minutes (run 45187683978 attempt 1). A runner has 3 cores for 8 tests at a time, so the time goes with the runner's speed, and with the tests' CPU. Most of that CPU is the session's own work in a debug build, not the test servers: a private server starts in about 0.2 seconds.
- The lint step's limit is 5 minutes. Most of it is the gate's own tests (`just test-gate`), which take about 10 seconds on a quiet machine, and have taken up to about 140 seconds under a load of 275 to 757.
- A process that a step leaves behind when it ends is stopped too.
- The gate shuts its own simulator down when the simulator step ends, however it ends. The simulator belongs to the system, so stopping the step's processes leaves it running.
- The simulator step's limit is 60 minutes, for the six journeys. On a new CI runner, the simulator's first boot starts hundreds of its own processes, and takes up to about 6 minutes before the first test. That work uses the whole runner, so it can't run beside the other steps. Then the time goes with the screens that the journeys audit: on CI, each screen takes about 1 minute in the four settings, once in the run. The double-length pseudo-language has no helper, so it audits each time that a journey reaches a screen, and pays its 15 seconds or so on each reach. The step's fixed part, its start and the hosted tests, takes about 5m40s to 8 minutes. With both runs, a screen takes about 1m15s, so 19 audited screens take about 32 minutes. The limit also holds a second run of the journeys in the four settings, for the named flake [the app's launch gets no process ID](#named-flakes): with 19 screens that run takes about 17 minutes, and a first try whose launch waits about 3 minutes and then fails late costs nearly as much again. The named flake [a change of setting doesn't show in the app](#named-flakes) sends a change again: about 1m30s when one resend works, and up to about 5 minutes. So the step holds about 19 audited screens with one second run and one resend, and about 40 with neither. Just after that boot, a call that changes a setting can wait minutes, so the calls that put the simulator in the default settings at the step's start have a limit of 5 minutes. The step's other calls at its start, the wait for the boot and the status bar's override, have no limit of their own: the step's limit holds them. When a call at the step's start finds the simulator shut down, the step boots it again, at most twice: the named flake [the gate's simulator shuts down by itself at the step's start](#named-flakes). Each boot again costs a boot and the status bar's override, about 2 to 6 minutes on CI. The step prints a line for each part of the simulator's start, and the time that each run's tests took, so a slower part shows. The Gate job's `timeout-minutes` in `ci.yml` stays above the sum of the steps' limits, and a gate test holds it there.
- A gate that is killed, even with `kill -9`, stops its running step. The slot is free only when that step's processes have stopped.
- A step that passes says its time against its limit, for example `── package passed in 6m06s, 61% of its limit of 10m00s`. So a step that comes near its limit shows before it fails. The share is rounded down.
- Each run logs its step times, and each step's limit, to a file that git ignores, `build/gate/times.jsonl`, so a slowdown shows as a trend. The last run's logs are beside it, in `build/gate/run/`.
- **The budget is 5 minutes**, warm, on the maintainer's laptop. A gate over budget passes with a warning. If it stays over, open an issue to fix it. CI starts cold, so the gate gives no warning there.
- The build and simulator steps take a machine-wide slot, so that gates from several checkouts don't overload the machine. A gate waits for its turn, and the wait is not part of its time. The slot's lock folder is `WISHBONE_GATE_SLOT_DIR`, which has a default under your user's cache folder: `~/Library/Caches/wishbone-gate`.
- `just simulator` by itself takes the slot too, so it waits for another checkout's gate, and never breaks it. Under the gate, which holds the slot already, it doesn't take it again: the gate sets `WISHBONE_GATE_SLOT_HELD=1` for each step in the slot.

While you work, run only the suites you touch. Run the full gate once at the end, after your last rebase.

### Rules for writing tests

- Write the test first, and see it fail.
- A test never decides a race by the clock on the wall. Timeouts, the 60-second sync timer, reminder dates, and background refresh run on the injected clock. Every suite has a `.timeLimit`.
- The gate's own tests (`just test-gate`) hold this rule on a busy machine too. A step that is not about its limit gets one far past its work. A test of the limit passes the limit by hand, or gives the step work that lasts far past it. A test waits for what it needs, and gives up only after a long time.
- Red is red. There is no retry, except for a flake named below with its signature.
- Test behavior through public interfaces. Nothing private is opened for a test.

### Named flakes

A flake that the gate retries is named here, with its signature. Each other failure is red.

**A `simctl ui` call hangs on a CI runner.** Signature: in the journeys in the four settings, the line after the run says `` …, and <N> of them hung (the named flake "a `simctl ui` call hangs on a CI runner"). `` When a call hangs until the change has no time left, the journey fails with `simctl ui <device> <option> <value> didn't return within 30s, <N> times in <time>, so the simulator isn't in <setting>`. Seen on 2026-11-21 in four of about thirty CI runs (runs 44908018537 attempt 1, 44909770001 attempt 3, 44912050447 attempt 1, and 44915070644 attempt 1). Each time, it was in the first journey, on any of the three options. The call hung, and the same call run again at once hung too. Then the simulator answered again within about two minutes: the next journey's calls passed. The cause wasn't found in the helper: it runs one call at a time, a journey doesn't audit while a call runs, and a call stopped at its limit leaves no `simctl` process behind.

- What the gate does: the settings helper waits 5 seconds, reads the setting back, and runs the call again, until the change has used its 3 minutes. See [Accessibility checks](#accessibility-checks).
- What shows: the line after the journeys in the four settings says how many calls hung, and names this flake. A call that hangs for the whole 3 minutes still fails the journey, with the call and how many times it hung.

**A change of setting doesn't show in the app.** Signature: in the journeys in the four settings, `simctl` applied a change of setting without a hang, and the screen goes on showing exactly what it showed before the change. Seen on 2026-11-21 on CI three times, each time with appearance: in run 44925735621 attempt 5 and run 44964806811 attempt 1, the Gifts screen didn't change to dark mode (`SignInJourney.swift:20` and `:21`: `The screen didn't settle in dark mode within 60.0 seconds.`), and in run 44941327060 attempt 1, the profile gate didn't change back to the default from dark mode (`SignInJourney.swift:33`). The screen recordings of runs 44964806811 and 44941327060 show the app, and the status bar with it, light for the whole 60 seconds after `simctl ui <device> appearance dark` returned, and dark for the whole 60 seconds after `appearance light` returned. Each time, the next journey passed, with a new launch of the app. The screens are a list with no content and a form, which don't move by themselves. So the change reached the simulator's settings or didn't, but not the app's screen. Seen again on 2026-11-22 in run 45004682219 attempt 5, as a change that reached the app late: `Audit.swift:267` in `SignInJourney/testSignIn()`, `Gifts, in Increase Contrast: Contrast failed … (No gifts yet., …)`. The run's screen recording shows Gifts light for about 15 seconds after the change to dark mode, then dark. The change back to the default reached the app about 6 seconds late. The screen in dark mode differed a little from the screenshot in dark mode, so the journey, which then checked only that the screen differed, took it as the default. Increase Contrast was then applied and audited on the screen in dark mode, and the fade to light came during the audit: the contrast check measured grey text on a grey screen. Its screenshot "Gifts, in Increase Contrast" is dark. So the journey now checks the appearance too.

- What the gate does: after 15 seconds in which no screenshot showed the change (each was exactly as before, or not in the setting's appearance), the journey asks the helper to send the change again, by way of the setting before it, at most twice. See [Accessibility checks](#accessibility-checks).
- What shows: after the journeys in the four settings, a line names this flake and how many changes were sent again, then a line for each change with what the simulator read for its three options before it was sent again. So the next sighting says whether the simulator had the setting that the app didn't show.
- What stays red: a screen that doesn't settle after the change was sent again twice, which fails with `The screen didn't settle in <setting> within 60.0 seconds. It showed the screen as it was before the change. The change was sent again twice.` A screen that never showed the change in the setting's appearance, but didn't show exactly the screen before it either, fails with `It never showed the change in <dark or light> appearance.` in place of those words. A screen that showed the change but didn't hold still is not sent again, and fails without those words.

**An accessibility audit doesn't complete in time on a CI runner.** Signature: a journey fails with `Error Domain=com.apple.xcode.xctest.accessibilityAudit Code=-56 "Audit failed to complete in time"`, about 15 seconds after the screenshot of the screen in that setting. Seen on 2026-11-22 on CI in run 45035731171 attempt 3: the audit of Home in the default settings, the first audit after the launch that signs in (`SignInJourney.swift:21`). The screen recording shows Home still for the whole audit. On two other CI runs, that audit and the change of setting after it took 5 and 9 seconds, among the longest of the run, where most screens took 3 to 5. The same runner was slow all through the step: it took 5 minutes to hold the status bar still. The Add screen's audit met the same limit before, from the system keyboard, which the journey now sends away before that audit (see the comment in `SignInJourney.swift`).

- What the gate does: the journey runs the audit again from the start, at most twice, 2 seconds after each stop. See [Accessibility checks](#accessibility-checks).
- What shows: in the run in the four settings, the journey tells the settings helper, and after the run a line names this flake and how many audits ran again, then a line for each with its screen and setting. In the double-length run, which has no helper, the journey's log has the line `The audit of <screen>, in <setting> didn't complete in time. It runs again (<N> of 2).`
- What stays red: an audit that XCTest stops three times in a row, which fails with `The audit of <screen>, in <setting> didn't complete in time, 3 times in a row`. An issue that an audit finds is never retried.

**An audit's issue has no element.** Signature: a journey fails with `<screen>, in <setting>: Contrast failed: Contrast failed for SwiftUI.AccessibilityNode (no element)`, or another issue with `(no element)`, and the log shows each read of the issue's element retried: `Find the Any (Descendant with identity binding to AX element …) (retry 2)`. Seen on 2026-11-22 once in a local gate run, and on 2026-11-23 on CI in run 45151826388 attempt 2, `Home, in the largest text size` (`Audit.swift:205`). The run's screenshot shows the Family heading under the tab bar, which the tab bar's exception allows when its element can be read. The audit had given the issue with its element, and for 17 seconds after it, XCUI couldn't find that element on the screen. The next run passed with the same Home code. The cause of the element's going wasn't found: Home was still in the screenshots before and after.

- What the gate does: the journey runs the audit again from the start, at most twice, 2 seconds after each try. See [Accessibility checks](#accessibility-checks). The closure reads each issue's element once, so a lost element costs one read, about 3 seconds, not one for each exception.
- What shows: in the run in the four settings, the journey tells the settings helper, and after the run a line names this flake and how many audits ran again, then a line for each with its screen and setting. In the double-length run, which has no helper, the journey's log has the line `The audit of <screen>, in <setting> named an element that was gone from the screen. It runs again (<N> of 2).`
- What stays red: an issue with no element in three audits in a row, which fails with its issues and `The audit named an element that wasn't on the screen 3 times in a row.` An issue with an element is never a reason to run the audit again.

**XCTest doesn't get a screenshot on a CI runner.** Signature: a journey fails with `Failed to get screenshot: Timed out while requesting screenshot.` at a line where it asks for a screenshot, about 130 seconds after its last step in the log. Seen on 2026-11-22 on CI in run 45072154826 attempt 1, on `main`: in `SignInJourney/testSignIn()`, on the Add screen, in the wait for the default settings after dark mode (`Audit.swift:445`). The app was idle all through the wait: a spindump of the whole runner, which XCTest took about 40 seconds into it, shows the app's main thread in its run loop, and the runner's processes at little CPU. The same spindump shows macOS's `DumpGPURestart`, started about 33 seconds before: the runner's GPU had restarted, and the simulator draws its screen with that GPU. The screen recording got no frame for 38 seconds, then showed the change to the default, then stopped about 70 seconds before the test's end. The next journey, with a new launch, passed. So the stall is the runner's, not the app's, the keyboard's or the journey's.

- What the gate does: the journey's test case (`JourneyTestCase`) holds back XCTest's time-out while `Screenshot.take` waits for a screenshot, and only then. `Screenshot.take` asks again, at most twice, 5 seconds after each time-out. See [Accessibility checks](#accessibility-checks). Each time-out costs XCTest's own wait, about 130 seconds, so two of them use about 4m30s of the step's limit.
- What shows: in the run in the four settings, the journey tells the settings helper, and after the run a line names this flake and how many screenshots were asked for again, then a line for each with its screen and setting. In the double-length run, which has no helper, the journey's log has the line `XCTest didn't get a screenshot of <screen>, in <setting> in time. It asks again (<N> of 2).`
- What stays red: a screenshot that times out three times in a row, which fails with `XCTest didn't get a screenshot of <screen>, in <setting>, 3 times in a row`. Every other issue that XCTest records while it takes a screenshot, and a time-out anywhere else, is recorded as it is.

**The gate's simulator shuts down by itself at the step's start.** Signature: at the start of the simulator step, after `✓ Booted the gate's simulator` and `✓ Held the simulator's status bar still`, a `simctl` call fails with `Unable to lookup in current state: Shutdown` (CoreSimulator's error 405). Seen on 2026-11-23 on CI in run 45151826388 attempt 1 (PR #187, tooling only): the simulator booted in 56 s, its status bar was held in 1m14s, and then `simctl ui <device> appearance light` failed with `An error was encountered processing the command (domain=com.apple.CoreSimulator.SimError, code=405): Unable to lookup in current state: Shutdown`. Nothing in the gate shuts the simulator down before the step's end. The run's `gate-results` didn't have CoreSimulator's logs, so the cause wasn't found.

- What the gate does: the step boots the simulator again, holds its status bar still again, and puts it in the default settings again, from the start. It does this at most twice. Before each boot again, it keeps the end of CoreSimulator's log (`~/Library/Logs/CoreSimulator/CoreSimulator.log`) and of the simulator's `system.log` in `build/gate/run/simulator/simulator-start-<N>-first.log`. The name ends in `-first.log`, so CI uploads it after a pass too, and the next sighting can say why the simulator shut down.
- What shows: a line that names this flake, says which boot again it is (`1 of 2`), gives the call's error, and says where the logs are. Then the lines of the start again, each with `again`.
- What stays red: a third shutdown at the start, a failure of any other kind at the start, and a shutdown after the start, in the hosted tests or the journeys.

**The app's launch gets no process ID on a busy machine.** Signature: a run of the journeys fails, and each test that failed has only the message `Application '<bundle ID>' does not have a process ID` or `Failed to get background assertion for target app with pid <pid>`, except a test that Xcode names `<runner> (<pid>) encountered an error`. Both messages come from XCTest's `launch()`, which gave up before the app was ready. In XCUIAutomation's `-[XCUIApplicationImpl _launchWithRequest:]`, `launch()` first waits for the app's process, and the first message is that wait's failure: the app's code never ran. After the app's first activation, `launch()` asks for a background assertion for the app's process, and the second message is that request's failure. Only then does it wait for the app's accessibility and for the app to go idle, so the journey never reached a step on the app's screen. Seen on 2026-11-21 twice on the maintainer's Mac, with a load average of about 534 (the sign-in journey, and then both journeys about 67 s in, at `SignInJourney.swift:37` and `SignOutJourney.swift:36`), and once on CI (run 44925735621 attempt 2: the sign-in journey's `launch()` took about 190 s, then the test runner failed). Seen on 2026-11-23 in a local gate run, with a load average of about 110: two journeys got no process ID, and the claim journey got no background assertion (`ClaimJourney.swift:49`: `Failed to get background assertion for target app with pid 32833: No failure details provided`). Part of the cure is a machine under its limit.

- What the gate does: `just simulator` runs that run of the journeys again, once, with a new settings helper. The first run's result bundle and log stay beside the second's, with `-first` at the end of their names. On CI, the Gate job uploads `build/gate/` when the gate fails, and also when it passes with a first try kept, so the first try can be read after a pass. The gate reads only the second run, so a second failure of any kind is red. The second run is inside the step's 60 minutes: on CI, with 9 audited screens, the run in the four settings takes about 7m45s and the step about 20 minutes. The limit holds one second run with about 19 audited screens, but a second run of both runs of the journeys may not fit.
- What shows: the run's `✗` line, then a line that names each journey whose launch XCTest gave up on and this flake, and says where the first run is.
- What stays red: a launch that gets its process ID and then crashes has another message. An app that crashes just after its first activation may give the background assertion's message. Then the first run takes it for the flake, and the second run, which crashes again, is red. The test runner's own background assertion, `Failed to get reply to request for background assertion within <time>`, is another failure. The test runner's error with no launch that failed, a journey that failed somewhere else too, and a failed test with no message all stay red.

### CI

- On each pull request and each push to `main`, GitHub Actions runs only the fast checks: the docs check, and `just lint` (`swift-format`, actionlint, shellcheck, and the gate's own tests). The list of jobs is in [`workflow.md`](workflow.md#ci).
- The **Gate** job runs the same `just gate`, on a macOS runner with the pinned Xcode, only when the CI workflow is run by hand: before each release, from `just cloud-build` (see [Releases](#releases)), or from the Actions tab. The runner is GitHub's `xcode-27` image. Its time limits in [The gate](#the-gate) hold for these runs.
- CI builds unsigned, with no secrets, so a fork's pull request runs every job.
- The Gate job keeps the gate's logs and results (`build/gate/`) and the build's log as the run's `gate-results` artifact, for 7 days. It uploads them when the gate fails, and when the gate passes after it ran a run of the journeys again, or booted the simulator again, for a named flake: then the artifact holds the first try's result bundle and log, or the simulator's logs at its shutdown, too. A pass with no second run uploads nothing.
- The Gate job caches the built server, Go's caches, and SwiftPM's, keyed on the pin and `Package.resolved`. The workflow finds the pin file by its name (`server-pin`, in any folder) and caches `build/server/`. A pin file with another name, or a server built in another folder, gets no cache and no error.
- The built server's key also holds Go's version and the build script, so a change of either builds the server again.
- The workflows and the required checks are in [`workflow.md`](workflow.md#ci).

## Releases

TestFlight and App Store builds are made in Xcode Cloud. They start only by hand, never on a push. The maintainer starts them with one command, on a Mac where `asc` is signed in to App Store Connect:

```bash
just cloud-build "What to look at in this build"                   # Tester, from main
just cloud-build --branch fix/123-something "What to look at"      # Tester, from another branch
just cloud-build --app-store "What to look at"                     # App Store
```

`scripts/xcode-cloud-build.sh` does the steps in this order:

1. It finds the commit at the head of the branch on GitHub, and checks it with the CI workflow's Gate job (the full `just gate`, see [CI](#ci)):
   - **Tester:** it starts a Gate run on that commit, prints the run's URL, and goes on without waiting. Check the run before you send the build further.
   - **App Store:** it uses a Gate run that passed on that exact commit, or waits for one under way, or starts one and waits for it (up to an hour). If the Gate fails, it stops with the run's URL and starts no build. To try again after a fix, push the fix and run the command again.
   - `--build-only` follows the rule of the workflow that it builds.
2. It starts the workflow on the branch: **Tester** by default, or **App Store** with `--app-store`. Tester builds go to internal testers only. The App Store workflow needs the explicit flag.
3. It waits for the build run, and for App Store Connect to process the build.
4. It sets the build's What to Test notes. The notes are the command's argument, never a file in the repo.
5. It adds the build to the TestFlight group, which tells the testers. The notes are set first, so the testers get them with the build.

Xcode Cloud builds the head of the branch when step 2 starts it. So don't push to the branch while the command runs, or the build is not the commit that the Gate checked.

The script reads the App Store Connect key from `asc` on that Mac (its default profile, or `ASC_PROFILE`), never from the repo. `--build-only` stops after step 3. The script needs `gh`, signed in to GitHub, to start and read the Gate runs. `--help` lists every option.

In Xcode Cloud:

- `ci_scripts/ci_post_clone.sh` writes `Config/Local.xcconfig` on the build machine: the real DSN, from the Xcode Cloud secret `SENTRY_DSN`; the Sentry environment, `testflight` for Tester and `appstore` for App Store; and Xcode Cloud's build number as `CURRENT_PROJECT_VERSION`. A release workflow with no DSN stops. Any other workflow writes nothing, so its build sends no diagnostics.
- `ci_scripts/ci_post_xcodebuild.sh` uploads the archive's dSYMs to Sentry with a pinned `sentry-cli`, checked against the SHA-256 of its release. The upload never fails the build: each problem is a warning. `sentry-cli` reads its token from the Xcode Cloud secret `SENTRY_AUTH_TOKEN`.
- The DSN and the token are Xcode Cloud secrets, never in the repo. Every member of the App Store Connect team can read the build logs, so neither script prints them.
- A local build still sends nothing: `Shared.xcconfig` has no DSN, and git ignores `Config/Local.xcconfig`.
- The app's `Info.plist` says that it uses no non-exempt encryption (it uses only HTTPS and hashing), so App Store Connect asks no export question for each build.

`AppStore/` holds the App Store listing as files. The folder is the source, and App Store Connect is the copy.
