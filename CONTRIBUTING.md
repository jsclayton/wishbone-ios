# Contributing

Thanks for wanting to help. The Wishbone app is kept by one person, so it stays small on purpose. Please read this before you start.

Everyone who takes part in this project follows the [Code of Conduct](CODE_OF_CONDUCT.md).

## Before you write code

Read these first:

- [`docs/spec.md`](docs/spec.md): what the app does. It is the source of truth. If the code and the spec differ, one of them is wrong. The server's [spec](https://github.com/jsclayton/wishbone/blob/main/docs/spec.md) binds the app too.
- [`GLOSSARY.md`](GLOSSARY.md): the terms. Use them in code, UI copy, and docs.
- [`docs/development.md`](docs/development.md): how to set up, build, sign, and test the app.
- [`docs/architecture.md`](docs/architecture.md): where each rule lives in the code.

[`docs/adr/`](docs/adr/README.md) says why the big choices were made. Read the matching ADR before you argue with one. [`AGENTS.md`](AGENTS.md), under "Where truth lives", indexes every doc.

## Open an issue first

For a feature or a change of behavior, open an issue before you write code. Say the problem, not only the fix. The spec decides what the app does, and the maintainer decides spec questions. A pull request that changes behavior the spec doesn't describe waits until the maintainer answers.

You can send a pull request without an issue for a typo, a small bug fix, or a missing test. A security problem is not an issue: see [`SECURITY.md`](SECURITY.md). A problem that the web app has too is probably a server problem: report it on [the server's repo](https://github.com/jsclayton/wishbone/issues).

## How to work

- Work test-first: write a failing test that shows the behavior, then make it pass. See [Tests and the gate](docs/development.md#tests-and-the-gate).
- Run `just gate` before you open a pull request, and keep it green.
- **Dependencies:** the app ships with two, sentry-cocoa and GRDB. Any other dependency needs an ADR that says why Apple's frameworks can't do the job (see [Dependencies](docs/architecture.md#dependencies)).
- **Concurrency:** follow the checklist in [Concurrency](docs/architecture.md#concurrency).
- **"Store" means a shop**, as in the glossary's **store link** and **blocked store**. Never use it as a name for state in code or docs.
- Change the spec and the glossary in the same pull request as the behavior, but only after the maintainer has agreed to the change.
- Follow [Conventional Commits](https://www.conventionalcommits.org/) for each commit and for the pull request's title, with a lowercase subject, for example `fix: keep the claim out of the widget`. `pnpm install` sets up lefthook, which runs commitlint on each commit. CI checks the title.
- Keep a pull request narrow. If it grows, split it.
- Don't commit private notes or scratch files (`.agent/`, `.claude/`, `.beads/`, `*.local.md`).

## Strings

- Every string that a person sees is in the String Catalog. Code uses `LocalizedStringResource` or `String(localized:)`, and assembles no text.
- A string in the Swift package names its bundle: `bundle: #bundle`.
- A name inside a sentence is an argument to a whole string. "Edit %@'s profile" is one entry. Code never adds "'s".
- A count uses the catalog's plural variants.
- Dates, prices, and numbers use formatters in the device's locale.
- Layout uses leading and trailing, never left and right.
- Write strings in plain US English, with the web app's words for the same actions (see [Words](docs/spec.md#words)).

## Translations

Translations aren't taken yet. Open an issue if you'd like to translate the app.

## License

The app is under the [MPL-2.0](LICENSE). When you contribute, you agree that your contribution is under the same license: what comes in is what goes out. There is no contributor agreement to sign, and no sign-off.

The name "Wishbone" and the app icon are not under the MPL-2.0 (see [`TRADEMARKS.md`](TRADEMARKS.md)). Pull requests that change the app icon are not taken.

## The full process

[`docs/workflow.md`](docs/workflow.md) describes the whole process: issues, branches, review, merge, and CI. As a contributor:

- **You don't merge your own pull request.** The maintainer reviews it, and squash-merges it when `PR Title` and `CI OK` pass.
- **You don't need the triage labels.** The maintainer triages issues and sets the labels.
- **Use the pull request template.** Say what changed and why, and the choices you made.
- **You don't have to file issues for what you find.** If you notice a problem outside your change, mention it in the pull request, or open an issue.

Questions are welcome. Open an [issue](https://github.com/jsclayton/wishbone-ios/issues/new/choose) and pick **Question**.
