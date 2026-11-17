---
status: accepted
---

# GRDB is the local database, and screens read only it

The app keeps a local copy of everything the user can see, in one SQLite database for each instance and user, through GRDB. Screens read only that database, and the API only feeds it. At launch, screens show what is saved at once, and a sync updates it under them. When the instance can't be reached, every screen shows what is saved, under a "Can't reach" line that blocks nothing. The session model owns the database, in `WishboneSession`, with no new module.

Wishbone's content is for reading: a list, a person's page, what you are giving. A family on a tailnet loses the instance whenever the VPN is off, and a giver in a shop needs the list most when the signal is weakest. A copy on the device also lets every window stay in step by observing one database.

## Considered Options

- **Memory only**, as the web app does. Rejected. Every launch starts empty, and an unreachable instance shows nothing.
- **A disk copy of the API's responses.** Rejected. Each screen would read a different response, so a change in one window does not show in another, and nothing can query across them.
- **A copy that the app shows only while online.** Rejected. Wishbone's content is for reading, so the copy is worth most when the instance can't be reached.

## Consequences

- GRDB is the second third-party dependency, beside sentry-cocoa. It is pinned to an exact version and moves only on purpose. Any other dependency needs an ADR that says why Apple's frameworks can't do the job.
- The copy's tables can be dropped and rebuilt at any time. The unsent changes are kept through every migration (see [ADR 0006](0006-writes-are-a-journal-of-unsent-changes-the-server-decides-and-claims-are-online-only.md)).
- The database file is in Application Support, left out of backups, with iOS's default file protection, so background refresh can sync while the device is locked.
- The share extension uses a database in memory. The widget reads a small occasions-only JSON file that the app writes, never the database.
- GRDB's MIT license text ships in the app's Acknowledgements screen.
