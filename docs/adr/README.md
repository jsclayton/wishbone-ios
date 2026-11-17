# Architecture decision records

An ADR records a decision that is hard to reverse, and why it was made. Smaller choices are in the [spec](../spec.md), with the reason beside the rule. Each ADR has a `status` in its front matter. Read the ADRs that touch your area before you change it.

| ADR | Decision |
|---|---|
| [0001](0001-tabs-that-become-a-sidebar-and-one-kind-of-window.md) | Tabs that become a sidebar, and one kind of window |
| [0002](0002-the-code-is-one-local-package-of-four-modules-with-thin-targets.md) | The code is one local package of four modules, with thin targets |
| [0003](0003-one-session-model-is-shared-by-every-window-with-no-view-models.md) | One session model is shared by every window, with no view models |
| [0004](0004-the-api-client-is-written-by-hand-and-checked-against-a-pinned-copy-of-the-servers-openapi-document.md) | The API client is written by hand, and checked against a pinned copy of the server's OpenAPI document |
| [0005](0005-grdb-is-the-local-database-and-screens-read-only-it.md) | GRDB is the local database, and screens read only it |
| [0006](0006-writes-are-a-journal-of-unsent-changes-the-server-decides-and-claims-are-online-only.md) | Writes are a journal of unsent changes that the server decides, and claims are online only |
| [0007](0007-the-tests-run-against-a-real-wishbone-server-built-from-a-pinned-commit.md) | The tests run against a real Wishbone server built from a pinned commit |
| [0008](0008-diagnostics-go-to-sentry-on-by-default-with-notice-and-send-only-what-the-app-names.md) | Diagnostics go to Sentry, on by default with notice, and send only what the app names |
| [0009](0009-the-app-is-mpl-2-0-not-the-servers-agpl-3-0.md) | The app is MPL-2.0, not the server's AGPL-3.0 |
| [0010](0010-one-session-per-device.md) | One session per device |
| [0011](0011-plain-http-instances-are-accepted.md) | Plain-HTTP instances are accepted |

The server's own ADRs are in [its repo](https://github.com/jsclayton/wishbone/blob/main/docs/adr/README.md). They bind the app where they decide what the API does.

## Numbers

A replaced ADR is removed, not kept. A number is never used twice.

## Writing one

A new ADR takes the next number, with a name like `0012-the-decision-as-a-sentence.md`. It starts with the front matter `status: accepted`, then a title that states the decision, the decision and its context, the options considered, and the consequences, as the existing ones do. If a new decision replaces an old one, remove the old ADR in the same pull request, and say so in the new one.

A new third-party dependency needs an ADR that says why Apple's frameworks can't do the job.
