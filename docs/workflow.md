# Workflow

How work moves from the spec to merged code. These rules apply to everyone who changes the repo, a person or an agent. An outside contributor reads [`CONTRIBUTING.md`](../CONTRIBUTING.md) first. The rules are the server's, with the app's commands and checks.

## Overview

```
spec.md ──► tickets (GitHub issues) ──► branch and PR ──► review ──► CI ──► squash merge
```

The maintainer is the person who owns the repo and decides what the app does. They decide what is built and in what order, decide product and spec questions, and can revert any merge.

## Tickets

A ticket is a GitHub issue that describes one piece of work.

- Each ticket is a **tracer bullet**: a thin slice through every layer it touches (the API client, the session model, the screens, and the tests). It can be demoed on its own, and fits in one working session.
- A ticket cites the spec sections and the screen specs it implements, and says what done looks like.
- The maintainer opens the issue for planned work when that work starts. So the open issues show what is being worked on, not everything that is planned.
- A behavior change starts with an issue. A typo or a small fix needs none.

### Labels

| Label | Meaning |
|---|---|
| `needs-triage` | New. The maintainer hasn't looked at it yet |
| `needs-info` | A product or spec question is open, and waits on the maintainer |
| `ready-for-agent` | Ready to work on, by an agent or a person |
| `ready-for-human` | Ready to work on, by a person only |
| `wontfix` | It won't be done |

A ticket with an open question is not `ready-for-agent`.

## Branches and commits

- Branch: `<type>/<N>-<slug>`, where `<type>` is the Conventional Commit type of the change (for example `feat`, `fix`, or `docs`), and `N` is the issue number. For example: `fix/123-hide-claim-in-widget`.
- **Never push to `main`.** Every change goes through a pull request.
- Commits and pull request titles follow Conventional Commits, with a lowercase subject.
- Commits carry no session link: no `Claude-Session:` line and no `claude.ai/code/session` URL. A `Co-Authored-By: Claude` line is fine. The `commit-msg` hook rejects the session link, so remove it from the message before you commit. Pushed history is not rewritten, so tell the maintainer if a session link gets pushed.
- Work test-first, at the seams the ticket names (see [Tests and the gate](development.md#tests-and-the-gate)).
- If the spec is ambiguous or seems wrong, ask. Spec changes go through the maintainer.

## Keeping the docs current

- A behavior change changes the spec, the screen's spec, and the glossary in the same pull request, after the maintainer agrees to it. A screen and its spec always agree.
- A ticket that contradicts the spec, or that touches a screen with no spec, stops and asks.
- A new screen's spec lands in or before the pull request that builds it. It uses [the template](screens/README.md#the-template), and gets a row in the screen index.
- No pending work goes in a doc. Plans, to-dos, and open questions are issues.
- [`AGENTS.md`](../AGENTS.md), under "Where truth lives", is the one index of the docs. The README and `CONTRIBUTING.md` point to it. Keep `AGENTS.md` short: move long text to `docs/`.
- Write the docs in plain English: short sentences, one word for one meaning, and the glossary's terms.
- `just lint` checks that every relative link in a Markdown file leads somewhere, and that the ADR index and the [screen index](screens/README.md#index) each match their folder.
- A presentation stays marked "**Provisional.**" until the maintainer has used the screen. A pull request that removes a mark says so (see [the spec](spec.md#placement-is-decided-presentation-is-provisional)).

## Review and the PR

- Every change is reviewed on two axes against the default branch: repo standards, and the ticket and the spec. The reviewer wrote none of the change.
- Before you push, rebase on `origin/main` and run `just gate`.
- Open a **ready** pull request. The title is a Conventional Commit (CI checks it). The body says `Closes #<issue>`, and follows [the PR body](#the-pr-body).
- Local checks catch most failures, so CI runs about once for each pull request. CI must be green.

### The PR body

The PR body is where a reader learns what changed and why. Write it in plain language, and keep it short. Use the template:

- **Summary:** what the change does, and why.
- **Decisions and notes:** each judgment call, with the reason. Include where it resolved an ambiguity in the ticket or the spec, and any answer the maintainer gave to a question. A reader can disagree with any of them and revert.
- **Testing:** what you ran, and the gate's last line.

Scratch files are never linked or copied raw. Keep the PR body current until the merge.

### Issues you find

You can file a GitHub issue for a problem that is out of the ticket's scope: a bug in code you didn't change, a spec gap, a missing test, or a review finding that waits. This gives the maintainer a place to triage without growing the pull request.

- First search the open issues, and don't file a duplicate.
- Each issue has a clear title, a short body (the problem, where it shows, why it matters, and what done looks like), and the `needs-triage` label. Nothing else: no `ready-for-agent`, no blockers, no parents.
- Issues are for people. An issue is never a working note, a log, or a to-do.
- A problem in the Wishbone server goes to [the server's repo](https://github.com/jsclayton/wishbone/issues).
- Link each issue you file from the PR body.
- A finding that blocks the ticket is not an issue. Raise it as a question.

## Merge

- Merge with `gh pr merge --squash`, when all of these are true:
  - The pull request is ready for review, not a draft.
  - Someone who wrote none of the change approved it in review, for the current head commit. A push after the review needs a new review.
  - `PR Title` and `CI OK` pass.
  - No spec question in the pull request is still open.
- A pull request for a `ready-for-agent` ticket can merge without the maintainer, once every condition above is true.
- The maintainer merges, or says to merge, a pull request that does any of these:
  - It changes `docs/spec.md`, a decided part of a screen's spec, an ADR, `PRIVACY.md`, or `GLOSSARY.md`.
  - It removes a "**Provisional.**" mark.
  - It adds a dependency, lowers the gate's floor, or changes a workflow or `ci_scripts/`.
- An outside contributor doesn't merge their own pull request. The maintainer merges it.
- Never turn on auto-merge for a pull request. The setting is on only for Renovate.
- Exception, Renovate: Renovate merges its own minor and patch updates of tools when CI is green, with no review. A major update, and every update of sentry-cocoa or GRDB, gets a review like any other pull request.
- The Xcode version and the pinned test server move by hand, not through Renovate. The server pin moves with the copy of the OpenAPI document and the minimum server version.
- If the maintainer disagrees with a merge, they revert it with a pull request.
- The squash commit uses the pull request's title and body.
- The `Commitlint` workflow lints the subject of each commit pushed to `main`. It can't block the merge. If someone edits the title in the merge dialog and breaks the rules, `main` turns red.

### Repo settings

These GitHub settings enforce the merge rules:

- **Merge button:** only squash merge is allowed. The squash commit uses the pull request's title and body.
- **Auto-merge:** allowed, for Renovate only.
- **Branches:** GitHub deletes the head branch after the merge.
- **Ruleset `main`:** applies to the default branch, with no bypass actors. It has two rules:
  - **Pull request:** every change to `main` goes through a pull request. Squash is the only merge method. No approving review is required, because GitHub doesn't let an author approve their own pull request. The review is a rule, not a setting.
  - **Required status checks:** `PR Title` and `CI OK` must pass before a merge.

## CI

The workflows:

- **CI**, with three jobs:
  - **Changes** finds what changed. It also fails when a private file is tracked: `.agent/`, `.claude/`, `.beads/`, or `*.local.md`. It runs the docs check (`just lint-docs`) on every change, so a change to docs only can't merge a broken link.
  - **Gate** runs `just gate` on a macOS runner, unsigned, with no secrets.
  - **CI OK** is the required check. It fails if Gate failed or was cancelled. A skipped job counts as passed.
- **PR Title** checks that the pull request's title is a Conventional Commit.
- **Commitlint** lints each commit pushed to `main`.

### CI cost

macOS runners cost more than Linux runners, so CI avoids needless runs:

- CI doesn't run on draft pull requests.
- A change to docs only skips Gate, and gets the docs check in Changes, on a Linux runner. Docs are `docs/`, `LICENSE`, any `*.md` file, `.github/ISSUE_TEMPLATE/`, and `.github/pull_request_template.md`.
- A new push to a pull request cancels its older run.
- Every job has a time limit.
- Don't use a self-hosted runner: in a public repo, it runs code from anyone's fork.

## Notes and memory

The repo is public. It holds only what a human contributor needs. Issues and pull requests are for people. Put each kind of information in one place:

| Kind | Where |
|---|---|
| Lasting decisions and why | `docs/adr/`, or the spec beside the rule, in the pull request that makes the decision |
| Behavior and terms | `docs/spec.md` and `GLOSSARY.md` (spec changes go through the maintainer) |
| How and why a change was made | The PR description ("Decisions and notes") and review comments |
| Rules for every session | `AGENTS.md`, kept short |
| Your own scratch notes | Outside the repo, or in a folder that git ignores |

- Issue bodies and comments hold the problem, the acceptance criteria, and human discussion. Agents don't log working notes there.
- Before you open a pull request, move anything lasting from your notes into an ADR, the spec, or the PR body.
- Nothing from `.agent/`, `.claude/`, `.beads/`, or `*.local.md` is committed. A pre-commit hook and CI both check this.
