---
status: accepted
---

# The API client is written by hand, and checked against a pinned copy of the server's OpenAPI document

The app's API client is written by hand, with no code generation. It is one client on `URLSession`, and every request goes through one private load: the user agent, the redaction of logs, the strict test for the API's own 401 and 410, and the rule for an unreachable instance. Its models follow the server spec's rules for clients: unknown keys are ignored, every enum has an `unknown(String)` case, and a field that can be hidden keeps "absent" apart from `null` where it matters. The repo keeps a copy of the server's OpenAPI document, taken from the release that is the app's minimum server version. A contract test checks, with no server, that every endpoint the client declares is in the copy, and that every field the models decode is in that route's response.

The server's document sets `additionalProperties: false` on its schemas and closes its enums. A generated client then fails on a new field or a new enum value, and the server spec allows both within an API version.

## Considered Options

- **Generate the client from the document**, with swift-openapi-generator. Rejected. The closed schemas turn allowed changes into decode errors, and a step to open them before generation adds dependencies.
- **No contract check.** Rejected. A typo in a path or a field name then shows only against a live server.
- **A copy of the newest document.** Rejected. The app must work with every server from its minimum version up, so the copy must be the oldest one the app accepts.

## Consequences

- The copy and the minimum server version change together in one commit, with the pinned test server (see [ADR 0007](0007-the-tests-run-against-a-real-wishbone-server-built-from-a-pinned-commit.md)). To use a newer server feature, raise the minimum on purpose.
- What the document can't show (error codes, absent against `null`) is checked by the tests against the real server.
- Error codes are one open enum, with `unknown(String)`, which shows the server's `detail`.
- Collections always follow `next_cursor`. JSON is never decoded on the main actor.
