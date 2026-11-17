# Security

## Report a vulnerability

Report it in private. Don't open a public issue or pull request for a vulnerability.

1. Open the **Security** tab of this repository.
2. Choose **Report a vulnerability**. This is GitHub's private vulnerability reporting.
3. Say what you found, the steps to reproduce it, and what an attacker gains. A short proof of concept helps.

The maintainer reads the report and replies in the same private thread. The app is kept by one person, so a fix can take some days.

If the hole is in the Wishbone server, not in the app, report it on [the server's repo](https://github.com/jsclayton/wishbone/security) instead. The server's [SECURITY.md](https://github.com/jsclayton/wishbone/blob/main/SECURITY.md) says what is in scope there.

## What is in scope

Above all, any way that the app lets **a list's recipient learn claim state**. The server keeps claim state from a recipient's own session. The app must not leak the giver's claim state to a recipient who is near the giver's device (see [Secrecy on the device](docs/spec.md#7-secrecy-on-the-device)). This covers claim state, or an open gift, that shows:

- on a system surface: the widget, a reminder, an app icon badge, the share extension, or an item dragged out of the app
- in the app group's shared container
- in logs or diagnostics

Also in scope:

- family content in diagnostics
- the session token that leaves its Keychain item, or that the app sends anywhere but the instance address (for example, with a store's image address)
- a login link that the app makes without the device owner check, or that stays on the clipboard for more than 10 minutes
- one user's data that reaches another session on the same device after sign-out

## What is out of scope

- Someone who holds the unlocked device. They see what its user sees.
- A mirrored, shared, or recorded screen. The spec accepts this cost.
- A jailbroken device.
- An instance on plain HTTP, over a network you don't trust (see [ADR 0011](docs/adr/0011-plain-http-instances-are-accepted.md)).
- A report from an automated scanner with no demonstrated effect.

## Supported versions

Only the newest App Store release gets security fixes. Update to it before you report, and say which version you tested.
