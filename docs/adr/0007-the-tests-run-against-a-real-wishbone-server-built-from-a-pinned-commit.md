---
status: accepted
---

# The tests run against a real Wishbone server built from a pinned commit

The session model's tests run against a real Wishbone server, not an HTTP stub. The server is built from source at a pinned commit of `jsclayton/wishbone`, with the `e2e` build tag, and stamped with its version. The pin is held in one file beside the copy of the OpenAPI document and the minimum server version, and all three change together in one commit (see [ADR 0004](0004-the-api-client-is-written-by-hand-and-checked-against-a-pinned-copy-of-the-servers-openapi-document.md)). Each test process starts its own server, on a free port with its own data folder, so tests and checkouts run in parallel. What a real server can't do (no network, a held request, a 5xx, a 410, an old version) comes from a network conditioner in `TestSupport`, which passes everything through to the server unless a test tells it otherwise.

The server holds the rules that matter most: who sees what, claim state, quantity, the `can_*` fields, and reveal. A fake would copy them and drift. A real server is cheap: built from source it takes about 13 seconds once, starts in under a second, and finishes setup in milliseconds.

## Considered Options

- **An HTTP stub, or a fake server in Swift.** Rejected. It copies the server's rules, and a test then passes against rules that the real server doesn't have.
- **A published test image of the server.** Rejected. A macOS CI runner has no Docker, and the source build needs only Go.
- **A mocking library for the network.** Rejected. The network conditioner does the few things a real server can't, with no dependency.

## Consequences

- Go is a tool of the repo, installed by mise. A test that needs the server fails, never skips, when Go or the server is missing.
- The fixture builder seeds a standard family through the API, as the admin. There is no checked-in database and no snapshot of server state.
- `ScratchDirectory` in `TestSupport` is the one place a test names a temporary folder. Each server's data folder lives under it, and is removed when its test process ends, or at the next start if that process crashed.
- The pin is a commit SHA. When the server has release tags, it can be a tag.
