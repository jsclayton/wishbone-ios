# The signed-out screen

## Purpose

The way in. A person scans or pastes a login link, and the app signs in at once. The screen is also where a device lands after it is signed out.

The rules are in the spec: [The signed-out screen](../spec.md#the-signed-out-screen), [Scan or paste signs in at once](../spec.md#scan-or-paste-signs-in-at-once), and [Unreachable never ends the session](../spec.md#unreachable-never-ends-the-session).

## How you get here, and where you go

- It replaces the whole window. It is not a tab, and not a sheet over the tabs (see [What sits in front of the tabs](../spec.md#what-sits-in-front-of-the-tabs)).
- It shows on a fresh install, after Sign out, after the API's own 401, and when the "Add item" control is used while signed out.
- A link from outside that arrives while it shows is dropped.
- After a sign-in, the window shows a [version block](version-block.md), the [profile gate](profile-gate.md), or [Home](home.md), in that order of need.
- **Scan QR code** opens the scanner as a full-screen cover. **I don't have a link** opens the help sheet. The notice line opens [Share diagnostics](share-diagnostics.md) as a sheet.

## Content

From top to bottom:

1. The app's name and icon.
2. A message, when there is one (see States).
3. **Scan QR code**, the main button.
4. **Paste link**, the system paste button.
5. **I don't have a link**.
6. At the foot, the diagnostics notice line (see [The notice and the switch](../spec.md#the-notice-and-the-switch)).

**Provisional.** Plain default: the two buttons stacked, the help link under them, and the notice line at the foot.

### The scanner

- The camera view fills the cover, with Cancel.
- It reacts only to a login link, and ignores any other QR code.
- A scanned login link closes the cover and starts the sign-in.

**Provisional.** Plain default: the system's data scanner with one line of help under it.

### The help sheet

Four cases, as the spec lists them. The last has a web link to the server project's page on running an instance.

**Provisional.** Plain default: a system list with one row for each case.

## States

- **Plain:** no message.
- **Signing in:** the buttons are disabled, and a progress indicator shows with "Signing in…". The app reads the instance's version, then redeems the link.
- **Signed in:** "Signed in as {name}" shows briefly, then the next screen.
- **Signed out by the server:** the message from [The API's own 401 signs the device out](../spec.md#the-apis-own-401-signs-the-device-out), or "Your account has been deleted."
- **Signed out with no connection:** the message from [Sign out](../spec.md#sign-out).
- **The link is used or expired** (401 `login_link_invalid`): a message, and the buttons stay ready.
- **Not a login link**, for a paste.
- **Can't reach {address}**, during sign-in: the app keeps the link, and shows Try again and Cancel.
- **A certificate the device doesn't trust:** its own message, with no way around it.
- **No Wishbone at the address**, from the version check.
- **The instance is too old:** the [version block](version-block.md) shows, and the link is not used.
- **Camera denied or not available:** Scan QR code says why, and offers Open Settings. Paste link still works.

**Provisional.** Plain default: each message is text above the buttons, and Try again is a button under it.

## Windows

- Every window shows this screen while the device is signed out.
- A sign-in in one window signs in every window.
- Narrow and wide: the content stays in a column of readable width, centered.

## Actions

| Action | Route | What it does |
|---|---|---|
| Scan QR code | The main button | Opens the scanner. A login link signs in |
| Paste link | The system paste button | Signs in with the link on the clipboard |
| I don't have a link | A text button | Opens the help sheet |
| Diagnostics settings | The notice line | Opens Share diagnostics as a sheet |
| Try again | A button, after "Can't reach" | Tries the same link again |
| Open Settings | A button, when the camera is denied | Opens the app's page in iOS Settings |
| Running your own Wishbone | A row in the help sheet | Opens the server project's page in the browser |

## Words

Decided in the spec: "Scan QR code", "Paste link", "I don't have a link", "Signed in as {name}", "That isn't a Wishbone login link", "You were signed out of {address}. Ask for a new login link to sign in again.", "Your account has been deleted.", "No Wishbone found at {address}", and the sign-out message for a failed server call.

**Provisional.** These are drafts:

| Where | Words |
|---|---|
| Signing in | "Signing in…" |
| The link is used or expired | "That link was already used, or it has expired. Ask for a new one." |
| Can't reach, during sign-in | "Can't reach {address}. Your link is kept. Try again when you're connected." |
| Certificate not trusted | "This device doesn't trust the certificate of {address}. Ask the person who runs Wishbone." |
| Camera denied | "Wishbone needs the camera to scan a QR code. You can turn it on in Settings, or paste a link." |
| Camera not available | "This device has no camera to scan with. Paste a link." |
| The scanner's help | "Point the camera at the QR code of your login link." |
| Help sheet, title | "Getting a login link" |
| Help sheet, a family member runs it | "Someone in your family runs Wishbone. Ask them, or your parent, for a login link." |
| Help sheet, the browser | "You use Wishbone in a browser. Open your sign-in screen there. It shows a QR code for you." |
| Help sheet, another device | "You're signed in to the app on another device. Open Wishbone there, and use Sign in on another device." |
| Help sheet, no instance | "Nobody in your family runs Wishbone yet." with the link "Running your own Wishbone" |
| The notice line | See [Share diagnostics](share-diagnostics.md) |

## Accessibility

- The message is announced when it appears, and so is "Signed in as {name}".
- The scanner has Cancel as its first element. Paste link does everything the scanner does, so nobody needs the camera.
- The link in the help sheet reads "Running your own Wishbone, opens in browser".
- At the largest text sizes the content scrolls, and the notice line stays in the scroll, not pinned.

## Secrecy

None. The screen shows nothing from the instance. The sign-out message names the instance address, which the person who holds the device already used.
