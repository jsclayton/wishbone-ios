# Wishbone for iPhone and iPad

The native iPhone and iPad app for Wishbone, private self-hosted family wish lists. Members claim gifts for each other without spoiling the surprise. SwiftUI on iOS and iPadOS 27, with a share extension and a widget extension, against the Wishbone server's API v2.

## Where truth lives

- **Behavior:** [`docs/spec.md`](docs/spec.md) is the source of truth for the app. Read it before you implement or change a feature. The server's [spec](https://github.com/jsclayton/wishbone/blob/main/docs/spec.md) and [route table](https://github.com/jsclayton/wishbone/blob/main/docs/routes.md) bind the app too.
- **Screens:** [`docs/screens/`](docs/screens/README.md) has one spec for each screen and each system surface: where it is, what it holds, what each action does, and its words. Read the screen's spec before you build or change the screen, and change it in the same pull request.
- **Terms:** [`GLOSSARY.md`](GLOSSARY.md) adds the app's terms to the server's [glossary](https://github.com/jsclayton/wishbone/blob/main/GLOSSARY.md). Use them in code, tests, UI copy, and docs.
- **Decisions and reasons:** [`docs/adr/`](docs/adr/README.md). Read the relevant one before you change the navigation, the modules, the session model, the API client, the database, the sync, the tests, or diagnostics.
- **Code:** [`docs/architecture.md`](docs/architecture.md) says where each rule lives. [`docs/development.md`](docs/development.md) has setup, signing, the repo layout, tests and the gate, and releases.
- **Process:** [`docs/workflow.md`](docs/workflow.md) covers tickets, branches, pull requests, review, merge, and CI.
- **Privacy:** [`PRIVACY.md`](PRIVACY.md) is the app's privacy policy. A change to what leaves the device changes it, and its effective date, in the same pull request.
- **The App Store listing:** `AppStore/` holds the listing as files. The folder is the source, and App Store Connect is the copy.

## Commands

`just --list` shows every recipe.

```bash
pnpm install                 # git hooks (lefthook and commitlint)
just gate                    # every check a pull request must pass. Quote its last line
just test                    # the package tests on macOS, against the pinned Wishbone server
just server                  # fetch and build that server. `just test` and `just gate` run it first
just lint                    # swift-format lint --strict, actionlint, shellcheck, the docs check, the gate's own tests
just fmt                     # format the Swift files
swift test --package-path WishboneKit --filter TestName     # one package test
```

## Rules that break CI or hooks

- Commits and pull request titles follow Conventional Commits, with a lowercase subject (lefthook runs commitlint). A message must not contain a `Claude-Session:` line or a session URL: commitlint rejects them. `Co-Authored-By` is fine.
- Never commit `.agent/`, `.claude/`, `.beads/`, or `*.local.md`. The pre-commit hook and CI refuse them.
- The pre-commit hook runs `swift-format lint --strict` on the staged Swift files. Run `just fmt` to fix them.
- The build has zero warnings.
- The build adds new strings to the String Catalog. Commit the changed `.xcstrings` file, or the gate fails.
- Every string in the Swift package has `bundle: #bundle`.
- Name a temporary folder only through `ScratchDirectory` in `TestSupport`.
- One file imports Sentry, and one file imports StoreKit. Only the app target links `WishboneDiagnostics`.
- A new dependency needs an ADR. sentry-cocoa and GRDB are the only ones.
- The gate fails when a test count falls below the floor. A commit that lowers the floor says why.

## Process rules

- Branch: `<type>/<N>-<slug>`, for example `fix/123-hide-claim-in-widget`, where `N` is the issue number. **Never push to `main`.** Work on a branch and open a pull request.
- **A pull request merges** with `gh pr merge --squash` only when someone who wrote none of it approved its head commit in review, and `PR Title` and `CI OK` are green. Never turn on auto-merge for a pull request. See [Merge](docs/workflow.md#merge).
- **Issues are for people.** Don't put working notes, logs, or decisions in issue bodies or comments. Issues use the labels in [Labels](docs/workflow.md#labels).
- **Every presentation is provisional** until the maintainer has used it. Build the plain default that the spec gives, and never ask for approval of a look.
