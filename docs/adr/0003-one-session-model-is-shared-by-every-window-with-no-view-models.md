---
status: accepted
---

# One session model is shared by every window, with no view models

There are no view models. A screen keeps its own `@State`. Shared state is one `@Observable`, `@MainActor` **session model** for each signed-in session. The app's composition root builds it once and puts it in the environment of every window scene, so every window reads the same instance. Screens never call the API client: every read and every write goes through the session model, which owns the local database (see [ADR 0005](0005-grdb-is-the-local-database-and-screens-read-only-it.md)).

A drop in one window must show in every other window at once. One shared model, and one database under it, makes that true for every write, not only drags. It also gives the tests one seam: a test calls the session model's actions and checks what it publishes.

## Considered Options

- **A view model for each screen.** Rejected. Each window then holds its own copy of shared state. SwiftUI's own state and one `@Observable` model already do the job.
- **Screens that call the API client directly.** Rejected. Writes can then skip the unsent changes, and a screen can show data that no other window sees.

## Consequences

- Sign-out, or the API's own 401, discards the session model, and every window shows the signed-out screen.
- The share extension builds its own session model in the same way, with a database in memory, so the add form has one dependency.
- The word "store" is kept for shops, as in the server's **store link** and **blocked store**. It never names state in code or docs. The code says "session model" for the shared state and "session keychain" for the Keychain item.
