# Sign-in and devices

## Purpose

Where a user sees the devices that are signed in as them, signs one out, and makes a login link for another device. A parent or the admin uses the same screen for another user. The rules are in the spec: [Sign-in and devices](../spec.md#sign-in-and-devices), [Sign in on another device](../spec.md#sign-in-on-another-device), [Making a login link](../spec.md#making-a-login-link), and [The For {name} part](../spec.md#the-for-name-part).

## How you get here, and where you go

- **Pushed** from **Sign-in and devices** in [Settings](settings.md), for the user's own.
- **Pushed** from **Sign-in and devices** in the For {name} part of a [user's page](user.md), for a parent or the admin.
- **Sign in on another device**, or **Sign {name} in on a device**, opens the login link sheet, after the device owner check. From Settings, where the screen is already in a sheet, the login link screen is pushed.

## Content

1. **Sign in on another device**, from `can_make_login_link`. For another user: **Sign {name} in on a device**.
2. **Devices**: the user's sessions, newest use first. Each row has a readable name made from the user agent, and when it was last used. The current one is marked "This device". Each has Revoke, from `can_delete`.
3. **Passkeys**, hidden when there are none: the name, when it was added, and when it was last used. Rename and Delete come from `can_edit` and `can_delete`. For another user, there is Delete only.
4. A line that says where to add a passkey. The screen has no Add button for one.

The Signed in block and Sign out are in Settings, not here. For another user, the screen never shows or sends a time zone.

**Provisional.** Plain default: a system list with a section for each part.

### The login link

1. The QR code.
2. **Copy** and **Share**.
3. When the link expires.

The link is made on the tap, and kept while the screen is open. Leaving the screen forgets it.

**Provisional.** Plain default: the QR code at the top, with Copy and Share buttons under it and the expiry as a footer.

## States

- **The device owner check is cancelled or fails:** no link is made, and nothing opens.
- **A device with no passcode:** the link is made with no check.
- **No devices**, for another user who has never signed in: the section says so.
- **Every write here waits for the server:** making a link, Revoke, and a passkey's Rename and Delete. With no connection, the screen says "Can't reach {address}", and nothing changes.
- **Revoking "This device"** is Sign out, with its warning.
- **Deleting the last passkey** has a stronger confirmation.
- **Can't reach, and the rest:** as every screen. The lists show from the local copy.

## Windows

One column of readable width. Nothing here opens in a new window, and nothing is a drop target.

## Actions

| Action | Route | What it does |
|---|---|---|
| Sign in on another device | A row at the top | The device owner check, then the login link |
| Copy | A button on the login link | Puts the link on this device's clipboard only, for 10 minutes |
| Share | A button on the login link | Opens the system share sheet with the link |
| Revoke | A swipe action, and a context menu item, on a device | Signs that device out, after a confirmation |
| Rename | A passkey's context menu, from `can_edit` | Opens an alert with the name |
| Delete | A swipe action, and a context menu item, on a passkey | Deletes it, after a confirmation |

## Words

Decided in the spec: "Sign in on another device", "Sign {name} in on a device", "Devices", "This device", "Passkeys", "Revoke", "Wishbone on iPad", "Safari on Mac", and "Passkeys sign you in to Wishbone in a browser. Add one there." Decided, as the web app has them: "Not signed in on any device", "You'll need a new link or QR code to get back in.", and "{name} will need a new link or QR code to sign in on a new device."

**Provisional.** These are drafts:

| Where | Words |
|---|---|
| Title | "Sign-in and devices" |
| The owner check's reason | "Make a login link for {name}" |
| A device's row | "Wishbone on iPhone · used today", "Safari on Mac · used Nov 3" |
| Login link, title | "Sign in on another device", or "Sign {name} in" |
| Login link, help | "Scan this code with Wishbone on the other device. It signs that device in as {name}." |
| Login link, expiry | "This link works once, until {date}." |
| Copy, done | "Copied. The link leaves the clipboard in 10 minutes." |
| Revoke, confirmation | "Sign out {device}? It needs a new login link to sign in again.", with the button "Sign out {device}" |
| Delete a passkey | "Delete {passkey}?", with the button "Delete passkey" |
| Passkey, for another user | "Passkeys sign {name} in to Wishbone in a browser." |

## Accessibility

- A device's row is one element: the name, "This device" when it applies, and when it was last used. Its actions are Revoke.
- The QR code reads "QR code of the login link". Copy and Share do the same job without sight.
- Revoke and Delete are never only a swipe.
- At the largest text sizes, a row's last-used time moves under the name.

## Secrecy

A login link gives a session as the user for up to a year, on someone else's device. So:

- The device owner check comes before every link, the user's own, a child's, and any that the admin makes. One check for each tap.
- Copy keeps the link on this device, and the clipboard drops it after 10 minutes.
- The link is never written to the local copy, to a log, or to diagnostics.
- The screen shows no claim state.
