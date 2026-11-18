# The Share diagnostics screen

## Purpose

One switch for **diagnostics**, with a plain account of what is sent and what never is. A person can turn diagnostics off before anything is sent. The rules are in the spec: [On by default, for each device, after a notice](../spec.md#on-by-default-for-each-device-after-a-notice) and [The notice and the switch](../spec.md#the-notice-and-the-switch).

## How you get here, and where you go

- **A sheet**, from the notice line at the foot of the [signed-out](signed-out.md) screen.
- **Pushed** from **Share diagnostics** in [Settings](settings.md).
- **Privacy policy** opens in the browser.

## Content

1. **Share diagnostics**: the switch. On by default.
2. A short paragraph: what is sent, and what never is.
3. **Privacy policy**, a web link.

The choice belongs to the device, not to the user. It survives a sign-out and a change of user.

**Provisional.** Plain default: a system form with a toggle, a footer paragraph, and a link. As a sheet, it has Done.

## States

- **On.**
- **Off:** anything not yet sent is deleted, with the diagnostics ID. Nothing more is sent.
- **A build with no DSN** (a fork, or a build from source): diagnostics never start. The switch still shows, and changes nothing that leaves the device.
- **No connection:** the screen works. The switch is local.

## Windows

One column of readable width. As a sheet in a wide window, it is the system's form sheet.

## Actions

| Action | Route | What it does |
|---|---|---|
| Turn diagnostics on or off | The switch | Off deletes what is not sent and the diagnostics ID. On makes a new ID |
| Privacy policy | A row | Opens the policy in the browser |
| Done | The toolbar, in the sheet | Closes the sheet |

## Words

Decided in the spec: "Share diagnostics".

**Provisional.** These are drafts. The first is in the spec, marked.

| Where | Words |
|---|---|
| The notice line, on the signed-out screen | "If Wishbone crashes, it sends a report to its developer, never anything from your family's lists. Diagnostics settings" |
| What is sent | "Wishbone sends crash and fault reports to its developer, with the versions of the app and of Wishbone, the device model, and the iOS version." |
| What never is | "It never sends anything from your family's lists, names, birthdays, or the address of your Wishbone." |
| The device | "This setting is for this device, whoever signs in." |
| The link | "Privacy policy" |

## Accessibility

- The switch reads "Share diagnostics", and its state.
- The paragraph is read after the switch.
- The link reads "Privacy policy, opens in browser".
- On the signed-out screen, the notice line's "Diagnostics settings" is a button with that label.

## Secrecy

Diagnostics never carry **family content**, which includes claim state. The screen says so in plain words. Turning the switch on or off sends nothing about the choice.
