---
status: accepted
---

# The app is MPL-2.0, not the server's AGPL-3.0

The app is under the Mozilla Public License 2.0. A contribution comes in under the same license, with no contributor agreement and no sign-off. Files carry no license headers: `LICENSE` is the unchanged MPL-2.0 text, and the README carries the notice. The copyright is "John Clayton and contributors". The name and the app icon are outside the license (see [TRADEMARKS.md](../../TRADEMARKS.md)).

The app goes to the App Store, and so can a fork. Apple's terms add restrictions that the GPL family treats as "further restrictions", so a GPL or AGPL app on the App Store works only while one person holds all the copyright. MPL-2.0 is copyleft for each file, so changes to the app's files stay open. Its section 3.2 lets the compiled app go out under other terms, which covers Apple's. Firefox for iOS is the precedent: MPL-2.0, outside contributions, no contributor agreement, on the App Store.

## Considered Options

- **AGPL-3.0, as the server, with a contributor agreement.** Rejected. The agreement lets the maintainer ship, but a fork can't, and an agreement to sign keeps contributors away.
- **GPL-3.0 with an App Store exception, and a sign-off.** Rejected. Every contributor must accept the exception, and a fork that drops it can't take later changes.
- **MIT**, as the open source apps hermex and ruddarr are. Rejected. A fork can close its changes to the app's files.

## Consequences

- The app's dependencies, GRDB and sentry-cocoa, are MIT and combine with it. Their license texts ship in the app's Acknowledgements screen.
- MPL-2.0 section 3.2(a) asks that people who get the app can find its source. Settings has a "Source code" row, from `WISHBONE_SOURCE_URL`.
- The App Store listing uses Apple's standard license agreement. Its copyright field says "2026 John Clayton and contributors".
- The server and the app have different licenses. The app shares no code with the server, so nothing crosses between them.
