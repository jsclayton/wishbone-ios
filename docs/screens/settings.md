# Settings

## Purpose

What is about the user and this device: who is signed in, their profile, their devices, reminders, diagnostics, and the app itself. The rules are in the spec: [Settings: a sheet from the avatar](../spec.md#settings-a-sheet-from-the-avatar), [Source code and Acknowledgements](../spec.md#source-code-and-acknowledgements), and [Support Wishbone](../spec.md#support-wishbone).

## How you get here, and where you go

- **A sheet**, from the user's avatar at the top trailing corner of Home, Lists, and Gifts, and from Command-comma.
- Each row pushes its screen inside the sheet: [Your profile](profile.md), [Sign-in and devices](sign-in-and-devices.md), [Reminders](reminders-settings.md), [Share diagnostics](share-diagnostics.md), [Blocked stores](blocked-stores.md), and [Acknowledgements](acknowledgements.md).
- **Source code**, the support row, and the link in the For the admin footer open in the browser.
- **Sign out** closes the sheet, and every window shows the [signed-out](signed-out.md) screen.
- No link from outside opens Settings.

## Content

In order:

1. **Signed in**: the user's name, the instance address with its scheme, and **Sign out**.
2. **Your profile**.
3. **Sign-in and devices**. This section's footer is the help line on keeping gifts private on a shared device (see [No Face ID lock of the app's own](../spec.md#no-face-id-lock-of-the-apps-own)).
4. **Reminders**.
5. **Share diagnostics**.
6. **For the admin**, for the admin only: **Blocked stores**, with the footer on the jobs that are done on the server.
7. **Support Wishbone**: one row, only when the spec's rules allow it.
8. **About**: **Source code**, **Acknowledgements**, and the app's version and build.

**Provisional.** The order and the sections. Plain default: a system list in the order above, with Done in the toolbar.

## States

- **The support row is absent** on every storefront but the United States, and when the storefront is unknown. It is also absent for a user who has parents, and when the build has no support address.
- **Sign out with unsent changes:** the warning adds how many will be lost.
- **Sign out with no connection:** the device is cleared, and the signed-out screen says that the device still shows in the Devices list.
- **Can't reach {address}:** the line shows in the sheet too. Every row still opens.

## Windows

- **Narrow:** the sheet covers the window.
- **Wide:** the sheet is the system's form sheet, centered.
- **Several windows:** each window can show its own Settings sheet. A change in one shows in the others.

## Actions

| Action | Route | What it does |
|---|---|---|
| Open a row's screen | A tap on the row | Pushes it inside the sheet |
| Sign out | A button in the Signed in section | Signs out, after the warning (see [Sign out](../spec.md#sign-out)) |
| Buy John a coffee | The support row | Opens the support page in the browser, at once |
| Source code | A row | Opens the app's repository in the browser |
| Running Wishbone | The link in the For the admin footer | Opens the server's docs in the browser |
| Done | The toolbar | Closes the sheet |

## Words

Decided in the spec: the row names above, "For the admin", "Blocked stores", "Source code", "Acknowledgements", the Sign out warnings. Decided in the spec, marked as drafts there: the help line on Require Face ID, the For the admin footer, and the Support Wishbone header, row, and footer.

**Provisional.** These are drafts:

| Where | Words |
|---|---|
| Title | "Settings" |
| Signed in | "Signed in as {name}", then the address |
| Sign out, title and button | "Sign out?", "Sign out" |
| For the admin, the link | "Running Wishbone" |
| About | "About", "Version {version} ({build})" |

## Accessibility

- The avatar button that opens Settings reads "Settings".
- Each web link reads its words, then "opens in browser": "Buy John a coffee, opens in browser", "Source code, opens in browser".
- The instance address is read in full, with its scheme.
- Sign out is destructive. The warning's Sign out button has the destructive role, and the row's words say what it does. The row is not red, because the system red on a row fails the 4.5:1 contrast rule.

## Secrecy

None in the sheet itself. The help line tells a person how to guard their gifts on a shared device with iOS's Require Face ID. The support row is never shown to a child, and no diagnostics event records a tap on it.
