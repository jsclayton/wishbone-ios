---
status: accepted
---

# One session per device

A device holds one **session** at most: one user on one instance. There is no switcher. Signing out is the only way to change the user or the instance. Storage and identifiers are still keyed by instance and user from the start (the Keychain item, the local database, the image cache, the widget's file, and each reminder's identifier), so a second session later is an addition, not a migration.

It matches the server: "A browser holds at most one session. There is no account switching."

## Considered Options

A switcher was weighed against three cases:

- **A shared iPad.** A switcher puts each person's Giving one tap from whoever holds the iPad, and Face ID can't guard each person apart. So a switcher makes secrecy worse in the case it seems to serve.
- **A parent who also signs in as a child.** Not needed. The parent's own session already does everything a parent may do for a child, through the ordinary routes with the child's ID. It can't claim in the child's name or see the child's Giving, which the server withholds on purpose.
- **A user in two families' instances.** Real, but rare. That user keeps the second instance on the web. This is the accepted cost.

## Consequences

- The widget, the share extension, the reminders, and the "Add item" control each act for the one session, with no setting to pick one.
- The app never redeems a login link while signed in, so it never sends a redeem with an `Authorization` header, and the server never revokes a session that the app holds.
- Giving a device to a child means signing the parent out on it first.
