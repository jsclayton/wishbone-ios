# The version blocks

## Purpose

To stop the app when it and the instance can't work together, and to say who must update what. There are two blocks: the app is too old, and the instance is too old. The rules are in the spec: [Version checks](../spec.md#version-checks).

## How you get here, and where you go

- A block replaces the whole window. It is not a tab, and not a sheet (see [What sits in front of the tabs](../spec.md#what-sits-in-front-of-the-tabs)).
- **The app is too old:** any request answered with a 410 `api_version_removed`.
- **The instance is too old:** the version check, before a login link is redeemed, and each time the app comes to the foreground.
- A block keeps the session. A link from outside that arrives while a block shows is dropped.
- When the check passes again, the block goes by itself, and the window shows what it showed before.

## Content

1. A title.
2. The message, which names the instance address.
3. For the app too old: **Update Wishbone**, which opens the app's App Store page.
4. For the instance too old: **Try again**.
5. When signed in: **Sign out**, so that a person is never held on a block. During sign-in: **Back**.

**Provisional.** Plain default: the system's unavailable-content view, with the buttons under the message.

## States

- **The app is too old.**
- **The instance is too old**, signed in: the check runs again at each foreground, and Try again runs it at once.
- **The instance is too old**, during sign-in: the block shows over the signed-out screen with **Back**, and the login link is not used.

## Windows

Every window shows the block. It goes from every window together.

## Actions

| Action | Route | What it does |
|---|---|---|
| Update Wishbone | A button, app too old | Opens the app's page in the App Store |
| Try again | A button, instance too old | Runs the version check again |
| Sign out | A button, when signed in | Signs out, with the warning from [Sign out](../spec.md#sign-out) |
| Back | A button, during sign-in | Returns to the signed-out screen |

## Words

Decided in the spec: "This version of Wishbone is too old for {address}. Update the app." and "{address} runs Wishbone {version}. The app needs {minimum} or later. Ask whoever runs it to update."

**Provisional.** These are drafts: the titles "Update Wishbone" (app too old) and "This Wishbone needs an update" (instance too old), and the buttons "Update Wishbone", "Try again", "Sign out", and "Back".

## Accessibility

The title and the message are one element, read when the block appears. The buttons follow it.

## Secrecy

None.
